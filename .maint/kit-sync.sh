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
MANIFEST="$MAINT_DIR/kit-manifest.tsv"
KIT_DIR="$(cd "$MAINT_DIR/../masa-harness-kit" && pwd)"
TARBALL="$MAINT_DIR/../masa-harness-kit.tar.gz"

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

case "${1:-check}" in
  check)    cmd_check ;;
  sanitize) sanitize_guard && echo "sanitize: clean" ;;  # CI gate 用（本体パス不要）
  apply)    cmd_apply ;;
  diff)     shift; cmd_diff "${1:-}" ;;
  stamp)    shift; cmd_stamp "${1:-}" ;;
  pack)     cmd_pack ;;
  *) echo "usage: kit-sync.sh {check|sanitize|apply|diff <kit_rel>|stamp <kit_rel|--all>|pack}"; exit 1 ;;
esac
