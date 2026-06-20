---
name: claude-stack-news
description: |-
  直近 1 週間の Claude Code / Anthropic / エコシステムのアップデートを **固定データソース** から収集してダイジェスト出力する読み取り専用 skill。Diff-Oriented: 前週ダイジェストと突合し `🆕 New / ⏸ Carryover / ✅ Resolved` に分類。proactive・週次運用 (「今週のアプデまとめて」「直近 1 週間のニュースダイジェスト」) で発動、`/schedule` 自動実行可。**本 skill は「固定 source の定点 sweep + digest 化」だけを担い、その digest 出力 (history/) が `claude-stack-audit` の一次入力 = エコシステム情報収集の単一 SoT。導入提案・セキュリティ監査・現環境照合は `claude-stack-audit` の役割** (本 skill は news のみ)。
scope: local-only
disable-model-invocation: true
updated_at: 2026-06-14
---

# Claude Stack News (週次ダイジェスト)

## Step 一覧 (5 段)

| Step | 内容 | 完了条件 |
|---|---|---|
| 1 | 前週ダイジェスト読込 (Diff base 確定) | `PREV` path 取得 (or "初回") |
| 2 | Tier 1 一次情報収集 (Claude Code Releases / Anthropic News / Docs / Engineering / 任意ツール) | 4〜5 source の取得結果 |
| 3 | Tier 2 ローカルプラグイン scan (`installed_plugins.json`) | 取得 or skip 明示 |
| 4 | Tier 3 コミュニティ (HN / Zenn) フィルタ取得 | スコア / 直近 7 日でフィルタ |
| 5 | Diff 分類 + ダイジェスト出力 + history/ に保存 | `🆕 / ⏸ / ✅` 付き出力 + 次週用保存 |

## Constants

| 名前 | 値 |
|---|---|
| デフォルト期間 | 直近 7 日 |
| Tier 1 一次情報 source | (1) `gh release list -R anthropics/claude-code` / (2) `https://www.anthropic.com/news` / (3) `https://code.claude.com/docs/en/overview` / (4) `https://www.anthropic.com/engineering` / (5) (任意) 自分が使う外部ツール/フレームワークの release や commit |
| Tier 2 source | `~/.claude/plugins/installed_plugins.json` |
| Tier 3 source | HN (`hn.algolia.com/api/v1/search`, score≥30 OR comments≥20) / Zenn (`zenn.dev/topics/claudecode/feed`) |
| 除外 source | Reddit (ドメインブロック) / X (機械収集不可) / YouTube / Qiita / 個人ブログ |
| history/ 保存 path | `~/.claude/skills/claude-stack-news/history/YYYY-MM-DD.md` |
| 同一性キー | Releases→version tag / Anthropic→URL path / HN→URL / Zenn→URL |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `claude-stack-audit` |
|---|---|---|
| **週次ニュース収集 + Diff 分類 + ダイジェスト** (読み取り専用) | ✅ | ❌ |
| 環境スキャン + 導入提案 + セキュリティ監査 | ❌ | ✅ |

> 本 skill で「気になる候補」を出したら `claude-stack-audit` に引き渡す運用

## When to Use

- proactive・週次運用 (「今週のアプデまとめて」「直近 1 週間のニュースダイジェスト」)
- `/schedule` での自動実行
- 「導入判断」「設定見直し」依頼は `claude-stack-audit` に切り替え

---

## Implementation Steps

### Step 1: 前週ダイジェスト読込 (Diff base)

**目的**: 同一性キーで突合する base を確定
**アクション**:
```bash
PREV=$(ls -t ~/.claude/skills/claude-stack-news/history/*.md 2>/dev/null | head -1)
[ -n "$PREV" ] && echo "Diff base: $PREV" || echo "Diff base: なし (初回または history 未蓄積)"
```
**完了条件**: `PREV` path 取得 or "初回"

> 初回実行 (history 空) は全 🆕 で出力、Resolved は出さない

---

### Step 2: Tier 1 一次情報 (必須・4〜5 項目)

#### 2-1. Claude Code Releases (最重要シグナル、週 8-10 件)
```bash
gh release list -R anthropics/claude-code -L 10
# 期間内ヒットを gh api repos/anthropics/claude-code/releases/tags/<tag> --jq '.body'
```

#### 2-2 / 2-3 / 2-4
- Anthropic News: WebFetch `https://www.anthropic.com/news`
- Claude Code Docs Overview: WebFetch `https://code.claude.com/docs/en/overview` (旧 `docs.claude.com/...` は 301)
- Anthropic Engineering Blog: WebFetch `https://www.anthropic.com/engineering`

**無効 URL**: `https://docs.claude.com/en/release-notes` → リダイレクト先 404、GitHub Releases で代替

#### 2-5. (任意) 自分が使う外部ツール/フレームワークの更新追跡
> 利用しているツールに GitHub リポジトリがあれば、直近 7 日のリリースや commit を取得する。
> ツールが GitHub Release を切らない場合は commit message からバージョンを抽出する。
```bash
# 例: gh api repos/<owner>/<repo>/commits --jq '.[0:25] | .[] | "\(.commit.author.date[0:10])  \(.sha[0:7])  \(.commit.message | split("\n")[0])"' \
#   | awk -v cutoff="$(date -v-7d +%Y-%m-%d)" '$1 >= cutoff'
# ローカル CHANGELOG があれば補助的に参照
```
> 任意ステップ。追跡するツールがなければ省略可。

