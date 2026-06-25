---
allowed-tools: Bash(git checkout:*), Bash(git switch:*), Bash(git add:*), Bash(git status:*), Bash(git push:*), Bash(git commit:*), Bash(git diff:*), Bash(git log:*), Bash(git branch:*), Bash(gh pr create:*)
description: "変更をコミットし、プッシュしてPRを作成する"
---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -5`

## Your task

上記の変更内容を分析し、以下を実行してください：

1. **ブランチ確認**: main/master ブランチの場合は適切な feature ブランチを作成
2. **コミット**: 変更内容に基づいた適切なコミットメッセージで単一コミットを作成
   - コミットメッセージは変更の「why」を重視
   - 日本語 or 英語はリポジトリの既存コミットスタイルに合わせる
3. **プッシュ**: ブランチを origin にプッシュ
4. **PR作成**: `gh pr create` でPRを作成
   - タイトルは70文字以内
   - 本文にはサマリーとテストプランを含める

**重要**: 上記すべてを単一メッセージ内のツールコールで実行すること。

## PR作成後: CI/レビュー watch の提案（自動実行しない）

PR作成が完了したら、PR番号を使って以下を**1行で提案**する（実行するかはユーザー判断）:

```
/loop check whether CI passed on PR #<番号> and address review comments; stop when CI is green and no open review threads
```

- self-pace（間隔指定なし）で完了時に自動停止する。**stop 条件を必ず含める**（裸の無限ループにしない＝token burn 防止）
- 長時間想定なら別セッション/別ターミナルで走らせる（本セッション占有を避ける）
