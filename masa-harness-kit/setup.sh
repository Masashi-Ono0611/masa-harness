#!/usr/bin/env bash
# masa-harness-kit セットアップ（冪等・再実行で更新可能）
#
# Claude Code の harness 設定一式を ~/.claude/ に展開する。
# 「既存の harness を壊さない」ことを最優先にした 3 モードで動く:
#
#   fresh      … 既存 harness なし → そのまま全展開（上書きの危険なし）
#   safe       … 既存 harness あり（初回遭遇） → 何も書かず差分レポートだけ出す【default】
#   overwrite  … MASA_MODE=overwrite で明示 → タイムスタンプ backup を取ってから配置
#
# 設定ファイル（CLAUDE.md / settings.json / recurring-tasks.json）は個人化されやすいので、
# overwrite を明示しない限り自動上書きしない。skills / rules / hooks は kit の更新を取り込む
# （変更されていれば backup を取ってから更新）。上書き前のファイルは消さず .bak-<日時> に退避する。
#
# 「全部 masashi 版」ではなく「良いとこだけ取り込む」なら、overwrite せず Claude Code で
# `masa-harness-audit` skill を使う（差分を推奨理由付きで提示し、承認分だけ反映）。
#
# 使い方:
#   bash setup.sh                    # 既存ありなら safe（レポートのみ）、なければ fresh
#   MASA_MODE=overwrite bash setup.sh
#   MASA_MODE=safe bash setup.sh     # いつでも強制的にレポートのみ（プレビュー）

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
META_DIR="${CLAUDE_DIR}/.masa-harness"
MANIFEST="${META_DIR}/manifest.txt"     # 前回この kit が設置した target 一覧（削除追従用）
VERSION_FILE="${META_DIR}/version"
REPORT="${META_DIR}/AUDIT-REPORT.md"
STAMP="$(date +%Y%m%d-%H%M%S)"
KIT_VERSION="$(cat "${KIT_DIR}/VERSION" 2>/dev/null || echo unknown)"

# --- 設定ファイル（kit 相対 → ~/.claude 相対）。個人化されやすく、上書きは慎重に扱う ---
CONFIG_SRC=( "CLAUDE.md.template" "settings.json.template" "state/recurring-tasks.json.template" )
CONFIG_DST=( "CLAUDE.md"          "settings.json"          "state/recurring-tasks.json" )

sha() {  # sha <file> -> sha256（macOS/Linux 両対応）
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# kit が管理する「ツリー配下ファイル」(rules/hooks/skills) を kit 相対パスで列挙
list_tree_files() {
  ( cd "$KIT_DIR" && find rules hooks skills -type f 2>/dev/null \
      ! -name '.DS_Store' ! -name '*.pyc' ! -path '*/__pycache__/*' | sort )
}

# kit 相対パス → ~/.claude 相対 target に変換（rules/hooks/skills はそのまま、config は対応表）
kit_to_target() {
  local k="$1" i
  for i in "${!CONFIG_SRC[@]}"; do
    if [ "$k" = "${CONFIG_SRC[$i]}" ]; then printf '%s\n' "${CONFIG_DST[$i]}"; return; fi
  done
  printf '%s\n' "$k"   # rules/… hooks/… skills/… は同じ相対パス
}

# 既存 harness 検出
detect_existing() {
  [ -f "${CLAUDE_DIR}/CLAUDE.md" ] && return 0
  [ -f "${CLAUDE_DIR}/settings.json" ] && return 0
  [ -n "$(ls -A "${CLAUDE_DIR}/skills" 2>/dev/null || true)" ] && return 0
  return 1
}

# ---- モード解決 -------------------------------------------------------------
EXISTING=no;  detect_existing && EXISTING=yes
PRIOR_KIT=no; [ -f "$VERSION_FILE" ] && PRIOR_KIT=yes
PREV_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo none)"

MODE="${MASA_MODE:-}"
if [ -z "$MODE" ]; then
  if [ "$EXISTING" = no ]; then MODE=fresh          # 失うものがない
  elif [ "$PRIOR_KIT" = yes ]; then MODE=install    # この kit の再実行（更新）
  else MODE=safe                                     # 既存 harness と初遭遇 → 壊さない
  fi
fi
WRITE=yes; [ "$MODE" = safe ] && WRITE=no           # safe だけ「書かない」

