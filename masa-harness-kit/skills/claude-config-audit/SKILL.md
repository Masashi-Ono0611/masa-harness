---
name: claude-config-audit
description: |-
  Claude Code 公式ベストプラクティス (docs.claude.com) と現環境 (`~/.claude`, repo の `.claude`, memory/) の差分を取り、CLAUDE.md / settings.json / hooks / skills / memory の構成健全性をスコア化してレポートする月次〜四半期 config 健康診断 skill。**環境を勝手に変更しない、レポート + 提案までで止め、ユーザー承認後に実施**。「ベスプラ点検」「設定健全性チェック」「Claude config audit」「mdファイルやメモリーなど設定できていない点をレポート」で発動。`claude-stack-audit` (ニュース起点) とは別軸 (本 skill は公式 docs 起点)。
scope: local-only
disable-model-invocation: true
updated_at: 2026-06-13
---

# Claude Config Audit

> **環境前提**: グローバル設定 `~/.claude` と各 repo の `.claude`（project scope）を対象にする。

## Step 一覧 (5 Phase)

| Phase | 内容 | 完了条件 |
|---|---|---|
| 1 | ベスプラ調査 (公式 docs 一次情報、8 観点) | 公式 URL 付き観点リスト |
| 2 | 環境スキャン (user / project scope + 履歴・キャッシュ系) | ファクトベースリスト |
| 3 | スコアリング (◎/◯/△/× + 優先度🔴🟡🟢) | スコア表 |
| 4 | レポート出力 (総評 / 🔴🟡🟢 / 推奨アクション / 📚出典) | 会話内出力 |
| 4b | クリーンアップ playbook (アーカイブ→保留→必要なら purge、3 段階) | reversibility 確保 |
| 5 | 実行確認 (バックアップ → 変更 → JSON validate → recurring-tasks 更新) | ユーザー承認後反映 |

## Constants

| 名前 | 値 |
|---|---|
| 公式 docs URL | `https://docs.claude.com/en/docs/claude-code/*` / `https://www.anthropic.com/news` |
| 8 観点 | CLAUDE.md 設計 / Memory システム / settings.json 階層 / Hooks / Skills/Commands / Permission Modes / MCP / Context 管理 |
| 環境 scan 対象 (global) | `~/.claude/` (settings.json / hooks / skills / projects/ / history.jsonl / backups/ / file-history/ / telemetry/ / paste-cache/ / todos/ / plugins/{cache,marketplaces}/) |
| 環境 scan 対象 (project) | 各 repo の `.claude/` (CLAUDE.md / settings.json / rules / hooks / commands / skills / state) |
| memory 対象 | `~/.claude/projects/<your-project>/memory/` (MEMORY.md + 個別ファイル) |
| 優先度 | 🔴 高 (公式逸脱、セキュリティ・効率影響) / 🟡 中 (推奨未準拠、改善で効果) / 🟢 低 (観察対象) |
| アーカイブ先 | `~/.claude/archive/cleanup-YYYY-MM-DD/<category>/` |
| 30 日後 purge 提案 | `recurring-tasks.json` の `archive-purge` entry が `last_run` から 30 日経過時に session-start で通知 |

### 履歴・キャッシュ系の閾値ガイド

| 項目 | 黄信号 | 赤信号 |
|---|---|---|
| `projects/` 合計 | >500MB | >1GB |
| 単一 transcript | >50MB | >100MB |
| transcript 60日超ファイル数 | >100 | >300 |
| `history.jsonl` | >5MB | >10MB |
| `backups/.claude.json.backup.*` 世代 | >3 | >10 |
| `todos/` 60日超 | >50 | >100 |
| `plugins/{cache,marketplaces}/` 合計 | >100MB | >500MB |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `claude-stack-audit` | `claude-stack-news` |
|---|---|---|---|
| **公式ベスプラ起点の構成ギャップ点検** (月次〜四半期) | ✅ | ❌ | ❌ |
| ニュース起点の導入提案 + セキュリティ監査 | ❌ | ✅ | ❌ |
| 週次ニュース収集 (読み取り専用) | ❌ | ❌ | ✅ |

