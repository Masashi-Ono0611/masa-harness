#!/usr/bin/env bash
# masa-harness インストーラ（curl | bash の唯一の入口）
#
# 初回も更新も、同じ 1 行でOK:
#   curl -fsSL https://raw.githubusercontent.com/OWNER/masa-harness/main/install.sh | bash
#
# 既存設定がある人が「全部 masashi 版」にしたいとき:
#   curl -fsSL https://raw.githubusercontent.com/OWNER/masa-harness/main/install.sh | MASA_MODE=overwrite bash
#
# このスクリプトは repo を ~/.masa-harness に取得（clone / pull）してから
# masa-harness-kit/setup.sh を呼ぶだけ。実際の展開ロジック・安全判定は setup.sh 側にある。
#
# 環境変数:
#   MASA_MODE   safe|overwrite … setup.sh にそのまま渡る（既定は自動判定）
#   MASA_REPO   OWNER/repo      … 取得元（既定 OWNER/masa-harness）
#   MASA_BRANCH branch          … 取得ブランチ（既定 main）
#   MASA_HOME   path            … 取得先（既定 ~/.masa-harness）

set -euo pipefail

REPO_SLUG="${MASA_REPO:-OWNER/masa-harness}"
REPO_URL="https://github.com/${REPO_SLUG}.git"
BRANCH="${MASA_BRANCH:-main}"
DEST="${MASA_HOME:-${HOME}/.masa-harness}"

echo "=== masa-harness インストーラ ==="

if ! command -v git >/dev/null 2>&1; then
  echo "✗ git が見つかりません。https://git-scm.com/ から入れて再実行してください。" >&2
  echo "  （git を使わない場合は GitHub の最新 Release から .tar.gz を落として、" >&2
  echo "    解凍後に masa-harness-kit/ で 'bash setup.sh' を実行してください）" >&2
  exit 1
fi

# 取得: 無ければ clone、あれば最新へ更新（~/.masa-harness は本ツール専用キャッシュなので reset で揃える）
if [ -d "${DEST}/.git" ]; then
  echo "更新を取得中: ${DEST}"
  git -C "${DEST}" fetch --depth 1 origin "${BRANCH}" -q
  git -C "${DEST}" reset --hard "origin/${BRANCH}" -q
else
  echo "取得中: ${REPO_URL} (${BRANCH}) → ${DEST}"
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${DEST}" -q
fi

VER="$(cat "${DEST}/masa-harness-kit/VERSION" 2>/dev/null || echo unknown)"
echo "kit バージョン: ${VER}"
echo ""

# 展開（setup.sh が fresh/safe/overwrite を自動判定。MASA_MODE は環境変数として継承される）
exec bash "${DEST}/masa-harness-kit/setup.sh"
