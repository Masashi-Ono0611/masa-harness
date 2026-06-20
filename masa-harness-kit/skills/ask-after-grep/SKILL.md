---
name: ask-after-grep
description: |-
  AI に質問する前に必ず `docs/` / `.knowledge/` / `CLAUDE.md` / `AGENTS.md` を grep する reflex skill。ドキュメントに既に書いてあることを AI に聞き直す無駄を防ぐ。「これ何?」「どこに書いてある?」「ask after grep」「grep してから」「docs 確認して」等で発火、もしくはユーザー質問を受ける前のチェックポイントとして proactively 起動。
scope: local-only
updated_at: 2026-05-18
---

# Ask-After-Grep (質問前 grep reflex)

docs/CLAUDE.md/AGENTS.md を grep する reflex で **ドキュメント既述の聞き直し**を防ぐ。ユーザー (or Claude 自身) が疑問を持った瞬間に **4 source を並列 grep** → ヒットすれば Read → ユーザー応答、を機械化。

## Step 一覧 (4 段)

| Step | 内容 | 完了条件 |
|---|---|---|
| 1 | keyword 抽出 (日本語 + 英語両方、2-4 個) | `KW` リスト |
| 2 | 4 source grep を並列実行 (docs / .knowledge / root MD / (任意) semantic 検索) | 各 source の hit リスト |
| 3 | hit 数評価 (0 / 1-3 / 4+) | 行動分岐確定 |
| 4 | ユーザーへの返答 (テンプレ準拠) | 応答完了 |

## Constants

| 名前 | 値 |
|---|---|
| 4 source | (1) project `docs/` / (2) project `.knowledge/` / (3) root `CLAUDE.md` `AGENTS.md` `CONTRIBUTING.md` `README.md` / (4) (任意) semantic 検索 MCP（環境にあれば併用） |
| 取得 root | `$(git rev-parse --show-toplevel 2>/dev/null \|\| pwd)` |

## 責務範囲 (被りなし)

| 用途 | 本 skill | semantic 検索 MCP |
|---|---|---|
| **質問前の docs grep reflex** (ドキュメント既述の聞き直し防止) | ✅ | ❌ (本 skill が呼ぶ source) |
| semantic search 単体 | ❌ | ✅ |

## When to Use

- ユーザーが具体的疑問を投げてきたとき (「プロジェクト X で Y どう扱う?」「Z の設定どこ?」「W の責任分離は?」等)
- Claude 自身が「ドキュメントに書いてあるか調べないとな」と気付いたとき
- `/ask-after-grep <keyword>` で明示呼び出し

**スキップ条件**:
- 一般技術知識 (公式 doc 系) → grep してもヒットしないことが自明
- リアルタイム情報 (PR の現在状態など) → grep の対象外
- 同 session で既に同 keyword を grep 済 → 再実行は無駄

---

## Implementation Steps

### Step 1: keyword 抽出

**目的**: ユーザー質問または Claude の探索意図から 2-4 個の検索 keyword を抽出
**ルール**: 日本語と英語の両方を試す
**例**: 「プロジェクト X の環境切替（STG/PRD）どう?」 → keywords: `env-config`, `STG.*PRD`, `環境切替`, `staging`

**完了条件**: `KW` リスト確定

---

### Step 2: 4 source grep を並列実行

**目的**: 散らばった doc を一括網羅
**アクション**:
```bash
KW="<keyword>"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# 1. プロジェクト docs
grep -rln "$KW" "$ROOT/docs/" 2>/dev/null

# 2. ツール非依存ナレッジ
grep -rln "$KW" "$ROOT/.knowledge/" 2>/dev/null

# 3. AI ハーネスガイド (root のみ)
grep -ln "$KW" "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md" "$ROOT/CONTRIBUTING.md" "$ROOT/README.md" 2>/dev/null

# 4. (任意) semantic 検索 MCP — 環境にあれば併用
# <semantic-search-mcp> query "$KW" --limit 5
```
**完了条件**: 全 hit を集約してリスト化

---

### Step 3: hit 数評価

| hit 数 | 行動 |
|---|---|
| **0 hit** | docs 未整備 → AI 知識で回答 OK。**ただしユーザーに「docs に hit なし、新規追加すべきか」と短く問う** |
| **1-3 hit** | 該当行と前後 5 行を Read → ファイルから抜粋を示す → 「これで足りる?」確認 |
| **4 hit 以上** | スコアリング (ファイル名 + 行位置で最も近いもの top 2 だけ Read、残りはファイル名リストで提示) |

---

### Step 4: ユーザーへの返答

| シナリオ | 返答テンプレ |
|---|---|
| hit 1-3 で完結 | 📄 `<path>:<line>` に記載: <要約>。これで答えになっていれば OK、足りなければ追加質問を |
| hit ありで補足必要 | 📄 docs に基本は記載 (`<path>`)。それに加えて <AI 補足> も関連します |
| hit 0 | 🔍 docs / .knowledge に hit なし。AI 知識で答えると <回答>。docs に追加すべきな内容なら別途 issue 化を提案できます |

---

## Constraints

| Pattern | Preferred | Reason |
|---|---|---|
| grep スキップで AI 即答 | 必ず grep → 0 hit でも記録に残す | ドキュメント既述の聞き直しを防ぐのが本質 |
| 1 keyword で諦める | 日本語 / 英語 / synonym で 2-4 回試す | i18n / HeroUI / 環境切替 など別表記混在 |
| 全ファイル網羅 grep | 4 source (docs / .knowledge / root MD / (任意) semantic 検索) に絞る | 過剰検索は cost、4 source で 90% カバー |
| 同 session で同 keyword を再 grep | キャッシュして skip | 無駄 token |
| hit したまま読まずに「ある」とだけ返答 | 該当行を Read して要約する | 「ある」だけだと検索を代行しただけで役に立たない |

## Quick Reference

```bash
# よく使う 1-liner (手動でも実行可)
grep -rln "<keyword>" docs/ .knowledge/ CLAUDE.md AGENTS.md README.md 2>/dev/null

# (任意) semantic 検索 MCP（環境にあれば）
# <semantic-search-mcp> query "<natural language question>"

# git で過去 PR から探す (補助)
git log --all --grep="<keyword>" --pretty=format:"%h %s" | head -5
```

## Related Skills / Resources

| Skill / Resource | 関係 |
|---|---|
| ガバナンス執行 | `$HOME/.claude/hooks/governance-gate.py` |
| (任意) semantic 検索 MCP | 環境固有の設定ファイルを参照 |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | Pragmatic Engineer の "performative AI"（やってる感だけの AI）警告 | doc を検索せず即答するのがその典型 |
| E2 | 個人運用での検証 | 4 source 並列 grep で大半をカバーでき、cost と精度のバランスが良い。grep reflex 自体は恒久採用 |
