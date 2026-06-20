---
name: lesson-harvest
description: |-
  Claude 会話履歴 (transcript) を sensor に、ユーザーが繰り返し指摘・訂正した運用パターンを収穫し、CLAUDE.md / rules / memory への追記 diff を起案 → 承認後に Edit する self-improving loop。
  「lesson harvest」「繰り返し指摘を拾って」「自己改善ループ回して」「learn を収穫」で発動。
  CLAUDE.md「同じ指摘を2回受けたら追記して再発防止」ルールの自動執行版。`claude-skill-audit` (skill 構造監査) / `claude-config-audit` (公式 docs 起点) とは sensor が異なる (本 skill = ユーザーの繰り返し指摘)。
scope: local-only
disable-model-invocation: true
updated_at: 2026-05-30
---

# Lesson Harvest

自己改善ループの考え方（外部の self-improving company 事例 [E1]）の個人版。monitoring agent → ツール自動改善ループを、「自分の transcript → 運用ルール自動追記」に縮約する。**sensor 層の主経路は Explore agent (model: haiku) による直近 transcript の読み取り**。semantic 検索 MCP（gbrain 等）があれば一次手段として併用できる。

## Step 一覧 (5 段 = 自己改善ループの 5 層)

| Step | ループの層 | 内容 | 完了条件 |
|---|---|---|---|
| 1 | sensor | transcript を読んで繰り返し指摘・訂正パターンを収穫（semantic 検索ツールがあれば併用） | 候補リスト (各候補に出典 session) |
| 2 | policy + learning | 既存 CLAUDE.md/rules/memory と突合 (新規 / 再発 / 矛盾を分類) | 分類済み候補 |
| 3 | tool | 追記/更新先 file と diff を起案 | file:行 + diff のリスト |
| 4 | quality gate | diff を提示しユーザー承認待ち [stop] | 承認 / 却下が候補ごとに確定 |
| 5 | apply | 承認分のみ Edit + memory 反映 → 完了報告 | 反映済み、却下分は記録のみ |

## Constants

| 名前 | 値 |
|---|---|
| SoT ルール | CLAUDE.md「同じ指摘を2回受けたら CLAUDE.md / rules / auto memory に追記して再発防止」 |
| 源流 | 自己改善ループの考え方（外部の self-improving company 事例）|
| scan 範囲 | 個人 overlay の設計・運用指摘。業務固有は各 repo の transcript に任せる |
| sensor 一次手段 | `Explore` agent (model: haiku) で直近 transcript を読む |
| sensor 任意強化 | semantic 検索 MCP (gbrain 等) があれば一次手段として使う |
| 追記先候補 | `$HOME/.claude/CLAUDE.md` / `$HOME/.claude/rules/*.md` / memory `~/.claude/projects/<your-project>/memory/` |
| 採用しきい値 | 2 回以上の指摘 or 明示的訂正。1 回限りは採用しない |
| トリガー | `recurring-tasks.json` の週次レビューの 1 ステップ (週次)。手動は `/lesson-harvest` |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `claude-skill-audit` | `claude-config-audit` |
|---|---|---|---|
| ユーザーの繰り返し指摘 → 運用ルール追記 | ✅ | ❌ | ❌ |
| 個人 skill の template 準拠・構造監査 | ❌ | ✅ | ❌ |
| 公式 docs 起点の config 健全性点検 | ❌ | ❌ | ✅ |

sensor (transcript) が本 skill 固有。他 2 skill は skill ファイル / 公式 docs を起点にする。

## When to Use

- 週次 (週次レビューの中) / `/lesson-harvest` 手動
- 「同じことを 2 回言った気がする」「前に直したのにまた指摘した」と感じたとき

**スキップ条件**:
- Explore agent も semantic 検索 MCP も使えない (sensor 不能) → その旨を報告して停止
- 直近に harvest 済みで新規指摘がない

---

## Implementation Steps

### Step 1: transcript を読んで繰り返し指摘を収穫 (sensor)

**目的**: transcript から「2 回以上の指摘 / 訂正」を抽出
**条件**: Explore agent (model: haiku) で直近 transcript を読む。semantic 検索 MCP (gbrain 等) があれば一次手段として使ってよい
**アクション (Explore agent 経路)**:
```
Agent(subagent_type="Explore", model="haiku",
  prompt="直近 N 日の transcript を読み、ユーザーが2回以上指摘・訂正した運用パターンを出典 session 付きで列挙")
```
**アクション (semantic 検索 MCP 経路、任意)**:
```
# gbrain 等の semantic 検索 MCP が使える場合は以下を実行してもよい
think(query="運用・設定について、ユーザーが2回以上指摘または訂正した点は何か。引用付きで。")
find_anomalies()        # 異常・繰り返しシグナル
get_recent_salience()   # 重要度の高い最近の話題
```
**完了条件**: 候補リスト (各候補に「何を / 何回 / どの session」)。0 件なら Step 4 をスキップして「新規指摘なし」を報告

