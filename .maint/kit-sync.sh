#!/usr/bin/env bash
# kit-sync — masa-harness-kit と本体（~/.claude, ~/Developer/.claude/skills）の drift 検出。
#
# kit は本体から手作業で汎用化した配布物（個人パス・org 名・未同梱 skill 参照を除去/placeholder 化）
# なので cp 自動同期は不可（個人情報漏洩＋汎用化破壊）。本スクリプトは「本体が前回同期時から
# 変わったか」を kit-manifest.tsv の baseline_sha256 で検出する。既定は read-only（check）。
#
# 使い方:  bash kit-sync.sh {check|apply|diff <kit_rel>|stamp <kit_rel|--all>|pack}
# 詳細は同ディレクトリ README.md。
set -euo pipefail

MAINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$MAINT_DIR/.." && pwd)"
MANIFEST="$MAINT_DIR/kit-manifest.tsv"
KIT_DIR="$MAINT_DIR/../masa-harness-kit"
KIT_DIR="$(cd "$KIT_DIR" && pwd)"
TARBALL="$MAINT_DIR/../masa-harness-kit.tar.gz"
# 配布物（VERSION 対象）の相対パス prefix と、版管理メタ（版差分判定から除外）。
KIT_REL="masa-harness-kit"

# 配布物（kit/）に混入してはいけない個人情報パターン（sanitize ガード）。
# このファイルは公開リポに入るので、ここには「作者本人の識別子」だけを書く。
# 公開したくない追加パターン（業務 org 名など）は gitignore 済みの .maint/.secret-extra に
# 1 行（`a|b|c` 形式）で置く。存在すれば OR 連結する（ローカルだけで効く＝公開リポには出ない）。
# 注: bare 'masashi' は kit のブランド名なので除外（秘密の実形は path=masashi_mac_ssd / email=masashi.ono）。
SECRET_PAT='masashi_mac_ssd|masashi\.ono'
if [ -f "$MAINT_DIR/.secret-extra" ]; then
  SECRET_PAT="$SECRET_PAT|$(tr -d '[:space:]' < "$MAINT_DIR/.secret-extra")"
fi

