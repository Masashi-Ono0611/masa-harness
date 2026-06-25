#!/usr/bin/env bash
# vuln-scan.sh — deterministic multi-repo vulnerability + runtime-EOL scanner.
#
# Per repo it: (1) extracts declared runtimes (Dockerfile FROM, .tool-versions,
# .nvmrc, package.json engines, CI node-version), (2) flags EOL runtimes via the
# endoflife.date API, (3) scans the runtime/base images for CVEs with `trivy image`
# (this is what catches Node-core CVEs that npm audit / Dependabot cannot see), and
# (4) scans the filesystem/lockfiles for dependency CVEs with `trivy fs`.
#
# Output: a machine-readable JSON file + a human summary on stdout. Triage/judgment
# is left to the SKILL.md orchestration (this script makes no act/ignore decisions).
#
# Usage:
#   vuln-scan.sh [--out DIR] [--severity LEVELS] [--skip-image] [--skip-fs] REPO [REPO...]
#   vuln-scan.sh --auto            # auto-detect git repos under ${REPOS_BASE:-$HOME/Developer}
#
set -euo pipefail

# ---- Constants -------------------------------------------------------------
DEV_ROOT="${REPOS_BASE:-$HOME/Developer}"
OUT_DIR_DEFAULT="${VULN_SCAN_OUT:-$DEV_ROOT/.vuln-scan}"
EOL_CACHE_DIR="${EOL_CACHE_DIR:-/tmp/vuln-scan-eol-cache}"
SEVERITY="HIGH,CRITICAL"
SKIP_IMAGE=0
SKIP_FS=0
AUTO=0
OUT_DIR="$OUT_DIR_DEFAULT"
TODAY="$(date +%Y-%m-%d)"

# ---- Arg parse -------------------------------------------------------------
REPOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "ERROR: --out needs an argument" >&2; exit 1; }; OUT_DIR="$2"; shift 2 ;;
    --severity) [ $# -ge 2 ] || { echo "ERROR: --severity needs an argument" >&2; exit 1; }; SEVERITY="$2"; shift 2 ;;
    --skip-image) SKIP_IMAGE=1; shift ;;
    --skip-fs) SKIP_FS=1; shift ;;
    --auto) AUTO=1; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) REPOS+=("$1"); shift ;;
  esac
done

# ---- Preflight -------------------------------------------------------------
command -v trivy >/dev/null 2>&1 || { echo "ERROR: trivy not installed (brew install trivy)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not installed (brew install jq)" >&2; exit 1; }
mkdir -p "$OUT_DIR" "$EOL_CACHE_DIR"

if [ "$AUTO" -eq 1 ]; then
  while IFS= read -r g; do REPOS+=("$(dirname "$g")"); done \
    < <(find "$DEV_ROOT" -maxdepth 3 -name .git -type d -not -path '*/node_modules/*' 2>/dev/null)
fi
[ "${#REPOS[@]}" -gt 0 ] || { echo "ERROR: no repos given (pass paths or --auto)" >&2; exit 1; }

JSON_OUT="$OUT_DIR/scan-$TODAY.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SCAN_ERRORS=0   # incremented whenever a scan/parse fails — a scanner must never silently report "0" on failure

# ---- Helpers ---------------------------------------------------------------