> **rules / CLAUDE.md 本文の剪定（重複・stale・規則衝突・"5個でなく40個"肥大）は本 skill が owner**（SoT: `rules/config-hygiene.md`）。規則の**追加**は `lesson-harvest`（足す係／削る係を分離）、skills/commands は `claude-skill-audit`、memory の L1 昇格は `lesson-harvest` が兼務。本 skill は剪定（削る側）のみ。
> Phase 2 で skills/memory も scan するが **overview 限定**で、**深掘り audit と変更は各 owner へ delegate**（重複監査・重複変更をしない＝MECE）。

## When to Use

- 「ベスプラ点検して」「設定の健全性チェック」「Claude config audit」
- 「md ファイルやメモリーなど設定できていない点をレポートして」
- 「コンテキスト管理が最適化できているか確認して」「設定全体を見直したい」「健康診断」
- 月初・四半期初めの定期点検 (routine 化推奨)

**Proactive trigger**: 直近 90 日 audit を実行していない場合、起動時に「最後の点検から N 日経過、`/claude-config-audit` 実行を提案」

---

## Implementation Steps

### Phase 1: ベスプラ調査 (並列)

**目的**: 公式 docs から最新ベスプラを取得し 8 観点をカバー
**アクション**: `claude-code-guide` agent または `general-purpose` agent を使う

**8 観点**:
1. **CLAUDE.md 設計** — `@import` 構文 / サイズ目安 (200 行〜25KB) / 階層的読込
2. **Memory システム** — MEMORY.md インデックス / topic ファイル分離 / prune 戦略
3. **settings.json 階層** — user / project / local の使い分け / `defaultMode` / `deny` 配置
4. **Hooks** — PreToolUse / PostToolUse / Stop / UserPromptSubmit の活用パターン
5. **Skills / Commands** — SKILL.md frontmatter (paths, allowed-tools, context, disable-model-invocation)
6. **Permission Modes** — plan / auto / bypassPermissions の使い分けと安全策
7. **MCP** — user/project scope, deferred loading, lockdown
8. **Context 管理** — subagent (`context: fork`) / `/compact`, `/clear` の使い所

各観点に **公式 URL** (docs.claude.com / anthropic.com) を必ず添える

---

### Phase 2: 環境スキャン (並列)

**目的**: read-only で構成と履歴・キャッシュ系を取得
**アクション**: `Explore` agent を使う

**取得対象 (global、`~/.claude/`)**:
- **設定**: `settings.json` permissions / defaultMode / hooks / statusLine / plugins / `hooks/` / `skills/`
- **履歴・キャッシュ・状態系**: `projects/` (transcript 総サイズ / 件数 / mtime 60 日超数 / 100MB 超の単一巨大 / `subagents/`) / `history.jsonl` / `backups/.claude.json.backup.*` 世代 / `file-history/` / `telemetry/` / `paste-cache/` / `todos/` 60 日超 / `plugins/{cache,marketplaces}/` / `shell-snapshots/` / `tasks/`

**取得対象 (project、各 repo の `.claude/`)**:
- `CLAUDE.md` 全文 (行数 / @import 使用 / orphan な `rules/*.md` 参照) — **@import 検出は `grep '^@'` で行う**（構文は `@path` であって `@import` という文字列ではない。`@import` で grep すると全件見逃す。2026-05-23 誤報事例 [E4]）
- `settings.json`, `settings.local.json`
- `rules/`, `hooks/`, `commands/`, `skills/`, `~/.claude/state/recurring-tasks.json`
- **rules/CLAUDE.md 本文の剪定検査 [config-hygiene owner]**: ①同一/類似ルールの重複（CLAUDE.md 階層内＋ `rules/*.md` 間）②相互矛盾する規則 ③stale（廃止機能・古い path/概念を指す規則）④肥大（1 セクションが "5個でなく40個" 化）。検出は提案のみ、剪定は Phase 5 でユーザー承認後に Edit で反映（shell 直書きは governance gate が hard-block）
- `research/` 試運転項目の期限