echo "=== masa-harness-kit セットアップ (v${KIT_VERSION}) ==="
echo "モード: ${MODE}  /  既存 harness: ${EXISTING}  /  前回 kit: ${PREV_VERSION}"
echo ""

# ---- safe モード: 差分レポートだけ出して終了（~/.claude は一切触らない）-----
if [ "$WRITE" = no ]; then
  mkdir -p "$META_DIR"
  {
    echo "# masa-harness-kit 差分レポート"
    echo ""
    echo "- kit バージョン: \`${KIT_VERSION}\`"
    echo "- 生成: ${STAMP}"
    echo "- あなたの \`~/.claude\` は **一切変更していません**（読み取りのみ）。"
    echo ""
    echo "取り込み方を選んでください:"
    echo ""
    echo "- **全部 masashi 版にする** → \`MASA_MODE=overwrite bash setup.sh\`（既存はタイムスタンプ backup）"
    echo "- **良いとこだけ取り込む** → Claude Code で「masa-harness を audit して良い差分だけ取り込んで」（\`masa-harness-audit\` skill）"
    echo ""
    echo "## 設定ファイル（個人化されやすい・慎重に）"
    echo ""
    for i in "${!CONFIG_SRC[@]}"; do
      src="${KIT_DIR}/${CONFIG_SRC[$i]}"; dst="${CLAUDE_DIR}/${CONFIG_DST[$i]}"
      [ -f "$src" ] || continue
      if [ ! -e "$dst" ]; then echo "- 🟢 NEW   \`${CONFIG_DST[$i]}\`（あなたにまだ無い）"
      elif [ "$(sha "$src")" = "$(sha "$dst")" ]; then echo "- ⚪️ SAME  \`${CONFIG_DST[$i]}\`"
      else echo "- 🟡 DIFF  \`${CONFIG_DST[$i]}\`（あなたの内容と違う＝あなたの編集を残します）"; fi
    done
    echo ""
    echo "## skills / rules / hooks（NEW と DIFF のみ表示）"
    echo ""
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      t="$(kit_to_target "$k")"; src="${KIT_DIR}/${k}"; dst="${CLAUDE_DIR}/${t}"
      if [ ! -e "$dst" ]; then echo "- 🟢 NEW   \`${t}\`"
      elif [ "$(sha "$src")" = "$(sha "$dst")" ]; then :   # SAME は省略
      else echo "- 🟡 DIFF  \`${t}\`"; fi
    done < <(list_tree_files)
  } > "$REPORT"

  echo "⚠️  既存の Claude Code 設定を検出しました。安全のため **何も上書きしていません**。"
  echo ""
  echo "差分レポート: ${REPORT}"
  echo ""
  echo "取り込み方は 2 つ:"
  echo "  (A) 全部 masashi 版にする   → MASA_MODE=overwrite bash setup.sh"
  echo "  (B) 良いとこだけ取り込む    → Claude Code で『masa-harness を audit して良い差分だけ取り込んで』"
  echo ""
  echo "（B はあなたの設定を尊重しつつ、kit の良い差分だけを推奨理由付きで選んで反映します）"
  exit 0
fi

# ---- 書き込みモード（fresh / install / overwrite）---------------------------
mkdir -p "$META_DIR" "${CLAUDE_DIR}/rules" "${CLAUDE_DIR}/hooks" "${CLAUDE_DIR}/skills" "${CLAUDE_DIR}/state"

n_new=0 n_upd=0 n_kept=0 n_bak=0 n_del=0
NEW_MANIFEST="$(mktemp)"

backup() {  # backup <target> … 削除せず .bak-<日時> へ退避
  cp "$1" "$1.bak-${STAMP}"; n_bak=$((n_bak+1))
  echo "  backup: $(basename "$1") → $(basename "$1").bak-${STAMP}"
}