sha() {  # sha <file> -> sha256 hex（macOS/Linux 両対応）
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

expand() {  # ~/x -> $HOME/x
  case "$1" in "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;; *) printf '%s\n' "$1" ;; esac
}

sanitize_guard() {  # kit/ に個人情報が残っていないか。0=clean / 1=fail
  local hits
  hits="$(grep -rIlE "$SECRET_PAT" "$KIT_DIR" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "SANITIZE FAIL: 個人情報の可能性 (/$SECRET_PAT/):"
    printf '%s\n' "$hits" | sed "s#^$KIT_DIR/#  #"
    return 1
  fi
  return 0
}

cmd_check() {
  local drift=0 missing=0 kit_rel src styp base srcabs cur
  while IFS=$'\t' read -r kit_rel src styp base; do
    [ -z "$kit_rel" ] && continue
    srcabs="$(expand "$src")"
    if [ ! -f "$srcabs" ]; then
      echo "MISSING source: $src  (for $kit_rel)"; missing=$((missing+1)); continue
    fi
    cur="$(sha "$srcabs")"
    if [ "$cur" != "$base" ]; then
      echo "DRIFT [$styp]: $kit_rel  ← 本体 $src が baseline から変化"
      drift=$((drift+1))
    fi
  done < "$MANIFEST"
  echo ""
  local san=clean
  sanitize_guard || san=FAIL
  echo ""
  echo "summary: drift=$drift missing=$missing sanitize=$san"
  [ "$drift" = 0 ] && [ "$missing" = 0 ] && [ "$san" = clean ]
}

cmd_apply() {  # verbatim drift のみ本体→kit に反映。generalized は列挙のみ。
  local tmp applied=0 kit_rel src styp base srcabs cur
  tmp="$(mktemp)"
  while IFS=$'\t' read -r kit_rel src styp base; do
    [ -z "$kit_rel" ] && continue
    srcabs="$(expand "$src")"
    if [ -f "$srcabs" ]; then
      cur="$(sha "$srcabs")"
      if [ "$cur" != "$base" ]; then
        if [ "$styp" = verbatim ]; then
          cp "$srcabs" "$KIT_DIR/$kit_rel"; base="$cur"; applied=$((applied+1))
          echo "applied (verbatim): $kit_rel"
        else
          echo "MANUAL (generalized): $kit_rel — 'kit-sync.sh diff $kit_rel' で確認し汎用化を保って手反映後 'stamp $kit_rel'"
        fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$kit_rel" "$src" "$styp" "$base" >> "$tmp"
  done < "$MANIFEST"
  mv "$tmp" "$MANIFEST"
  echo "verbatim applied: $applied"
}

cmd_diff() {
  local kit_rel="${1:-}" src
  [ -z "$kit_rel" ] && { echo "usage: diff <kit_rel>"; return 1; }
  src="$(awk -F'\t' -v k="$kit_rel" '$1==k{print $2}' "$MANIFEST")"
  [ -z "$src" ] && { echo "not in manifest: $kit_rel"; return 1; }
  diff "$(expand "$src")" "$KIT_DIR/$kit_rel" || true
}

cmd_stamp() {  # baseline を本体現 sha に更新（generalized を手反映し終えた後に叩く）
  local target="${1:-}" tmp kit_rel src styp base srcabs cur n=0
  [ -z "$target" ] && { echo "usage: stamp <kit_rel|--all>"; return 1; }
  tmp="$(mktemp)"
  while IFS=$'\t' read -r kit_rel src styp base; do
    [ -z "$kit_rel" ] && continue
    srcabs="$(expand "$src")"
    if { [ "$target" = --all ] || [ "$target" = "$kit_rel" ]; } && [ -f "$srcabs" ]; then
      cur="$(sha "$srcabs")"; base="$cur"; n=$((n+1))
    fi
    printf '%s\t%s\t%s\t%s\n' "$kit_rel" "$src" "$styp" "$base" >> "$tmp"
  done < "$MANIFEST"
  mv "$tmp" "$MANIFEST"
  echo "stamped: $target ($n entries)"
}

cmd_pack() {
  ( cd "$KIT_DIR/.." && tar --exclude='*.bak-*' --exclude='__pycache__' --exclude='.DS_Store' \
      -czf "$TARBALL" "$(basename "$KIT_DIR")" )
  echo "packed: $TARBALL"
  echo "--- contents (top) ---"; tar tzf "$TARBALL" | head -8
}

# 未リリースの配布物変更を検出する＝リリース漏れ防止。最新タグ vX.Y.Z 以降に配布物
# （VERSION/CHANGELOG を除く masa-harness-kit/ 配下）が変わったのに VERSION が据え置きなら
# 「マージ済だがリリースされていない」漏れ。--strict で漏れ時に exit 1（CI gate 用）。
cmd_release_status() {
  local strict=0; [ "${1:-}" = "--strict" ] && strict=1
  local latest_tag latest_ver ver changed
  latest_tag="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  if [ ! -f "$KIT_DIR/VERSION" ]; then echo "release-status: VERSION 不在"; return 1; fi
  ver="$(tr -d '[:space:]' < "$KIT_DIR/VERSION")"
  if [ -z "$latest_tag" ]; then
    echo "release-status: タグ無し（初回リリース前）— skip"; return 0
  fi
  latest_ver="${latest_tag#v}"
  changed="$(git -C "$REPO_ROOT" diff --name-only "$latest_tag"..HEAD -- "$KIT_REL/" \
            ":(exclude)$KIT_REL/VERSION" ":(exclude)$KIT_REL/CHANGELOG.md" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$changed" -eq 0 ]; then
    echo "release-status: clean（${latest_tag} 以降に配布物変更なし）"; return 0
  fi
  if [ "$ver" = "$latest_ver" ]; then
    echo "release-status: LEAK — ${latest_tag} 以降に配布物 ${changed} 件の変更があるのに VERSION 据え置き（v${ver}）"
    echo "  未リリースの変更があります。/masa-harness-release で semver 判定→VERSION/CHANGELOG→tag を切ってください。"
    git -C "$REPO_ROOT" diff --name-only "$latest_tag"..HEAD -- "$KIT_REL/" \
      ":(exclude)$KIT_REL/VERSION" ":(exclude)$KIT_REL/CHANGELOG.md" 2>/dev/null | sed 's/^/    /'
    [ "$strict" = 1 ] && return 1 || return 0
  fi
  echo "release-status: in-progress — VERSION は v${ver} に bump 済（latest tag ${latest_tag}）。tag 未 push なら publish を完了してください。"
  return 0
}

