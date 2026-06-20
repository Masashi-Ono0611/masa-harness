---
name: claude-stack-audit
description: |-
  自分の現環境 (`~/.claude`, repo ごとの `.claude`, 各プロジェクト設定) を最新アップデートと照合し「導入すべき・様子見・不要」に分類して提案する設定全体の健全性チェック + 採用判断 skill。GitHub repo 由来の skills/plugins/MCP servers は Step 4b のセキュリティ監査を通過した場合のみ HIGH/MED に昇格。**情報収集は `claude-stack-news` の digest (history/) を一次入力として消費し、本 skill は現環境照合・セキュリティ監査・採用提案に純化する** (自前 WebSearch は digest に無い不足分の targeted 補完のみ)。「ここ 1-2 週間の Claude Code のアップデートをまとめておすすめを提案して」「直近の claude 関係のアプデまとめて」「statusline / rate_limits / effort 設定見直し」で発動。週次ニュース把握だけなら `claude-stack-news` 側 (本 skill は重い処理)。
scope: local-only
disable-model-invocation: true
updated_at: 2026-06-14
---

# Claude Stack Audit

> **環境前提**: 管理対象 repo を置くディレクトリは環境変数 `REPOS_BASE`（既定 `$HOME/Developer`）で指定する。グローバル設定は `~/.claude` 配下にある前提。

## Step 一覧 (5 段 + 4b)

| Step | 内容 | 完了条件 |
|---|---|---|
| 1 | 期間と範囲確認 (デフォルト 2 週間 / Claude Code 本体 / プラグイン / エコシステム) | 期間 & 範囲確定 |
| 2 | 情報取り込み (news digest 優先 + 不足分のみ targeted 補完) | 評価キュー |
| 3 | 現環境スキャン (global / repo / 各プロジェクト / CLI 状態) | 環境スナップショット |
| 4 | 差分マッピング (導入済 / HIGH / MED / 様子見 / 不要) | 各機能に分類タグ |
| 4b | **外部配布物セキュリティ監査** (信頼性スコア 4 段階、× は降格) | 信頼性 ◎◯△× タグ |
| 5 | アクション提案 (HIGH / MED / 様子見 / 不要、ユーザー承認待ち) | 提案表 |

## Constants

| 名前 | 値 |
|---|---|
| デフォルト期間 | 直近 2 週間 |
| 信頼性 4 段階 | ◎ 公式 (Anthropic 等) / ◯ 信頼可 (star≥50 / commit 30 日以内 / contributor≥2 / license 明示 / 権限スコープ限定) / △ 要注意 (star 少 / 単独メンテ / license 不明 / 直近更新なし) / × 不可 (fs 全域 / 任意 shell / README 乖離 / identity 追跡不能) |
| 深掘り skill | `/cso` (skill supply chain scanning 含む、月次・高リスク候補のみ) |
| 関連 skill (input) | `claude-stack-news` (週次ニュース source) |
| 関連 skill (取込時) | `oss-clone-security` (新規取り込み瞬間の防衛) |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `claude-stack-news` | `claude-config-audit` |
|---|---|---|---|
| **ニュース起点の導入提案 + セキュリティ監査** | ✅ | ❌ | ❌ |
| 週次ニュース収集 (読み取り専用) | ❌ | ✅ (input source) | ❌ |
| 公式ベスプラ vs 現環境の構成ギャップ点検 | ❌ | ❌ | ✅ |

## When to Use

- 「ここ 1-2 週間の Claude Code のアップデートをまとめておすすめを提案して」
- 「`https://...` (X / Zenn / 公式ブログ) を参考に今の設定を最適化提案して」
- 「`/ultraplan` などの新機能が気になっている、使うべきか?」
- 「直近の claude 関係のアプデまとめて」
- 「statusline / rate_limits / effort 設定を見直したい」

**スキップ条件**:
- 週次ニュース把握だけ → `claude-stack-news`
- 環境構成ギャップ点検 (ベスプラ準拠) → `claude-config-audit`

---

## Implementation Steps

### Step 1: 期間と範囲確認

