---
allowed-tools: Bash(pwd), Bash(cd:*), Bash(echo:*), Bash(cat:*), Bash(jq:*), Bash(gh pr:*), Bash(gh repo:*), Bash(gh api:*), Bash(git branch:*), Bash(git commit:*), Bash(git diff:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git status:*), Read(*), Fetch(*)
description: "現在のブランチのPRレビューコメントを収集し、修正対応を行う"
parameters:
  - name: max_comments
    description: "最大取得件数（新しい順）。未指定は全件"
    required: false
---

# 1) ブランチ→PR番号を特定

```shell
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -z "${branch:-}" ] || [ "$branch" = "HEAD" ]; then
  echo "❌ Gitブランチが取得できません（detached HEAD など）。" >&2
  exit 1
fi

pr_number="$(gh pr view --json number --jq .number 2>/dev/null || true)"
if [ -z "${pr_number:-}" ] || [ "$pr_number" = "null" ]; then
  pr_number="$(gh pr list --head "$branch" --state all --json number --jq '.[0].number' 2>/dev/null || true)"
fi
if [ -z "${pr_number:-}" ] || [ "$pr_number" = "null" ]; then
  echo "❌ ブランチ '${branch}' に紐づくPRが見つかりません。" >&2
  exit 1
fi
echo $pr_number
```

# 2) 付加情報（リポジトリ/PRタイトル/base/head）

```shell
repo_full="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo $repo_full
pr_meta="$(gh pr view ${pr_number} --json title,baseRefName,headRefName,url,author --jq '{title, base: .baseRefName, head: .headRefName, url, author: .author.login}')"
echo $pr_meta
```

# 3) レビューコメントを取得（新しい順）

```shell
comments_json="$(gh api repos/:owner/:repo/pulls/${pr_number}/comments --paginate \
  | jq -s 'flatten | sort_by(.created_at) | reverse' )"

if [ -n "${max_comments:-}" ]; then
  comments_json="$(printf '%s' "$comments_json" | jq ".[0:${max_comments}]")"
fi
echo $comments_json
```

# 4) Markdownの"対応用プロンプト"を組み立て

```shell
title=$(printf '%s' "$pr_meta" | jq -r .title)
base=$(printf '%s' "$pr_meta" | jq -r .base)
head=$(printf '%s' "$pr_meta" | jq -r .head)
url=$(printf '%s' "$pr_meta" | jq -r .url)
author=$(printf '%s' "$pr_meta" | jq -r .author)

echo "# PRレビュー対応プロンプト"
echo
echo "対象: **${repo_full}** / **PR #${pr_number}**"
echo "- タイトル: ${title}"
echo "- ブランチ: ${head} → ${base}"
echo "- 作成者: ${author}"
echo "- URL: ${url}"
echo
echo "## あなたの役割"
cat <<'EOF'
あなたはソフトウェアレビュアー兼修正実装者です。以下のレビューコメントに**一括で対応**してください。

### ゴール
1. 各コメントの意図を要約
2. 具体的な修正方針を提示（影響範囲・代替案があれば併記）
3. **パッチ（diff）**を生成（可能な範囲で最小差分）
4. テストや型・Lint・パフォーマンス観点の追補があれば提案
5. 返信テンプレート（レビュースレッドに返す文面）を作成

### 制約
- 既存の設計・命名規則に合わせる
- 破壊的変更は要理由と移行策
- セキュリティと可読性を優先
- 変更が広範囲な場合は、段階的コミット案を提案

### 出力フォーマット
1. **対応サマリ（要約）**
2. **ファイル別対応案**（見出し：`path:line`）
3. **統合パッチ**（```diff で囲む）
4. **追補タスク**（チェックリスト）
5. **返信文例**（各コメント向け）
EOF
echo
echo "## レビューコメント（新しい順）"
echo

# 各コメントをMarkdownで列挙
printf '%s' "$comments_json" | jq -r '
  to_entries[] as $e
  | $e.value
  | "### " + (.path // "(no-file)") + ":" + ((.line // .original_line // 0|tostring))
    + "  \n**author:** " + (.user.login // "unknown")
    + " | **at:** " + (.created_at // "")
    + " | **side:** " + (.side // "")
    + " | **url:** " + (.html_url // "") + "\n"
    + "**comment:**\n"
    + (.body // "" ) + "\n\n"
    + "**diff context:**\n```diff\n" + ((.diff_hunk // "")|gsub("\r";"")) + "\n```\n"
    + "---\n"
'
```

# 5) レビュー対応

出力されたプロンプトを利用して、レビューコメントに対する対応を行ってください。
