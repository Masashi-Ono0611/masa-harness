---
allowed-tools: Bash(gh pr:*), Bash(gh api:*), Bash(gh repo:*), Bash(git diff:*), Bash(git log:*), Bash(git fetch:*), Bash(git rev-parse:*), Read(*), Fetch(*)
description: "指定PRのコードレビューを行う (arg: PR number or URL)"
parameters:
  - name: focus
    description: "レビュー重点（security, performance, logic 等）。未指定は全般レビュー"
    required: false
---

# 目的
指定されたPRのコードを**レビュアー視点**でレビューし、改善提案を行う。

# 入力検証

`$ARGUMENTS`が空・未定義の場合：
- エラー表示: `🔴 エラー: PRのnumberもしくはURLが必要です`
- 使用例表示: `例: /review:pr-review 42, /review:pr-review https://github.com/<owner>/<repo>/pull/42`
- **即座に実行を停止**

# 実行ルール

## Step 1: PR情報の収集

```shell
pr_number="$ARGUMENTS"
# URLの場合はnumberを抽出
pr_number=$(echo "$pr_number" | grep -oE '[0-9]+$' || echo "$pr_number")

echo "=== PR情報 ==="
gh pr view $pr_number --json title,body,baseRefName,headRefName,author,additions,deletions,changedFiles,labels,url

echo "=== 変更ファイル一覧 ==="
gh pr diff $pr_number --name-only

echo "=== 差分 ==="
gh pr diff $pr_number
```

## Step 2: コードベースの文脈理解
- 変更対象ファイルの周辺コード（変更されていない部分）を読み、文脈を把握する
- プロジェクトの CLAUDE.md があれば規約を確認する

## Step 3: レビュー実施

以下の観点でレビューを行う：

### 必須チェック
1. **バグ・ロジックエラー**: 境界条件、null/undefined、型の不整合、競合状態
2. **セキュリティ**: インジェクション、XSS、認証・認可の漏れ、秘密情報の露出
3. **データ整合性**: DB操作、トランザクション、マイグレーション

### 推奨チェック
4. **パフォーマンス**: N+1クエリ、不要な再レンダリング、メモリリーク、重い計算
5. **キャッシュ**: TTL 設定漏れによる stale データ、cache key の衝突・誤生成、invalidation 漏れ、無効化後も古い値が返る、ineffective なキャッシング戦略
6. **可読性・保守性**: 命名、責務分離、過度な複雑性
7. **テスト**: カバレッジ、エッジケース、テストの信頼性

### 文脈チェック
8. **設計一貫性**: 既存パターンとの整合、アーキテクチャ方針
9. **影響範囲**: 他機能へのデグレ、API互換性

## Step 4: レビュー結果の出力

以下のフォーマットで出力してください：

```markdown
# Code Review: PR #[番号] [タイトル]

## サマリー
（1-2行で変更の概要と全体的な評価）

## Critical（要修正）
| # | ファイル:行 | 問題 | 修正案 |
|---|-----------|------|-------|

## Warning（推奨修正）
| # | ファイル:行 | 問題 | 修正案 |
|---|-----------|------|-------|

## Suggestion（任意）
| # | ファイル:行 | 提案内容 |
|---|-----------|---------|

## 良い点
（コードの良い点があれば記載）

## 総合判断
- [ ] Approve（問題なし）
- [ ] Request Changes（Critical あり）
- [ ] Comment（Warning のみ）
```

## Step 5: GitHub にレビューを投稿するか確認
レビュー結果を表示した後、GitHub PR にコメントとして投稿するかユーザーに確認してください。