**目的**: 探索スコープを確定
**確認項目**:
- 期間: デフォルト「直近 2 週間」(ユーザー指定優先)
- 範囲: Claude Code 本体 (CLI / IDE 拡張 / Web 版) / 主要プラグイン・skills (インストール済みツール・プラグイン等) / エコシステム (Anthropic 公式 / 有名コミュニティ)
- ユーザー提示 URL があれば起点に関連情報も拾う

---

### Step 2: 情報取り込み (news digest 優先、収集の SoT は claude-stack-news)

**目的**: 評価対象の候補リストを得る。固定 source の定点 sweep は `claude-stack-news` の責務なので、本 skill では原則その digest を消費し、足りない分だけ targeted に補完する (同じ調査を二度やらない)
**アクション**:
```bash
# 1. 最新 news digest を一次入力にする
PREV=$(ls -t $HOME/.claude/skills/claude-stack-news/history/*.md 2>/dev/null | head -1)
[ -n "$PREV" ] && echo "digest base: $PREV" || echo "digest なし → 補完収集にフォールバック"
# digest の「気になる候補」「🆕 New」を評価キューに入れる
```
**不足分のみ targeted 補完** (下記いずれかのときだけ WebSearch/WebFetch、固定 source sweep の再実行はしない):
- (a) ユーザー提示 URL/機能が digest に未収載 → WebFetch でその URL を取得
- (b) digest が 7 日以上古い or 該当トピック未収載 → 限定 WebSearch で裏取り
- digest が無い (news 未走) → フォールバックとして従来の WebSearch (`"Claude Code release notes <year>-<month>"` 等) を実行

**情報の質を分類** (補完収集分のみ。digest 由来は news の Tier を継承):
- **一次情報** (公式ブログ・docs・リリースノート)
- **二次情報** (実証された記事、コードベースで確認できるもの)
- **三次情報** (個人の感想・宣伝・主観評価)

---

### Step 3: 現環境スキャン

**アクション**:
```bash
# グローバル
ls ~/.claude/ ~/.claude/skills/ ~/.claude/commands/ ~/.claude/agents/ 2>/dev/null
cat ~/.claude/settings.json 2>/dev/null
cat ~/.claude/CLAUDE.md 2>/dev/null

# 各プロジェクト（repo 群の置き場。REPOS_BASE で上書き可・既定 ~/Developer）
find "${REPOS_BASE:-$HOME/Developer}" -maxdepth 3 -name "CLAUDE.md" -not -path "*/node_modules/*" 2>/dev/null
find "${REPOS_BASE:-$HOME/Developer}" -maxdepth 4 -type d -name ".claude" -not -path "*/node_modules/*" 2>/dev/null

# 現 CLI 状態
claude --version 2>/dev/null
claude plugin marketplace list 2>/dev/null
```

---

### Step 4: 差分マッピング

| 分類 | 基準 | 信頼性要件 | アクション |
|---|---|---|---|
| **すでに導入済み** | 現環境で使用中 | — | 「不要なら明示的にスキップ」 |
| **導入推奨 (HIGH)** | 一次情報あり、ユーザーのワークフローに直接ヒット | 信頼性◎ または公式 | 試験運用案作成 |
| **導入推奨 (MED)** | 二次情報レベル、効果見込み | 信頼性◯以上 | 1 週間試して再評価提案 |
| **様子見** | 三次情報のみ、実証不十分、過剰最適化リスク、または信頼性△ | — | スキップ理由明示 |
| **明示的に不要** | ユーザー環境/嗜好と合わない、または信頼性× | — | 理由付きで提示 |

> **外部配布物 (GitHub repo 由来の skills/plugins/MCP)** は Step 4b のセキュリティ監査を通過した場合のみ HIGH/MED に昇格

---

### Step 4b: 外部配布物セキュリティ監査 [必須]

**目的**: サプライチェーンリスク回避
**アクション**:
```bash
gh repo view <owner>/<repo> --json stargazerCount,pushedAt,createdAt,licenseInfo,isArchived
gh api repos/<owner>/<repo>/contributors --jq 'length'
gh api repos/<owner>/<repo>/commits --jq '.[0].commit.author.date'
gh api repos/<owner>/<repo>/contents/package.json 2>/dev/null
gh api repos/<owner>/<repo>/contents/pyproject.toml 2>/dev/null
gh search code --repo <owner>/<repo> 'curl|wget|eval|exec|child_process|subprocess'
```

