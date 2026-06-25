---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git status:*), Bash(git branch:*), Bash(codex review:*), Bash(codex exec:*), Bash(codex login status:*), Bash(which codex:*), Bash(agy:*), Bash(which agy:*)
description: "複数AIモデル（Codex/OpenAI → Antigravity/Google fallback + Claude）でセルフコードレビューを実行"
parameters:
  - name: base
    description: "比較対象のベースブランチ（デフォルト: main）"
    required: false
---

# マルチモデル セルフコードレビュー

PR を出す前に、コードを **第二モデル（Codex を primary、Antigravity CLI `agy` を fallback）** と **Claude** の最低 2 つで自動レビューし、両者の指摘を統合レポートにまとめる。両モデルが一致して指摘した箇所は信頼度が高く、優先対応すべきポイント。

> **外部CLIは任意**。Codex も Antigravity も入っていなければ Claude 単独で動く（その旨をレポートに明記する）。Codex / Antigravity の導入・認証・トラブルシュートは [`docs/multi-model-review.md`](https://github.com/Masashi-Ono0611/masa-harness/blob/main/masa-harness-kit/docs/multi-model-review.md) を参照。
>
> **任意の追加レビュア**: マルチエージェント・オーケストレータ系（例: Sakana fugu）を第三の対戦相手として足してもよい。付加価値は「モデル多様性」でなく「オーケストレーション/合成 + 大 context」。ただし多くはサブスク/従量課金が要るので**必須ではない**＝無料チェーン（Codex/agy/Claude）で multi-model は成立する。足すなら raw API helper を `<skill-root>/bin/` に置き、鍵は環境変数（コミットしない）で渡す。
>
> **repo ごとに PR フロー全体を自動化したい場合**: 本 command を呼ぶ orchestrator skill を各 repo の `.claude/skills/<repo>-multi-model-review/` に作る（PR 作成・レビュー・マージまで一気通貫にしたいとき）。本 command 単体は「PR 作成前の第二モデル + Claude レビュー」だけを担う。

## モデルの優先順位

1. **Primary**: Codex CLI (`codex review`)。**ただし大型 diff (>~30 files) は agentic な `codex review` でなく chunked `codex exec` single-shot**（Step 2a「大型 diff」参照、クォータ枯渇回避）
2. **Fallback**: Antigravity CLI (`agy -p`、Gemini 3.1 Pro) — Codex usage limit 等で primary 不能時。※旧 Gemini CLI は 2026-06-18 に無料/AI Pro/Ultra 枠が停止し Antigravity CLI へ移行（無料 Antigravity Starter Quota で動く）
3. **必ず動く**: Claude（この session）

直列ではなく、**第二モデル枠で 1 つだけ走らせる**設計。Codex 復活待ちで multi-model review をスキップしないこと（fallback 連鎖 Codex→Antigravity CLI(agy)→Gemini bot→Claude で即進む）。

> **モデル指定（SoT・"腐る軸"）**: review に使うモデルは「入力検証」ブロック冒頭の `CODEX_REVIEW_MODEL` / `CODEX_REVIEW_EFFORT` / `AGY_REVIEW_MODEL` で一元管理する。codex session の既定モデルに依存させず、review を明示的に強モデルへ固定する（session を別作業で安いモデルへ切替えても review 品質を落とさない）。これは `agent-model-routing.md` の「外部モデル review のルーティング」と同じ「腐る軸（モデル名）を1箇所に隔離」する思想。別ベンダー CLI なので Claude Code のアップデートでは自動追従しない＝モデル世代が変わったらここだけ更新する。

## 前提条件

少なくとも片方が動けば multi-model 成立:

- **Codex (primary)**: Codex CLI 導入済（OpenAI 直 `codex login`、または ChatGPT Plus/Pro アカウント）
- **Antigravity CLI (fallback)**: `agy` 利用可。導入 = `curl -fsSL https://antigravity.google/cli/install.sh | bash`、認証 = **`agy` を素で1回起動して Google Sign-In**（無料 Antigravity Starter Quota で動作・keyring 保存）。利用モデルは `agy models` で確認

両方不能なら Claude セルフ単独で進め、その旨を統合レポートに明記。詳細な導入手順は [`docs/multi-model-review.md`](https://github.com/Masashi-Ono0611/masa-harness/blob/main/masa-harness-kit/docs/multi-model-review.md)。

## 入力検証

```shell
# === レビューモデル SoT（"腐る軸"＝モデル名はここだけ更新する）===
# review のモデルを codex session 既定から decouple し、明示的に強モデルへ固定する。
# session を別作業で安いモデルに切替えても review 品質は落ちない。
# 値は執筆時点の例。最新のモデル名は `codex --help` / `agy models` で確認して各自更新する。
CODEX_REVIEW_MODEL="gpt-5.5"              # codex review/exec に -c model で渡す強モデル
CODEX_REVIEW_EFFORT="high"               # 推論深さ。最大は xhigh（agentic review は quota とのバランスで high 既定）
AGY_REVIEW_MODEL="Gemini 3.1 Pro (High)"  # Antigravity CLI(agy) fallback の強モデル。一覧は `agy models`

# Codex CLI チェック
codex_available=false
if which codex > /dev/null 2>&1 && codex login status > /dev/null 2>&1; then
  codex_available=true
fi

# Antigravity CLI (agy) チェック（疎通まで）
agy_available=false
if which agy > /dev/null 2>&1; then
  if echo "" | agy --model "$AGY_REVIEW_MODEL" -p "Reply with exactly: OK" 2>&1 | tail -1 | grep -q "^OK$"; then
    agy_available=true
  fi
fi

if ! $codex_available && ! $agy_available; then
  echo "⚠️  Codex / Antigravity(agy) どちらも使用不可。Claude セルフ単独で続行します。"
  echo "（Codex: codex login / Antigravity: agy を素で1回起動し Google Sign-In で復旧可能）"
fi

if $codex_available; then
  echo "✅ 第二モデル: Codex (primary) を使用"
elif $agy_available; then
  echo "✅ 第二モデル: Antigravity CLI (fallback・Gemini 3.1 Pro) を使用"
fi
```

## 実行ルール

### Step 1: 変更内容の収集

ベースブランチとの差分を収集します。

```shell
base_branch="${base:-main}"
current_branch="$(git rev-parse --abbrev-ref HEAD)"

echo "=== レビュー対象 ==="
echo "ブランチ: ${current_branch} → ${base_branch}"
echo ""

echo "=== コミット履歴 ==="
git log --oneline "${base_branch}..HEAD" 2>/dev/null || echo "(差分なし)"
echo ""

echo "=== 変更ファイル ==="
git diff --name-status "${base_branch}...HEAD"
```

差分がない場合は「レビュー対象の変更がありません」と伝えて終了してください。

### Step 2a: Codex（Primary）によるレビュー

`codex_available=true` の場合のみ実行。`codex review` の `--base` とプロンプト引数は同時使用不可なので `--base` 単独で。

```shell
if $codex_available; then
  echo "Codex review を実行中..."
  codex review -c model="$CODEX_REVIEW_MODEL" -c model_reasoning_effort="$CODEX_REVIEW_EFFORT" --base "${base_branch}" 2>&1 | tee /tmp/codex-review.md
  echo ""
  echo "=== Codex レビュー完了 ==="
fi
```

**usage limit エラー検出**: 以下のメッセージが出たら primary 不能扱いで Step 2b へ。

```
ERROR: You've hit your usage limit. ... try again at <YYYY-MM-DD HH:MM>.
```

Codex 復活時刻を統合レポートの footer に記録（後追い review に使用）。

#### ⚠️ 大型 diff (>~30 files) は `codex review` でなくchunked `codex exec` single-shot

`codex review --base` は **agentic**（レビュー中に repo を `sed`/`find`/`git diff` で自己探索）で、大型 diff だと探索でトークンを食い尽くし **usage limit で途中中断**しやすい（Release PR / 大型 feature でクォータ枯渇の実績）。**枯渇を避けたいときは絞り込み single-shot を chunk 分割**で:

1. 対象を**高リスクのコードだけ**に絞る（docs / lockfile / 生成物 / i18n / UI装飾は除外）
2. focused diff を **stdin で inline** に渡し、プロンプトに「**diff のみレビュー・ファイル探索/コマンド実行禁止**」を明記（agentic 探索を抑止）
3. ~500 行/chunk で 2-3 分割、**chunk 間で usage limit エラー無しを確認**してから次へ（一気にキャパオーバーを防ぐ）

```shell
DIFF=$(git diff "${base_branch}"...HEAD -- <高リスク code files: authz / 破壊的操作 / fail-closed gate / 入力検証>)
echo "$DIFF" | codex exec -c model="$CODEX_REVIEW_MODEL" -c model_reasoning_effort="$CODEX_REVIEW_EFFORT" -s read-only "Review ONLY the diff in the <stdin> block. Do NOT run commands, read files, or explore the repo. Grade Critical/Warning/Suggestion with file:hunk. Focus: authz/tenant-isolation, fail-open gates, null/boundary, destructive-action safety. Sections ## Critical / ## Warning / ## Suggestion (None. if empty). Terse."
```
実測（72 files の大型 Release PR）: agentic `codex review` は全クォータ枯渇 / chunked `codex exec` は 2 chunk 計 ~38k tokens で完走。Claude 未検出の存在オラクル・CSV partial-state を Codex が拾えた。

#### モデル上限の fallback 連鎖（第二モデルが全滅しうる）

Codex usage limit → **Antigravity CLI (`agy`)**（`agy --model "Gemini 3.1 Pro (High)" -p`。無料 Antigravity Starter Quota で動作。quota 切れなら次へ）→ **Gemini bot**（PR がある repo なら `/gemini review` コメントで起動・daily quota 制・quota 切れ時 ~24h で復活）→ **Claude**（必ず動く）。CLI 全滅でも Claude + Gemini bot で 2 モデル成立。PR を「マージ直前で停止」する運用なら Gemini bot レビューは async で merge 前に着けばよい。

### Step 2b: Antigravity CLI（Fallback）によるレビュー

Codex が動かなかった、または途中で usage limit になった場合のみ実行。

```shell
if $agy_available && [ ! -s /tmp/codex-review.md ]; then
  echo "Antigravity (agy) fallback review を実行中..."
  git diff "${base_branch}...HEAD" | agy --model "$AGY_REVIEW_MODEL" -p "$(cat <<'PROMPT'
You are reviewing a code diff for a software project. Grade each issue you find as **Critical / Warning / Suggestion**. Be terse — bullet points only, no preamble.

Check for:
1. Bugs / logic errors: boundary conditions, null/undefined, type mismatches
2. Security: injection / XSS / OWASP Top 10 / credential leakage / IAM over-privilege
3. Performance: N+1, unnecessary re-renders, memory leaks, blocking I/O on hot paths
4. Maintainability: complex conditionals, magic numbers, separation of concerns
5. Tests: coverage gaps, missing edge cases
6. Project conventions: style consistency with existing code

Output sections:
## Critical
## Warning
## Suggestion

If none in a section, write "None.".
PROMPT
)" 2>&1 | tee /tmp/agy-review.md
  echo ""
  echo "=== Antigravity (agy) レビュー完了 ==="
fi
```

### Step 3: Claude によるレビュー

あなた（Claude）は、以下のコマンドで変更差分を取得し、独自にレビューしてください。

```shell
git diff "${base_branch}...HEAD"
```

**レビュー観点:**

1. **バグ・ロジックエラー**: 境界条件、null/undefined、型の不整合
2. **セキュリティ**: インジェクション、XSS、認証・認可の漏れ（OWASP Top 10）
3. **パフォーマンス**: N+1クエリ、不要な再レンダリング、メモリリーク
4. **可読性・保守性**: 複雑な条件分岐、マジックナンバー、責務の分離
5. **テスト**: テストカバレッジの不足、エッジケース
6. **プロジェクト規約**: 既存のコーディングスタイル・パターンとの一貫性

### Step 4: 統合レビューレポートの出力

Step 2a / 2b / 3 の結果を以下のフォーマットで統合してください。

**出力フォーマット:**

```markdown
# マルチモデル セルフレビュー結果

## サマリー
- レビュー対象: {ブランチ名} → {ベースブランチ}
- 第二モデル: {Codex (primary) または Antigravity/agy (fallback) または "両方不能 — Claude 単独"}
- Claude モデル: {使用中のモデル名}

## Critical（要対応）
| # | 指摘元 | ファイル:行 | 内容 | 修正提案 |
|---|--------|------------|------|---------|

## Warning（推奨対応）
| # | 指摘元 | ファイル:行 | 内容 | 修正提案 |
|---|--------|------------|------|---------|

## Info（参考情報）
| # | 指摘元 | ファイル:行 | 内容 | 修正提案 |
|---|--------|------------|------|---------|

## モデル間の一致・相違
- **一致（信頼度高）**: 両モデルが指摘した箇所
- **相違（追加検討）**: 片方のみが指摘した箇所
- **盲点候補（どのモデルも指摘しなかったが diff のリスク上見るべき箇所）**: diff の変更面（認可境界 / 破壊的操作 / fail-open gate / 入力検証 / 並行性 / テスト欠落）に対し、どのモデルも触れなかった箇所を Claude judge が能動的に列挙する。指摘の "和" を取るだけでなく、全モデルの "共通の死角" を埋める枠。なければ "—"

## 推奨アクション
1. ...

## Footer
- Codex 復活時刻: {usage limit に当たった場合の `<YYYY-MM-DD HH:MM>`、なければ "—"}
```

## レビューコマンドの使い分け

本コマンドは PR 作成**前**のセルフレビュー専用。人間レビュアーのコメント対応（PR 作成**後**）とは補完関係。

```
1. 実装完了
2. /review:self-multi-model  ← AIセルフレビュー（本コマンド、Codex/Antigravity どちらか + Claude）
3. Critical 指摘を修正
4. PR 作成
5. 人間レビュアーがレビュー
6. レビューコメントへの対応
7. マージ
```

## 注意事項

- **Critical は PR 作成前に必ず修正してください**
- 両モデルが一致して指摘した箇所は信頼度が高いため、優先対応を推奨
- 片方のみの指摘も無視せず妥当性を判断
- **Codex 復活待ちで multi-model review をスキップしないこと** — Antigravity(agy) に fallback して即進む
- Antigravity CLI (agy) のトラブル対処:
  - `Please sign in ...` / `agy models` がサインインを要求 → **`agy` を素で1回起動**して Google Sign-In（keyring 保存・以降は非対話で動く。TUI なので実ターミナルで実行）
  - 未導入 → `curl -fsSL https://antigravity.google/cli/install.sh | bash`（`~/.local/bin` が PATH に入る・新シェルで有効）
  - quota 切れ → `agy models` で枠確認。無料 Starter Quota が尽きたら **Gemini bot（`/gemini review`）** か Claude 単独へ fallback
  - モデル名は `agy models` の表示名をそのまま `--model "Gemini 3.1 Pro (High)"` で渡す
- Codex 実行には OpenAI 直 `codex login`（ChatGPT Plus/Pro）または OpenAI API クレジットが必要
- Antigravity (agy) 実行には Google アカウントの Sign-In のみ（無料 Antigravity Starter Quota）。旧 Gemini CLI は 2026-06-18 に無料/AI Pro/Ultra 枠が停止