**完了条件**: 4〜5 source の取得結果 (or 失敗明示)

---

### Step 3: Tier 2 ローカルプラグイン (環境依存)

```bash
jq -r --arg since "$(date -v-7d -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.plugins | to_entries[] | select(.value[0].lastUpdated > $since) | "\(.key) v\(.value[0].version) (\(.value[0].lastUpdated))"' \
  ~/.claude/plugins/installed_plugins.json 2>/dev/null
```
**完了条件**: 取得 or `installed_plugins.json` アクセス不能なら「**Tier 2 unavailable**」と明示

> `gitCommitSha` 比較や更新提案は `claude-stack-audit` の役割

---

### Step 4: Tier 3 コミュニティ (フィルタ付き)

| ソース | 取得・閾値 |
|---|---|
| Hacker News | WebFetch `https://hn.algolia.com/api/v1/search?query=Claude+Code&numericFilters=created_at_i>{unix_ts_7d_ago}&hitsPerPage=20` / score≥30 OR comments≥20 |
| Zenn RSS | WebFetch `https://zenn.dev/topics/claudecode/feed` (**RSS 必須**、SPA は WebFetch 不可) / 直近 7 日 → タイトル関連性高い上位 5 件 |

**完了条件**: 各 source の上位件数

---

### Step 5: Diff 分類 + ダイジェスト出力 + history/ 保存

**分類ルール**:
- 🆕 **New**: 前週ダイジェストに同 ID なし
- ⏸ **Carryover**: 前週に同 ID あり (current 行末に「(既出: YYYY-MM-DD)」と付記)
- ✅ **Resolved**: 前週「気になる候補」枠で挙げた item が今週収集データに登場せず、対応済推測できるもの (推測根拠を 1 行で明示)

**出力フォーマット**:

```markdown
# Claude Stack News — YYYY-MM-DD (直近 7 日)

## Claude Code 本体
- 🆕 v X.Y.Z: <変更点 1 行> — <URL>
- ⏸ v X.Y.Z: <変更点 1 行> — <URL> (既出: YYYY-MM-DD)

## 外部ツール (任意)
- 🆕 v X.Y.Z: <変更点> (PR #...)

## Anthropic 公式
- 🆕 <タイトル>: <要約> — <URL>

## コミュニティ (Tier 3)
- 🆕 <タイトル> — HN score 87 / <URL>

## 気になる候補 (深掘り推奨)
最大 3 件。理由 1 行 + `claude-stack-audit` に引き継ぎ明記

## ✅ 前週から解消
最大 3 件。前週「気になる候補」が今週言及なし or 環境側で対応済みのもの。推測根拠 1 行
(初回 / 該当なしの週はセクションごと省略可)

## スルー推奨
最大 3 件。理由 1 行

## 取得状況
Tier 1: X/5 / Tier 2: X 件 or skipped / Tier 3: HN X 件・Zenn X 件
Diff base: <前週ファイルパス or "初回">
```

**保存**:
```bash
mkdir -p ~/.claude/skills/claude-stack-news/history/
# 出力内容を YYYY-MM-DD.md として保存 (次週の diff base になる)
```

**取得失敗時の fallback**:
- **Tier 1 が 2 つ以上失敗** → 「データ不十分」で実行中止、ユーザー通知
- **Claude Code Releases 単独失敗** → 中止に値する
- **任意ツール source 失敗** → ダイジェスト冒頭で明示報告 (黙って省略しない)
- 1 つだけ失敗 → 欠落明記して継続

---

## Constraints

| Pattern | Preferred | Reason |
|---|---|---|
| 環境スキャン・導入提案・セキュリティ監査 | 本 skill は read-only、`claude-stack-audit` に引き継ぐ | 責務分離 (news vs audit) |
| 三次情報 (個人ブログ / インフルエンサー主観) を一次情報扱い | Tier 1-3 分類厳守、三次情報は除外 | 信頼性担保 |
| データソースを毎回拡張 | 追加は本 SKILL.md を編集してから | 固定データソースの一貫性 |
| 取得失敗を黙殺 | fallback ルール厳守 (2 つ以上失敗で中止 / 各 source 失敗は冒頭報告) | データ欠損のサイレント混入防止 |
| 「気になる候補」「✅ 前週から解消」「スルー推奨」を各 4 件以上載せる | 各 3 件まで | 散漫化防止 |
| ダイジェスト保存忘れ | Step 5 末尾で `history/YYYY-MM-DD.md` Write 必須 | 次週の diff base 喪失 |

## Related Skills

| Skill | 関係 |
|---|---|
| `claude-stack-audit` | **下流**。本 skill の「気になる候補」を引き継いで導入提案・セキュリティ監査 |
| `oss-clone-security` | `claude-stack-audit` Step 4b と組合せ、外部配布物の取り込み時に発動 |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | 過去 Tier 1 失敗事例 | `docs.claude.com/en/release-notes` 301 / 404 → GitHub Releases で代替 |
| E2 | エコシステム調査で | GitHub Release を切らないツールは commit message から版数抽出する特殊運用が必要 |
| E3 | history/ Diff 設計 | 同一性キーで前週突合 → 🆕/⏸/✅ 分類で読みやすさ確保 |