**信頼性スコア (4 段階)**:
| スコア | 判定基準 |
|---|---|
| **◎ 公式** | Anthropic 公式 / Claude Code 公式 / 認知度高ベンダー |
| **◯ 信頼可** | star≥50 / 直近 30 日以内 commit / contributor≥2 / license 明示 / hooks/MCP 権限がスコープ限定 |
| **△ 要注意** | star 少 / 単独メンテ / license 不明 / 直近更新なし — 本格運用避ける |
| **× 不可** | hooks/MCP が fs 全域・任意 shell 実行を要求 / README と実装乖離 / 配布者 identity 追跡不能 / 依存に怪しいパッケージ |

**チェックリスト** (GitHub repo 由来全項目):
- [ ] star 数・直近コミット・contributor 数・issue 対応の活発さ
- [ ] license 明示 (MIT/Apache 等)
- [ ] `package.json` / `pyproject.toml` 依存先に怪しいもの (typosquatting 含む)
- [ ] hooks / MCP server 権限がスコープ限定 (fs 全域・任意 shell・network 無制限は NG)
- [ ] README/SKILL.md と実コード乖離なし
- [ ] 配布者の他リポ・GitHub/X identity に一貫性
- [ ] 過去に同等機能を試した記録がメモリに

**1 項目でも × があれば原則「明示的に不要」または「様子見」に降格**
**深掘りが必要なら `/cso` (月次 / 高リスク候補のみ)**

---

### Step 5: アクション提案

**フォーマット**:
```markdown
## 導入推奨 (HIGH)
1. <機能名> — <一次情報 URL>
   - なぜ: <具体的な利益>
   - 影響範囲: <どのファイル/設定>
   - 試験運用: <試験期間と再評価期限>

## 導入推奨 (MED)
...

## 様子見
1. <機能名> — <理由>

## 明示的に不要
...
```

**重要**: 実装は別ステップ。提案後、ユーザーが選んだもののみ `.claude/rules/` / `CLAUDE.md` / `settings.json` に反映

---

## 過去の典型的な発見ポイント

- statusline 設定 (rate_limits, cost, model 表示)
- effort level (max / xhigh 設定方法)
- MCP プラグイン管理
- skills / commands 整理
- gstack / chrome-devtools の browser tooling
- ignore 設定 (`.claudeignore`、チーム共有時の `.gitignore`)

→ 「過去に対応済みの可能性が高い」前提でスキャン

## Constraints

| Pattern | Preferred | Reason |
|---|---|---|
| 三次情報 (個人ブログ) を一次情報扱い | 一次/二次/三次分類厳守 | 信頼性担保 |
| ユーザー承認なしに `settings.json` / `CLAUDE.md` 変更 | 提案までで止め、Step 5 承認後実装 | 既存運用破壊リスク |
| 「とりあえず全部入れる」提案 | HIGH/MED/様子見/不要を明確に区別 | 過剰導入は害 |
| 既存運用を壊す変更を「軽微」表現 | 影響範囲を具体明示 | 誤判定の元 |
| GitHub repo 由来配布物を Step 4b 飛ばして HIGH/MED 分類 | Step 4b 通過のみ昇格 | サプライチェーンリスク |
| 「機能が魅力的だから」を理由に信頼性 △/× を昇格 | 機械的判定厳守、印象で動かさない | 客観性担保 |

## Related Skills / Resources

| Skill / Resource | 関係 |
|---|---|
| `claude-stack-news` | **input source**。週次ニュース → 気になる候補を本 skill に引き継ぎ |
| `claude-config-audit` | 補完関係: ベスプラ起点の構成ギャップ点検 (本 skill はニュース起点) |
| `oss-clone-security` | 外部配布物導入決定後の clone 瞬間防衛 |
| `/cso` | 月次・高リスク候補の深掘り |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | 過去 `usedhonda/claude-skills` ケース | 配布者の他リポ・identity 一貫性検証で typosquatting / 詐称防止 |
| E2 | Step 4b 信頼性 4 段階運用 | 「機能魅力 = 採用」ではなく機械的スコアで判定、印象で動かさない |
