# Skill Template (Claude が走りやすい SKILL.md ベスト形式)

新規 skill 生成時 / 既存 skill 大幅改修時は **本テンプレに準拠する**。Anthropic 公式 [Claude Code Skills](https://docs.claude.com/en/docs/claude-code/skills) と、実運用 skill 群（マルチモデルレビュー反映済）の運用知見を統合。

## 推奨構造 (見出し階層)

```
---
name: <kebab-case>
description: |-
  <1-2 文で主用途> + <trigger phrase 列挙> + <delegate / 上下流関係>。
  <スコープ / 適用範囲>。
scope: local-only       # 個人ローカル skill (gitignore 配下) は必須／共有・commit 対象の skill には付けない
updated_at: YYYY-MM-DD
---

# Skill Title

## Step 一覧 (N 段)          ← 冒頭で全体像を即把握させる
## Constants                 ← 固定値 (ID / URL / option ID / SoT path) を集約
## 責務範囲 (被りなし)        ← 関連 skill との被り排除表
## When to Use / スキップ条件
## Implementation Steps
  ### Step 0/1/2/.../N      ← 各 Step は固定構造 (下記)
## Constraints              ← Errors (致命的) + Warnings (注意) の 2 table
## Related Skills / Resources
## Evidence Index           ← 末尾、行数を圧迫しないよう短く
```

## 各 Step の固定構造

```
### Step N: タイトル [スコープ修飾 (例: 通常 PR のみ / Release PR のみ)]

**目的**: なぜやるか (1 文)
**条件**: skip 判定 or 実行前提 (allowlist 形式、暗黙 skip 禁止)
**アクション**: コピペで動くコード or 手順 (変数はプレースホルダ明示)
**完了条件**: 次 Step に進める判断基準 (fail-fast 形式)
```

## Step 一覧表の書式

```
| Step | 内容 | 通常モード | 別モード (delegate / scope) |
|---|---|---|---|
| 1 | ... | ✅ | ✅ / ❌ (理由) |
| ... |
```

- **❌ には必ず理由を併記** (`(release branch 既存)` / `(release-execute が SoT)` 等)
- 別モード列が不要な単純 skill では 2 列でも OK

## Constants 集約ルール

「本文中に散在する固定値」を 1 箇所に。例:

| 名前 | 値 |
|---|---|
| Project Board ID | `<project-board-id>` |
| Status field ID | `<status-field-id>` |
| Status 値 | `<status-option-id>` |
| SoT path | `@docs/<your-playbook>.md` |
| 命名規約 | `<rule>` |

**散在しがちな項目**: repo / base branch / GCP project / region / service 名 / label / milestone 名 / SoT doc path / 命名規約

## 責務範囲表

```
| 用途 | 本 skill | <上流 skill> | <下流 skill> |
|---|---|---|---|
| <task A> | ✅ | ❌ | ❌ |
| <task B> | ❌ (delegate) | ❌ | ✅ Step X-Y |
```

- **被り排除**: 同じ task が複数 skill に「✅」になる場合は SoT を 1 箇所に決めて他は `❌ (delegate / 参照のみ)` に
- 詳細手順 / GraphQL mutation / option ID 早見表は SoT 側に持ち、他は参照リンクのみ

## Constraints 2-table 構造

```
### 致命的 (Errors)
| Pattern | Preferred | Reason |
|---|---|---|
| <禁止行動> | <推奨行動> | <なぜ Errors か (実害)> |

### 注意 (Warnings)
| Pattern | Preferred | Reason |
|---|---|---|
| <非推奨行動> | <推奨行動> | <なぜ Warnings か> |
```

- Errors は「実害あり (PR 詰まり / データ損失 / インシデント)」のみ
- Best Practices section は **作らない** (Constraints と重複するため Constraints に集約)
- Reason に Evidence ID (`[E1]` 等) を貼って Evidence Index と双方向リンク

## 禁止事項 (Critical Anti-patterns — Codex review 由来)

| ❌ NG | ✅ Preferred | 理由 |
|---|---|---|
| **対話式コマンド** (`git add -p` / `gh pr create` の wizard 等) | ファイル単位 / `--body` 等で非対話 | agent が prompt 待ちで停止 |
| **undefined 変数の使用** (`$PR` を使う Step が `$PR` 取得 Step を持たない) | Step 1 等で `PR=$(...)` を明示し以降の Step で再利用 | Bash session 分断で空変数のまま実行されて詰まる |
| **暗黙 skip** (「config のみは skip」と書くが allowlist 不明確) | allowlist を明示 (例: docs/md only OK / `.github/` `*.env*` は skip 禁止) | 高リスク (CI/env/secret) を誤 skip すると prod incident |
| **コマンド `--base` 省略** (`/review:self-multi-model` を base 指定なしで呼ぶ) | `--base "$BASE"` 必須 (default `main` で誤 diff レビュー) | Step 1 で `BASE=$(...)` を取得して以降全 Step で渡す |
| **副作用コマンド前の guard 欠如** (`gh pr merge "$PR"` 前に baseRefName 確認なし) | 直前に `if [ "$BASE_CHECK" != "expected" ]; then exit 1; fi` | PR 取り違え最後の防波堤 |
| **対話式 prompt 残し** (「ユーザーに確認」だけで停止条件が曖昧) | 明示的に「ユーザー応答待ち [stop]」と書き、確認内容も Markdown でフォーマット | agent が確認なしで進めてしまうリスク |
| **長文の Best Practices 散文** | Constraints table 1 つに集約 | 重複 + 読みづらさ |
| **絵文字濫用** (📌🎉🔄 等の装飾) | ✅❌⚠️🏆🥈🥉 等の **意味のあるシンボル**のみ | 読みやすさ + 機械パース容易 |
| **小数ステップ採番** (`Step 2.5` 等) | 整数振り直し or 下位作業は `Step 2a/2b` (正本: CLAUDE.md §共通ルール 採番 reflex) | 暫定感が残り増殖・番号を ID 扱いするのに不安定 |

## 命名規則 (skill name convention) — 2026-06-06 制定

skill 名は **`<namespace>-<object>-<action>`** に統一する。名前だけで責務境界が読めること（= 誤発火を防ぐ）が目的。2026-06-06 に `skill-audit` / `claude-bestpractice-check` の取り違えが実際に起きたのを機に制定。

### namespace 接頭辞 (meta-skill のみ付与、一貫させる)

| 接頭辞 | 対象領域 | 例 |
|---|---|---|
| `claude-` | **Claude Code 環境自体**の保守・監査 (config / skill / ecosystem / news) | claude-config-audit, claude-skill-audit, claude-stack-audit, claude-stack-news |
| `dev-` | マシン / 開発環境の ops | dev-machine-optimize |
| (無し) | ドメイン・プロジェクト固有 / reflex | oss-clone-security, lesson-harvest, ask-after-grep |

> **partition として機能させる**: 「Claude 環境保守系なら全部 `claude-`」のように、同じ族は必ず同じ接頭辞を付ける。一部だけ無印にしない（族の一部を無印にすると別族に見え、誤発火・取り違えの原因になる）。

### action = 統制語彙 (controlled vocabulary、同じ動作は同じ語)

| action | 意味 | 例 |
|---|---|---|
| `audit` | 基準と差分照合してレポート（健康診断・スコア化を含む） | stack-audit, skill-audit, config-audit |
| `check` | pass/fail gate（合否2値の関門） | (現状 該当 skill なし・将来の gate 用に予約) |
| `news` | digest | stack-news |
| `optimize` / `refresh` / `harvest` / `security` | 各動作で1語固定 | machine-optimize, research-refresh |

> **audit と check を混用しない** / **object は並列構造**にする（audit 兄弟が `stack-audit`/`skill-audit` のように object で区別できる形）。動詞は末尾 (object-action 順)。`ask-after-grep` のような reflex 命令形は既存例外として許容するが、新規は object-action を優先。

### 新規 skill 命名時の自問
- [ ] 同族 skill があるなら **同じ namespace 接頭辞**を付けたか (族の一部だけ無印にしていないか)
- [ ] action は統制語彙の既存語か (新しい同義語を増やしていないか)
- [ ] 既存 skill と **名前だけで区別**できるか (object が並列か)

## description / frontmatter ベスト

- **description**: 1-2 文で主用途を冒頭に置く + trigger phrase 列挙 (`「<phrase 1>」「<phrase 2>」で発動`) + delegate / 上下流関係明記
- **scope: local-only**: 個人 skill (gitignore 配下) は必ず明示
- **updated_at**: 最新編集日 (YYYY-MM-DD)
- **長い description は `description` と「## When to Use」に分割**

## 行数 soft cap

- **目標 < 500 行** (公式 docs の soft cap)
- 超える場合は `references/<topic>.md` や `scripts/<task>.sh` に外出し
- 例: 長い GraphQL snippet / 詳細手順集 / Evidence Index → `references/evidence.md` 検討

## Evidence Index ルール

末尾に **短く** (本文と分離):

```
| ID | 出典 | 学び |
|---|---|---|
| E1 | session YYYY-MM-DD (<context>) | <1 文の学び> |
```

- session ID 単独 (`session d77055e7`) は opaque なので **context (日付 / リポ / PR 番号)** を併記
- 本文の Constraints から `[E1]` で双方向リンク

## 実装規模の目安

本テンプレに準拠した実運用 skill の規模感:

| 規模 | 行数 | 構成の目安 |
|---|---|---|
| 最小 | ~150 | Step 4 段・委譲中心のシンプルな skill |
| 中 | ~230-330 | Step 6-8 段・判定ロジック表 / Constants が肝 |
| 大 | ~350-450 | Phase + Step 8 段・専用フロー |
| 最大 | ~550-580 | Step 10-16 段・多 Phase・失敗モード対処込（このあたりが上限。超えるなら `references/` へ分割） |

## 新規 skill 生成チェックリスト

新規 skill を作る前に:

- [ ] description は 1-2 文 + trigger phrase + delegate 関係を含む
- [ ] Step 一覧表が冒頭にある (全 N Step が一目で把握できる)
- [ ] Constants が必要なら 1 箇所に集約 (散在禁止)
- [ ] 責務範囲表で関連 skill との被りなしを宣言
- [ ] 各 Step が「目的 / 条件 / アクション / 完了条件」固定構造
- [ ] コードは copy-paste で動く (変数はプレースホルダ明示)
- [ ] 対話式コマンド (`git add -p` 等) を使っていない
- [ ] undefined 変数を使うときは取得 Step が前にある (`PR=$(...)`)
- [ ] 副作用コマンド (merge / delete / close) 前に guard あり
- [ ] Constraints が Errors + Warnings の 2 table 構造
- [ ] Best Practices section を作っていない (Constraints に集約)
- [ ] Related Skills が双方向で整合 (相手 skill にも自分への参照あり)
- [ ] Evidence Index に context (日付 / リポ / PR 番号) 付き
- [ ] 500 行を超えていない (超える場合は `references/` 検討)
- [ ] 個人 skill なら `scope: local-only` を frontmatter に明示
