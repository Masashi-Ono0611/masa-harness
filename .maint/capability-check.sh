#!/usr/bin/env bash
# capability-check — capability-manifest.json と kit が ship する component の整合を検証する。
#
# kit-sync.sh が「ファイル同期 drift（hash）」を見るのに対し、本スクリプトは
# 「capability-layer drift」を見る = ship した skill/hook に capability 宣言があるか、
# capability が実在しない component を指していないか、id が一意か。
# config-hygiene owner マップの機械可読版（capability-manifest.json）の完全性ゲート。
#
# 使い方:  bash capability-check.sh        # read-only・exit 1 で fail
set -euo pipefail

MAINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$MAINT_DIR/../masa-harness-kit" && pwd)"
MANIFEST="$KIT_DIR/capability-manifest.json"

command -v jq >/dev/null || { echo "❌ jq 不在"; exit 2; }
[ -f "$MANIFEST" ] || { echo "❌ manifest 不在: $MANIFEST"; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { echo "❌ manifest が不正な JSON"; exit 2; }

fail=0

# (0) version 不変条件: manifest.version は masa-harness-kit/VERSION と一致せねばならない
#     （bump 漏れで manifest が stale な release metadata を advertise するのを防ぐ）
echo "=== version 整合（manifest.version == VERSION）==="
kit_ver="$(tr -d '[:space:]' < "$KIT_DIR/VERSION" 2>/dev/null)"
man_ver="$(jq -r '.version' "$MANIFEST")"
if [ "$kit_ver" = "$man_ver" ]; then
  echo "  ✅ 一致 (${man_ver})"
else
  echo "  ❌ 不一致: manifest=$man_ver / VERSION=$kit_ver"
  fail=1
fi

# (1) ship 対象 component を列挙（skills=ディレクトリ / hooks=ファイル）
shipped=()
for d in "$KIT_DIR"/skills/*/; do [ -d "$d" ] && shipped+=("skills/$(basename "$d")"); done
for f in "$KIT_DIR"/hooks/*; do [ -f "$f" ] && shipped+=("hooks/$(basename "$f")"); done

# manifest が宣言する component 一覧
declared=$(jq -r '.capabilities[].component' "$MANIFEST")

# (2) orphan: ship したが capability 宣言が無い component
echo "=== orphan（ship 済だが capability 未宣言）==="
orphan=0
for c in "${shipped[@]}"; do
  printf '%s\n' "$declared" | grep -qxF "$c" || { echo "  ❌ $c"; orphan=1; fail=1; }
done
[ "$orphan" = 0 ] && echo "  ✅ なし（全 ship component に capability 宣言あり）"

# (3) dangling: capability の component は「実在する ship 済 skills/<name> or hooks/<name>」でなければならない。
#     単なる path 存在チェックだと ../ 脱出や非 ship ファイルを通す（fails-open）ので shape を固定する。
echo "=== dangling（capability が ship 済 skills/* | hooks/* を指すか）==="
dangling=0
while IFS= read -r c; do
  [ -z "$c" ] && continue
  case "$c" in
    skills/*/*|hooks/*/*|*/../*|../*) echo "  ❌ 不正な component 形（skills/<name> | hooks/<name> のみ可）: $c"; dangling=1; fail=1; continue ;;
    skills/*) [ -d "$KIT_DIR/$c" ] || { echo "  ❌ 実在しない skill: $c"; dangling=1; fail=1; } ;;
    hooks/*)  [ -f "$KIT_DIR/$c" ] || { echo "  ❌ 実在しない hook: $c"; dangling=1; fail=1; } ;;
    *) echo "  ❌ skills/ でも hooks/ でもない component: $c"; dangling=1; fail=1 ;;
  esac
done <<< "$declared"
[ "$dangling" = 0 ] && echo "  ✅ なし（全 capability が ship 済 skills/* | hooks/* を指す）"

# (4) id 一意性
echo "=== capability id 一意性 ==="
dup=$(jq -r '.capabilities[].id' "$MANIFEST" | sort | uniq -d)
[ -n "$dup" ] && { echo "  ❌ 重複 id: $dup"; fail=1; } || echo "  ✅ 一意"

# (5) policy_ref は「実在する rules/<name>」でなければならない（任意パス/../ を通さない）
echo "=== policy_ref（実在する rules/* か）==="
prfail=0
while IFS= read -r r; do
  [ -z "$r" ] && continue
  case "$r" in
    rules/*/*|*/../*|../*) echo "  ❌ 不正な policy_ref 形（rules/<name> のみ可）: $r"; prfail=1; fail=1; continue ;;
    rules/*) [ -f "$KIT_DIR/$r" ] || { echo "  ❌ 実在しない policy_ref: $r"; prfail=1; fail=1; } ;;
    *) echo "  ❌ rules/ 配下でない policy_ref: $r"; prfail=1; fail=1 ;;
  esac
done < <(jq -r '[.capabilities[].policy_ref[]?, .policy_sources[].ref] | unique[]' "$MANIFEST")
[ "$prfail" = 0 ] && echo "  ✅ 全 policy_ref が rules/* 実在"

# (6) role は roles vocab 内でなければならない（宣言外の role を防ぐ）
echo "=== role が宣言 vocab 内か ==="
rolefail=0
vocab="$(jq -r '.roles | keys[]' "$MANIFEST")"
while IFS= read -r role; do
  [ -z "$role" ] && continue
  printf '%s\n' "$vocab" | grep -qxF "$role" || { echo "  ❌ vocab 外の role: $role"; rolefail=1; fail=1; }
done < <(jq -r '.capabilities[].role' "$MANIFEST")
[ "$rolefail" = 0 ] && echo "  ✅ 全 role が roles vocab 内"

echo ""
if [ "$fail" = 0 ]; then
  echo "✅ capability-check PASS（manifest と kit 構成が整合）"
else
  echo "❌ capability-check FAIL（上の不整合を解消せよ）"
fi
exit "$fail"
