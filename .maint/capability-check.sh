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

# (3) dangling: capability が指す component が実在しない
echo "=== dangling（capability が実在しない component を指す）==="
dangling=0
while IFS= read -r c; do
  [ -e "$KIT_DIR/$c" ] || { echo "  ❌ $c"; dangling=1; fail=1; }
done <<< "$declared"
[ "$dangling" = 0 ] && echo "  ✅ なし（全 capability が実在 component を指す）"

# (4) id 一意性
echo "=== capability id 一意性 ==="
dup=$(jq -r '.capabilities[].id' "$MANIFEST" | sort | uniq -d)
[ -n "$dup" ] && { echo "  ❌ 重複 id: $dup"; fail=1; } || echo "  ✅ 一意"

# (5) policy_ref が実在 rule を指すか
echo "=== policy_ref の実在 ==="
prfail=0
while IFS= read -r r; do
  [ -z "$r" ] && continue
  [ -e "$KIT_DIR/$r" ] || { echo "  ❌ 実在しない policy_ref: $r"; prfail=1; fail=1; }
done < <(jq -r '[.capabilities[].policy_ref[]?, .policy_sources[].ref] | unique[]' "$MANIFEST")
[ "$prfail" = 0 ] && echo "  ✅ 全 policy_ref が実在"

echo ""
if [ "$fail" = 0 ]; then
  echo "✅ capability-check PASS（manifest と kit 構成が整合）"
else
  echo "❌ capability-check FAIL（上の不整合を解消せよ）"
fi
exit "$fail"