# endoflife.date lookup. Args: <product> <major-or-cycle>
# Echoes: "<status>|<eol_value>"  status in {EOL,SUPPORTED,UNKNOWN}
eol_status() {
  local product="$1" cycle="$2" cache="$EOL_CACHE_DIR/$1.json"
  # (re)fetch if missing or older than 1 day, so newly-EOL runtimes aren't missed via stale cache
  if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mtime +1 2>/dev/null)" ]; then
    if curl -fsSL "https://endoflife.date/api/${product}.json" -o "$cache.tmp" 2>/dev/null && jq -e . "$cache.tmp" >/dev/null 2>&1; then
      mv "$cache.tmp" "$cache"
    else
      rm -f "$cache.tmp"
      [ -s "$cache" ] || { echo "UNKNOWN|api-fail"; return; }   # no usable cache → report unknown, not "supported"
    fi
  fi
  # match exact cycle, else major.minor, else major
  local maj="${cycle%%.*}"
  local mm; mm="$(echo "$cycle" | grep -oE '^[0-9]+\.[0-9]+' || true)"
  local row
  row="$(jq -c --arg c "$cycle" --arg mm "$mm" --arg m "$maj" \
    'map(select((.cycle==$c) or (.cycle==$mm) or (.cycle==$m)))[0] // empty' "$cache" 2>/dev/null)"
  [ -n "$row" ] || { echo "UNKNOWN|no-cycle"; return; }
  local eol; eol="$(echo "$row" | jq -r '.eol')"
  # eol can be true/false or a date string
  if [ "$eol" = "true" ]; then echo "EOL|true"; return; fi
  if [ "$eol" = "false" ]; then echo "SUPPORTED|false"; return; fi
  # date string: compare to today
  if [[ "$eol" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    if [[ "$eol" < "$TODAY" ]]; then echo "EOL|$eol"; else echo "SUPPORTED|$eol"; fi
    return
  fi
  echo "UNKNOWN|$eol"
}

# Map a docker image ref to "product|version" for EOL, or "" if not a tracked runtime.
image_to_runtime() {
  local img="$1"
  case "$img" in
    node:*|*/node:*)
      local tag="${img##*:}"; tag="${tag%%-*}"
      [ -n "$tag" ] && echo "nodejs|$tag" ;;
    *distroless/nodejs*)
      local n; n="$(echo "$img" | sed -E 's#.*distroless/nodejs([0-9]+).*#\1#')"
      [ -n "$n" ] && echo "nodejs|$n" ;;
    python:*|*/python:*)
      local tag="${img##*:}"; tag="${tag%%-*}"
      echo "python|$tag" ;;
    golang:*|*/golang:*)
      local tag="${img##*:}"; tag="${tag%%-*}"
      echo "go|$tag" ;;
    *) echo "" ;;
  esac
}

# Extract real base images from a Dockerfile (skipping intra-file stage aliases & templated).
# Echoes one image per line; templated ones prefixed with "TEMPLATED:".
dockerfile_images() {
  local f="$1"
  local aliases; aliases="$(grep -iE '^[[:space:]]*FROM[[:space:]].*[[:space:]]+AS[[:space:]]+' "$f" 2>/dev/null \
    | sed -E 's/.*[[:space:]][Aa][Ss][[:space:]]+([A-Za-z0-9_.-]+).*/\1/' | tr '[:upper:]' '[:lower:]' || true)"
  grep -iE '^[[:space:]]*FROM[[:space:]]' "$f" 2>/dev/null | while IFS= read -r line; do
    local img
    img="$(echo "$line" | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?([^[:space:]]+).*/\2/')"
    [ -z "$img" ] && continue
    [ "$img" = "scratch" ] && continue
    local low; low="$(echo "$img" | tr '[:upper:]' '[:lower:]')"
    # skip if it references a prior stage alias (fixed-string match; aliases may contain regex-special chars like '.')
    if echo "$aliases" | grep -Fqx -- "$low" 2>/dev/null; then continue; fi
    if echo "$img" | grep -q '\${'; then echo "TEMPLATED:$img"; else echo "$img"; fi
  done | sort -u
}

# ---- Per-repo scan ---------------------------------------------------------
echo "[]" > "$TMP/repos.json"