**取得対象 (memory)**:
- `MEMORY.md` インデックスと実ファイルの整合
- 各 memory ファイルの粒度 (200 行超は要注意)

> ファクトベースで列挙、評価は本 skill 側で行う

---

### Phase 3: スコアリング

**カテゴリ評価**: ◎ / ◯ / △ / ×
**優先度分類**:
| 優先度 | 基準 |
|---|---|
| 🔴 高 | 公式ベスプラから明確に逸脱、セキュリティ・効率に影響 |
| 🟡 中 | 推奨に未準拠、改善で明確な効果あり |
| 🟢 低 | 観察対象、現状維持でも実害なし |

**スコア表テンプレ**:
```
| 項目 | 評価 | 主な所感 |
|---|---|---|
| CLAUDE.md 構成 | ◎/◯/△/× | ... |
| Memory 運用 | ... | ... |
| Skills 期限管理 | ... | ... |
| settings 階層 | ... | ... |
| Hooks | ... | ... |
| Rules 参照 | ... | ... |
| Permission policy | ... | ... |
```

---

### Phase 4: レポート出力 (会話内、ファイル化しない)

**セクション構成**:
1. **📊 総評** — スコア表
2. **🔴 優先度 高** — 各項目「ベスプラ」「現状 (ファイルパス:行番号)」「提案 (具体的な差分)」「出典 URL」
3. **🟡 優先度 中** — 同上
4. **🟢 優先度 低 (継続観察)**
5. **🎯 推奨アクション (時短ベース)** — # / アクション / 工数 / 効果
6. **📚 出典** — 公式 URL 一覧

**各提案には「実行コマンド or 編集差分」を具体的に書く** (提案だけで終わらせない)

---

### Phase 4b: クリーンアップ playbook (履歴・キャッシュ系)

> 「削除提案」ではなく「アーカイブ → 保留 → 必要なら purge」の **3 段階で reversibility 確保**

**標準アーカイブフロー**:
1. **archive 先**: `~/.claude/archive/cleanup-YYYY-MM-DD/<category>/`
   - category 例: `transcripts-large/`, `transcripts-old/`, `backups-old/`, `todos-stale/`
2. **構造保持で move** (削除ではない、即復旧可)
   - `~/.claude/projects/` 配下は `find ... -mtime +N | while read f; do mkdir -p && mv` で相対パス保持
3. **必要なら gzip 圧縮** (jsonl は ~10x 圧縮想定)
   - `find archive/.../*.jsonl | xargs -P 4 gzip`
   - 圧縮後も `zcat` / `gzcat` で中身確認可
4. **30 日後 purge を提案**
   - `recurring-tasks.json` の `archive-purge` entry が `last_run` から 30 日経過時に session-start で通知
   - skill 自身では purge せず、ユーザー承認後に削除

**アクティブ判定フローチャート** (100MB 超 transcript / 30 日超 dormant session を archive 候補にする前に):
1. **mtime**: 7 日以内なら active 候補 (archive 不可)
2. **last entry**: `tail -1 *.jsonl | jq .type` で `pr-link` / `summary` 等の終端マーカーあれば dormant 確定
3. **同 cwd の他 session**: 同 project に直近活動 session あれば dormant でも archive 推奨
4. **トピック確認**: 最初/最後の user/assistant message を読み、現在進行中の業務でないことを確認

判定例 (実機):
```
file: <session-id>.jsonl (134MB, <project>)
  mtime: 10 日前 → 7 日超 OK
  last type: pr-link → 終端 OK
  同 project: 5/9 別 session 活動中 → dormant 確定
  topic: Prod E2E QA リリース → 完了済み案件 → archive OK
```