### Step 2: 既存ルールと突合 (policy + learning)

**目的**: 採用可否を判定し、再発を検知する
**条件**: 各候補を 3 分類
- **新規**: 既存ルールに無い → 追記候補
- **再発**: 既に追記済みなのに再発 → そのルールが弱い → **強化候補** (learning 層)
- **矛盾**: 既存ルールと食い違う → 更新候補
**アクション**: 候補ごとに該当 file を Read で確認 (`$HOME/.claude/CLAUDE.md` / `$HOME/.claude/rules/*.md` / memory)。1 回限りの指摘・既存と重複するものは**ここで除外**
**完了条件**: 分類済み候補リスト (新規 / 再発 / 矛盾 / 除外)

### Step 3: 追記/更新 diff を起案 (tool)

**目的**: そのまま適用できる形にする
**アクション**: 候補ごとに「追記先 file:行」「diff」を作る。memory への追記は frontmatter (type: feedback) 形式、CLAUDE.md/rules への追記は既存 style に合わせる (Surgical: 触るのは必要箇所のみ)
**完了条件**: file:行 + diff のリスト

### Step 4: diff 提示 + 承認待ち [stop]

**目的**: quality gate (人間承認)。loop の唯一の human ステップ
**条件**: 候補が 1 件以上ある
**アクション**: 各候補を Markdown で提示 (`分類 / 出典 session / 追記先 file:行 / diff / 理由`)。**diff をテキストで一括提示し承認を仰ぐ**（候補が 5 件超で個別判断が要る時のみ AskUserQuestion）。承認を得るまで Step 5 に進まない [stop]
**完了条件**: 候補ごとに採用/却下が確定

### Step 5: 承認分のみ Edit + 完了報告 (apply)

**目的**: loop を閉じる
**条件**: Step 4 で**採用された候補のみ**。却下分は Edit しない
**アクション**:
1. **責任領域 guard**: 追記内容が governance / 法務 / 契約 / 本番デプロイ / 対外発信に関する「最終判断ルール」なら、自動追記せず「人間が判断する」旨の注意書きに留める (副作用前 guard [E2])
2. 採用候補を該当 file に Edit。memory 追記時は MEMORY.md にも 1 行 index 追加
3. 完了報告: 採用 N 件 (file:行) / 却下 M 件 / 再発だった件数 (= 前回ルールが効かなかった証跡)
**完了条件**: 採用分が反映済み、報告済み

---

## Constraints

### 致命的 (Errors)

| Pattern | Preferred | Reason |
|---|---|---|
| Step 4 の承認前に file を Edit する | diff 提示 → 承認 → Step 5 で Edit | 自動でルールを書き換えると意図しない運用変更が静かに入る |
| 責任領域 (governance/法務/契約/本番/対外) の最終判断ルールを自動追記 | 「人間が判断」の注意書きに留める | AI に最終判断させない（a16z 線） |
| sensor 出力を裏取りせず追記 | Step 2 で該当 file を Read し実在・矛盾を確認 | LLM 要約の hallucination をルールに固定化しない |
| sensor 不能なのに憶測で候補を生成 | Explore も semantic 検索 MCP も不能なら停止して報告 | 出典なき "指摘" の捏造を防ぐ |

### 注意 (Warnings)

| Pattern | Preferred | Reason |
|---|---|---|
| 1 回限りの指摘を追記 | 2 回以上 or 明示訂正のみ | ルールの過剰増殖 (CLAUDE.md 肥大化) |
| 既存ルールと重複する追記 | Step 2 で重複除外、再発なら強化に振る | 同義ルールの乱立 |
| memory ファイルが 200 行超 | 分割または index 化 | memory システムのベスプラ |
| 大量候補を一度に提示 | 上位 3-5 件に絞る | 承認疲れ・loop が回らなくなる |

## Related Skills / Resources

| Skill / Resource | 関係 |
|---|---|
| semantic 検索 MCP (gbrain 等) | sensor の任意強化。transcript の semantic 検索に使える |
| `claude-config-audit` | 公式 docs 起点の config 点検 (本 skill は transcript 起点) |
| `claude-skill-audit` | skill 構造の監査 (本 skill は運用ルールの監査) |
| Self-Improving Company 事例 | 源流の考え方 (monitoring → 自動改善 → 自動適用ループ) |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | YC "How to Build a Self-Improving Company with AI" (self-improving loop 事例) | 監視→自動改善→自動適用ループを人間承認だけ残して個人運用に縮約 |
| E2 | CLAUDE.md 恒久ルール (副作用前 guard / a16z 線) | 責任領域の最終判断ルールは自動追記せず人間に残す |