for repo in "${REPOS[@]}"; do
  [ -d "$repo" ] || { echo "skip (not dir): $repo" >&2; continue; }
  name="$(basename "$repo")"
  remote="$(git -C "$repo" remote get-url origin 2>/dev/null || echo '')"
  echo "===== $name ($remote) =====" >&2

  runtimes_json="$TMP/rt.json"; echo "[]" > "$runtimes_json"
  images_seen="$TMP/imgs.txt"; : > "$images_seen"

  add_runtime() { # product version source detail
    local st; st="$(eol_status "$1" "$2")"
    if jq --arg p "$1" --arg v "$2" --arg s "$3" --arg d "$4" \
         --arg eol "${st%%|*}" --arg eolv "${st##*|}" \
         '. += [{product:$p,version:$v,source:$s,detail:$d,eol_status:$eol,eol_value:$eolv}]' \
         "$runtimes_json" > "$runtimes_json.t"; then
      mv "$runtimes_json.t" "$runtimes_json"
    else
      rm -f "$runtimes_json.t"
      echo "  WARN: failed to record runtime $1 $2 ($3)" >&2
      SCAN_ERRORS=$((SCAN_ERRORS + 1))
    fi
    return 0   # never abort the caller's && chain; failures are counted, not swallowed silently
  }

  # 1) Dockerfiles
  while IFS= read -r df; do
    rel="${df#$repo/}"
    while IFS= read -r img; do
      [ -z "$img" ] && continue
      if [[ "$img" == TEMPLATED:* ]]; then
        rt="$(image_to_runtime "${img#TEMPLATED:}")"
        [ -n "$rt" ] && add_runtime "${rt%%|*}" "${rt##*|}" "Dockerfile(templated):$rel" "${img#TEMPLATED:}"
        continue
      fi
      echo "$img" >> "$images_seen"
      rt="$(image_to_runtime "$img")"
      [ -n "$rt" ] && add_runtime "${rt%%|*}" "${rt##*|}" "Dockerfile:$rel" "$img"
    done < <(dockerfile_images "$df")
  done < <(find "$repo" -iname 'Dockerfile*' -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/.next/*' 2>/dev/null)

  # 2) .tool-versions
  while IFS= read -r tv; do
    nv="$(grep -E '^nodejs ' "$tv" 2>/dev/null | awk '{print $2}' | head -1)"
    [ -n "$nv" ] && add_runtime nodejs "$nv" ".tool-versions" "${tv#$repo/}"
  done < <(find "$repo" -maxdepth 3 -name .tool-versions -not -path '*/node_modules/*' 2>/dev/null)

  # 3) .nvmrc
  while IFS= read -r nf; do
    nv="$(grep -oE 'v?[0-9]+(\.[0-9]+)*' "$nf" 2>/dev/null | head -1 | tr -d 'v')"
    [ -n "$nv" ] && add_runtime nodejs "$nv" ".nvmrc" "${nf#$repo/}"
  done < <(find "$repo" -maxdepth 3 -name .nvmrc -not -path '*/node_modules/*' 2>/dev/null)

  # 4) package.json engines.node (root + shallow)
  while IFS= read -r pj; do
    en="$(jq -r '.engines.node // empty' "$pj" 2>/dev/null || true)"
    if [ -n "$en" ]; then
      maj="$(echo "$en" | grep -oE '[0-9]+' | head -1 || true)"
      [ -n "$maj" ] && add_runtime nodejs "$maj" "engines.node" "${pj#$repo/} ($en)"
    fi
  done < <(find "$repo" -maxdepth 2 -name package.json -not -path '*/node_modules/*' 2>/dev/null)

  # 5) CI node-version (incl. nested monorepo .github/workflows)
  while IFS= read -r wf; do
    while IFS= read -r cv; do
      [ -n "$cv" ] && add_runtime nodejs "$cv" "CI" "${wf#$repo/}"
    done < <(grep -hoE "node-version: *['\"]?[0-9]+(\.[0-9x]+)*" "$wf" 2>/dev/null | grep -oE '[0-9]+(\.[0-9x]+)*' | sort -u || true)
  done < <(find "$repo" -path '*/.github/workflows/*' \( -name '*.yml' -o -name '*.yaml' \) -not -path '*/node_modules/*' 2>/dev/null)

  # ---- runtime CVE scan (unique base images; scan each image once) ----
  # A failed/aborted scan is recorded as status:error (NOT high_crit:0) — never claim
  # an image is clean when we did not actually observe it.
  imgcve_json="$TMP/imgcve.json"; echo "[]" > "$imgcve_json"
  if [ "$SKIP_IMAGE" -eq 0 ]; then
    while IFS= read -r img; do
      [ -z "$img" ] && continue
      echo "  trivy image $img" >&2
      if trivy image --timeout 10m --quiet --scanners vuln --severity "$SEVERITY" --format json "$img" > "$TMP/img.json" 2>"$TMP/img.err" \
         && jq -e . "$TMP/img.json" >/dev/null 2>&1; then
        cnt="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$TMP/img.json")"
        ids="$(jq -r '[.Results[]?.Vulnerabilities[]?.VulnerabilityID] | unique | join(",")' "$TMP/img.json")"
        jq --arg i "$img" --argjson c "${cnt:-0}" --arg ids "$ids" \
          '. += [{image:$i, status:"ok", high_crit:$c, cve_ids:$ids}]' "$imgcve_json" > "$imgcve_json.t" && mv "$imgcve_json.t" "$imgcve_json"
      else
        err="$(tail -1 "$TMP/img.err" 2>/dev/null)"
        echo "  ERROR scanning image $img: $err" >&2
        SCAN_ERRORS=$((SCAN_ERRORS + 1))
        jq --arg i "$img" --arg e "$err" \
          '. += [{image:$i, status:"error", high_crit:null, cve_ids:"", error:$e}]' "$imgcve_json" > "$imgcve_json.t" && mv "$imgcve_json.t" "$imgcve_json"
      fi
    done < <(sort -u "$images_seen")
  fi

  # ---- dependency CVE scan (lockfiles; scan once) ----
  # status: ok | error | skipped. On error/skip the counts are JSON null, never 0.
  depcve="null"; dep_ids="null"; dep_status="skipped"
  if [ "$SKIP_FS" -eq 0 ]; then
    echo "  trivy fs $name" >&2
    if trivy fs --timeout 8m --quiet --scanners vuln --severity "$SEVERITY" --format json "$repo" > "$TMP/fs.json" 2>"$TMP/fs.err" \
       && jq -e . "$TMP/fs.json" >/dev/null 2>&1; then
      depcve="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$TMP/fs.json")"
      dep_ids="$(jq -r '[.Results[]?.Vulnerabilities[]?.VulnerabilityID] | unique | length' "$TMP/fs.json")"
      dep_status="ok"
    else
      echo "  ERROR scanning fs $name: $(tail -1 "$TMP/fs.err" 2>/dev/null)" >&2
      SCAN_ERRORS=$((SCAN_ERRORS + 1)); dep_status="error"
    fi
  fi

  jq --arg name "$name" --arg repo "$repo" --arg remote "$remote" --arg ds "$dep_status" \
     --slurpfile rt "$runtimes_json" --slurpfile ic "$imgcve_json" \
     --argjson depcve "$depcve" --argjson depids "$dep_ids" \
     '. += [{name:$name, path:$repo, remote:$remote, runtimes:$rt[0], image_cves:$ic[0], dep_status:$ds, dep_high_crit:$depcve, dep_unique_cves:$depids}]' \
     "$TMP/repos.json" > "$TMP/repos.json.t" && mv "$TMP/repos.json.t" "$TMP/repos.json"
done

# ---- Emit ------------------------------------------------------------------
jq --arg date "$TODAY" --arg sev "$SEVERITY" \
   '{generated:$date, severity:$sev, repos:.}' "$TMP/repos.json" > "$JSON_OUT"

echo
echo "================ SUMMARY ($TODAY, severity=$SEVERITY) ================"
jq -r '
  .repos[] |
  "\n# \(.name)  [\(.remote)]" ,
  (.runtimes | group_by(.product+.version) | .[] |
    "  runtime \(.[0].product) \(.[0].version)  EOL=\(.[0].eol_status)(\(.[0].eol_value))  via: \([.[].source]|unique|join(", "))"),
  (.image_cves[]? |
    if .status == "ok"
    then "  image \(.image)  HIGH/CRIT=\(.high_crit)\( if .cve_ids != "" then "  ["+.cve_ids+"]" else "" end)"
    else "  image \(.image)  SCAN-\(.status | ascii_upcase)\( if (.error // "") != "" then ": "+.error else "" end)" end),
  ( if .dep_status == "ok"
    then "  deps HIGH/CRIT vulns: \(.dep_high_crit) (\(.dep_unique_cves) unique CVEs)"
    else "  deps SCAN-\(.dep_status | ascii_upcase)" end)
' "$JSON_OUT"
echo
echo "JSON: $JSON_OUT"

if [ "$SCAN_ERRORS" -gt 0 ]; then
  echo >&2
  echo "⚠️  $SCAN_ERRORS scan/parse error(s) — results are INCOMPLETE. Do NOT treat repos/images marked SCAN-ERROR as 'clean'." >&2
  exit 2
fi