# README と実配布物の整合を検証する＝stale tree 防止。配布物（skills/commands/hooks/rules）の
# basename が README に列挙されているか、実数が README に出現するかを突き合わせる。
# --strict で不整合時に exit 1（CI gate 用）。
# missing pass と count を同一定義で出すための列挙ヘルパ（macOS/Linux 両対応＝GNU 専用の
# find -printf を使わず glob + basename）。各カテゴリの「README に出るべき token」を1行ずつ吐く
# （skills=末尾 / 付き dir 名で境界化、commands/hooks/rules=ファイル名＝拡張子が右境界）。
_kit_list() {  # _kit_list <category>
  local f
  case "$1" in
    skills)   for f in "$KIT_DIR"/skills/*/;   do [ -d "$f" ] && printf '%s/\n' "$(basename "$f")"; done ;;
    commands) find "$KIT_DIR/commands" -type f -name '*.md' 2>/dev/null | while IFS= read -r f; do basename "$f"; done ;;
    hooks)    for f in "$KIT_DIR"/hooks/*.py "$KIT_DIR"/hooks/*.sh; do [ -f "$f" ] && basename "$f"; done ;;
    rules)    for f in "$KIT_DIR"/rules/*.md;  do [ -f "$f" ] && basename "$f"; done ;;
  esac
}

cmd_doc_check() {
  local strict=0; [ "${1:-}" = "--strict" ] && strict=1
  local readme="$KIT_DIR/README.md" fail=0 cat tok
  local -a missing=()
  if [ ! -f "$readme" ]; then echo "doc-check: README.md 不在"; return 1; fi
  # (1) 列挙チェック（hard gate）: 各配布物の token が README に出現するか。
  #     grep -F で固定文字列照合＝正規表現メタ文字や `foo`⊂`foobar` の誤判定を排除。
  #     skills は token に末尾 '/' を含めて境界化、commands/hooks/rules は拡張子が右境界。
  #     missing pass と下の count は同一述語（_kit_list）由来＝定義ズレを作らない。
  for cat in skills commands hooks rules; do
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      grep -Fq -- "$tok" "$readme" || missing+=("$cat: $tok")
    done < <(_kit_list "$cat")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "doc-check: README に未記載の配布物:"; printf '    %s\n' "${missing[@]}"; fail=1
  fi
  # (2) 実数の報告（informational）: README の散文カウント（「11 個」等）は phrasing 依存で
  #     脆いため hard gate にしない。実数を出し、人/レビューが prose と突き合わせる。
  #     列挙チェック (1) が「全ファイルが README に載っている」ことは既に保証する。
  local sk cm hk rl
  sk=$(_kit_list skills   | wc -l | tr -d ' ')
  cm=$(_kit_list commands | wc -l | tr -d ' ')
  hk=$(_kit_list hooks    | wc -l | tr -d ' ')
  rl=$(_kit_list rules    | wc -l | tr -d ' ')
  echo "doc-check: actual skills=$sk commands=$cm hooks=$hk rules=$rl"
  if [ "$fail" = 0 ]; then echo "doc-check: clean"; return 0; fi
  [ "$strict" = 1 ] && return 1 || return 0
}

case "${1:-check}" in
  check)          cmd_check ;;
  sanitize)       sanitize_guard && echo "sanitize: clean" ;;  # CI gate 用（本体パス不要）
  apply)          cmd_apply ;;
  diff)           shift; cmd_diff "${1:-}" ;;
  stamp)          shift; cmd_stamp "${1:-}" ;;
  pack)           cmd_pack ;;
  release-status) shift; cmd_release_status "${1:-}" ;;  # 未リリース配布物変更の検出（--strict で CI fail）
  doc-check)      shift; cmd_doc_check "${1:-}" ;;        # README ↔ 配布物 整合（--strict で CI fail）
  *) echo "usage: kit-sync.sh {check|sanitize|apply|diff <kit_rel>|stamp <kit_rel|--all>|pack|release-status [--strict]|doc-check [--strict]}"; exit 1 ;;
esac