---

### Phase 5: 実行確認

**目的**: ユーザー承認後、安全に変更を反映
**アクション**:
1. 必ずバックアップ: `cp file file.bak.before-config-audit-fix-YYYYMMDD`
2. 変更後に **JSON validate**: `python3 -c "import json; json.load(open(...))"`
3. 可能なら **before/after の検証** (hook 動作確認 / @import 反映 / `du -sh` 比較を**会話内で出すだけ**)
4. `recurring-tasks.json` の `last_run` を today に更新（**Edit tool で**。shell 直書きは governance gate が hard-block）
5. archive を作成した場合は `archive-purge` の `last_run` も更新

> **ログファイルは生成しない**。audit 実体は `~/.claude/archive/cleanup-YYYY-MM-DD/` のディレクトリ自体・本 SKILL.md の方法論・recurring-tasks.json の `last_run` で十分。markdown report ceremony は廃止 (2026-05-09 反省)

---

## Constraints

| Pattern | Preferred | Reason |
|---|---|---|
| 公式ドキュメント参照せず、ブログ記事や過去知識のみで判定 | Phase 1 で必ず公式 docs を一次情報として WebFetch | 古い情報・誤情報排除 |
| user / project / local scope の取り違え | 必ず `Read` で実ファイル確認 | 設定ミスの主因 |
| 「ベスプラに違反」と決めつけ、ユーザーの意図的選択を上書き | 「修正すべき」と「現状で問題なし」を**両方明示** | `bypassPermissions` 等の意図的選択を尊重 |
| 提案が抽象的 (「整理しましょう」だけで具体差分なし) | 「実行コマンド or 編集差分」を具体的に書く | 実行可能性担保 |
| ファイルとして audit log を書く | 会話内に出して終わり、ceremony 廃止 | doc 肥大化防止 (2026-05-09 反省) |
| 学びを反映せず終わる | 剪定の学びは config-hygiene / 該当 skill に反映（規則の**新規追加**と memory の L1 昇格は `lesson-harvest` へ渡す＝足す係/削る係を混ぜない） | 同じ指摘の繰り返し回避 + owner 分離維持 |
| `claude-config-audit` と `claude-stack-audit` を混同 | 本 skill = 公式 docs 起点 / `claude-stack-audit` = ニュース起点 | 責務分離 |

## Related Skills / Resources

| Skill / Resource | 関係 |
|---|---|
| `claude-stack-audit` | **補完**: ニュース起点の audit (本 skill は公式 docs 起点) |
| `claude-stack-news` | 週次ニュース source |
| `~/.claude/state/recurring-tasks.json` | 90 日 routine entry + `archive-purge` 30 日通知 |

## Routine 化 (既定)

`~/.claude/state/recurring-tasks.json` に entry 登録済 (trigger: `session-start-reminder`, interval_days: 90)。`claude` 起動時に due/overdue で `audit-reminder.sh` が context へ通知する。実行後は state file の `last_run` を today に更新するだけで次回までサイレント。

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | 2026-05-09 反省 | markdown report ceremony 廃止、audit 実体は archive ディレクトリ + recurring-tasks last_run で十分 |
| E2 | 実機例 (c42eaa3c... 134MB) | アクティブ判定 4 段階 (mtime / last type / 同 cwd 他 session / topic) で dormant 確定 |
| E3 | 90 日 routine 設計 | `~/.claude/state/recurring-tasks.json` + SessionStart hook で due/overdue 通知 |
| E4 | 2026-05-23 audit (個人環境) | Explore agent が `@import` 文字列で grep し `@path` 構文を全件見逃し「@import なし」と誤報。親が context の実ファイルと矛盾を検知し自分で `grep '^@'` 再確認して訂正。agent の grep 結果は context の事実と矛盾したら鵜呑みにせず再検証する |