# 設定ファイル: 無→入れる / 同→何もしない / 異→overwrite 時のみ backup+配置、ほかは「あなたのを残す」
for i in "${!CONFIG_SRC[@]}"; do
  src="${KIT_DIR}/${CONFIG_SRC[$i]}"; rel="${CONFIG_DST[$i]}"; dst="${CLAUDE_DIR}/${rel}"
  [ -f "$src" ] || continue
  mkdir -p "$(dirname "$dst")"
  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"; echo "  + ${rel}"; n_new=$((n_new+1))
  elif [ "$(sha "$src")" = "$(sha "$dst")" ]; then
    :
  elif [ "$MODE" = overwrite ]; then
    backup "$dst"; cp "$src" "$dst"; echo "  ~ ${rel}（上書き）"; n_upd=$((n_upd+1))
  else
    echo "  = ${rel}（あなたの内容を残しました。masashi 版にするなら overwrite か audit skill）"; n_kept=$((n_kept+1))
  fi
  printf '%s\n' "$rel" >> "$NEW_MANIFEST"
done

# skills / rules / hooks: kit-owned。更新を取り込む（違えば backup→更新）
while IFS= read -r k; do
  [ -z "$k" ] && continue
  rel="$(kit_to_target "$k")"; src="${KIT_DIR}/${k}"; dst="${CLAUDE_DIR}/${rel}"
  mkdir -p "$(dirname "$dst")"
  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"; n_new=$((n_new+1))
  elif [ "$(sha "$src")" = "$(sha "$dst")" ]; then
    :
  else
    backup "$dst"; cp "$src" "$dst"; n_upd=$((n_upd+1))
  fi
  printf '%s\n' "$rel" >> "$NEW_MANIFEST"
done < <(list_tree_files)

# hooks に実行ビット
chmod +x "${CLAUDE_DIR}/hooks/"*.sh "${CLAUDE_DIR}/hooks/"*.py 2>/dev/null || true

# 削除追従: 前回 manifest にあって今回 kit に無い「ツリー配下」を quarantine へ退避
# （config は消さない・hard rm しない。退避先は ~/.claude/.masa-harness/removed-<日時>/ に元パスを保つ）
QUARANTINE="${META_DIR}/removed-${STAMP}"
if [ -f "$MANIFEST" ]; then
  while IFS= read -r oldrel; do
    [ -z "$oldrel" ] && continue
    case "$oldrel" in rules/*|hooks/*|skills/*) ;; *) continue ;; esac
    if ! grep -qxF "$oldrel" "$NEW_MANIFEST"; then
      target="${CLAUDE_DIR}/${oldrel}"
      if [ -e "$target" ]; then
        q="${QUARANTINE}/${oldrel}"; mkdir -p "$(dirname "$q")"; mv "$target" "$q"
        echo "  - ${oldrel}（kit から削除 → .masa-harness/removed-${STAMP}/ へ退避）"; n_del=$((n_del+1))
      fi
    fi
  done < "$MANIFEST"
  # 退避で空になった skill/rule ディレクトリを刈る（トップの skills/rules/hooks 自体は残す）
  for d in skills rules hooks; do
    find "${CLAUDE_DIR}/${d}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  done
fi

sort -u "$NEW_MANIFEST" > "$MANIFEST"; rm -f "$NEW_MANIFEST"
printf '%s\n' "$KIT_VERSION" > "$VERSION_FILE"

# governance-gate.py 構文チェック（__pycache__ を作らない ast.parse）
echo ""
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${CLAUDE_DIR}/hooks/governance-gate.py" 2>/dev/null; then
    echo "  governance-gate.py: 構文OK"
  else
    echo "  ⚠️ governance-gate.py: 構文エラー（要確認）"
  fi
else
  echo "  ⚠️ python3 が見つかりません。governance-gate.py（危険コマンド BLOCK）は python3 が無いと動きません。"
fi

echo ""
echo "=== 完了: v${PREV_VERSION} → v${KIT_VERSION} ==="
echo "  新規 ${n_new} / 更新 ${n_upd} / 据置 ${n_kept} / 退避 ${n_del} / backup ${n_bak}"
[ "$n_bak" -gt 0 ] && echo "  上書き前のファイルは *.bak-${STAMP} に退避済み（不要なら削除可）"
echo ""
echo "=== 次の手順（手動・初回のみ）==="
echo "1. ${CLAUDE_DIR}/CLAUDE.md を開き、{{...}} プレースホルダを自分の環境に記入"
echo "2. 使わない言語の '@~/.claude/rules/*.md' import 行を CLAUDE.md から削除"
echo "3. settings.json の hooks command で \$HOME が展開されるか確認（効かない環境は絶対パスに置換）"
echo ""
echo "Claude Code を再起動してください。"
