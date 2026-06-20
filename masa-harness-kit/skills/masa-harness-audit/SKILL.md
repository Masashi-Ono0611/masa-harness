---
name: masa-harness-audit
description: |-
  masa-harness-kit の最新版と、あなたの現在の Claude Code 設定（~/.claude）の差分を監査し、
  「取り込むと良い差分」だけを推奨理由付きで提示して、承認したものだけを反映する skill。
  「masa-harness を audit して」「kit の良いところだけ取り込んで」「harness を強化して」
  「masa-harness の差分を見せて」で発動。全部上書き（setup.sh の overwrite）したくない人向けの
  選択的アップグレード経路。読み取り優先・反映は承認後のみ。
updated_at: 2026-06-20
---

# masa-harness-audit

masa-harness-kit の最新版とあなたの `~/.claude` を比較し、**良い差分だけを選んで harness を強化する** skill。
`setup.sh` の overwrite が「全部 masashi 版にする」のに対し、これは「**あなたの設定を主、kit を参考に良いとこ取り**」する。

## Step 一覧（5 段）

| Step | 内容 |
|---|---|
| 1 | 最新 kit の在処を特定（`~/.masa-harness/masa-harness-kit`） |
| 2 | kit ↔ `~/.claude` の差分を列挙（NEW / DIFF をファイル単位で） |
| 3 | 各差分を読み、**推奨度（高/中/低）＋理由**を付けて提示 |
| 4 | ユーザーが採否を選択（[stop] 承認待ち） |
| 5 | 承認分のみ反映（タイムスタンプ backup → 配置）、結果を要約 |

## Constants

| 名前 | 値 |
|---|---|
| 最新 kit ルート | `~/.masa-harness/masa-harness-kit`（curl install のキャッシュ） |
| 反映先 | `~/.claude/`（CLAUDE.md / settings.json / rules / hooks / skills / state） |
| version 記録 | `~/.claude/.masa-harness/version`（現在の取り込み版） |
| 差分レポート | `~/.claude/.masa-harness/AUDIT-REPORT.md`（setup.sh safe モードが残す） |
| backup 形式 | `<target>.bak-YYYYMMDD-HHMMSS`（上書き前に必ず取る） |

## 責務範囲（被りなし）

| 用途 | 本 skill | setup.sh |
|---|---|---|
| 全部 masashi 版にする | ❌ | ✅ `MASA_MODE=overwrite` |
| 良い差分だけ選んで反映 | ✅ | ❌ |
| 新規インストール / 更新の一括展開 | ❌（delegate） | ✅ fresh / install |
| 既存を壊さない差分レポート生成 | ✅（読み解く側） | ✅ safe モードが生成 |

## When to Use

- 既に自分の `~/.claude` を育てていて、kit を**丸ごと上書きはしたくない**
- kit が更新された（`setup.sh` safe モードが DIFF を報告した）ので、良い分だけ取り込みたい
- スキップ条件: まだ harness が無い（→ `setup.sh` の fresh install を使う方が早い）

## Implementation Steps

### Step 1: 最新 kit の在処を特定

**目的**: 比較元（最新 kit）のパスを確定する
**条件**: `~/.masa-harness/masa-harness-kit` があればそれを使う。無ければユーザーに「kit をどこに展開したか」を尋ねる（tar.gz 解凍先など）
**アクション**:
```bash
KIT="${HOME}/.masa-harness/masa-harness-kit"
[ -d "$KIT" ] || echo "kit が見つかりません。install.sh を実行したか、解凍先パスを教えてください"
cat "$KIT/VERSION" 2>/dev/null
cat "${HOME}/.claude/.masa-harness/version" 2>/dev/null   # 現在の取り込み版
```
**完了条件**: 比較元 KIT パスと、両者のバージョンが分かった

### Step 2: 差分を列挙

**目的**: NEW（あなたに無い）/ DIFF（内容が違う）ファイルを洗い出す
**条件**: なし
**アクション**: `setup.sh` が safe モードで残した `~/.claude/.masa-harness/AUDIT-REPORT.md` があればそれを起点にし、無ければ自分で kit と `~/.claude` を sha256 比較してファイル単位で NEW/DIFF を出す。config（CLAUDE.md/settings.json/recurring-tasks）と skills/rules/hooks を分けて扱う
**完了条件**: 差分ファイルの一覧ができた（0 件なら「最新です」で終了）

### Step 3: 各差分に推奨度＋理由を付ける

**目的**: ユーザーが採否を判断できる材料を作る（claude-stack-audit と同じ「読み取り専用・推奨提案」思想）
**条件**: なし
**アクション**: 差分ファイルごとに実際の中身（diff）を読み、以下を 1 行で提示:
- **推奨度**: 🟢高（安全装置・明確な改善）/ 🟡中（好み次第）/ 🔴低（masashi 環境固有で他人には不要な可能性）
- **理由**: 何が変わる/増えるか、なぜ薦める/薦めないか
- **衝突注意**: あなたが手で編集した形跡があるファイル（特に CLAUDE.md）は「あなたの編集が backup される」旨を明記
**完了条件**: 全差分に推奨度と理由が付いた表ができた

### Step 4: ユーザーの採否選択（承認待ち）

**目的**: 何を反映するかの最終決定をユーザーに委ねる
**条件**: 反映（書き込み）の直前
**アクション**: 推奨度付きの一覧を提示し、「どれを取り込みますか?（例: 高だけ / 個別指定 / 全部 / やめる）」と尋ねて **[stop] 応答待ち**。CLAUDE.md のような個人設定を上書きする選択には「あなたの現 CLAUDE.md は backup されます」と明示確認する
**完了条件**: 反映対象ファイルがユーザー承認で確定した

### Step 5: 承認分のみ反映

**目的**: 選ばれたファイルだけを安全に反映する
**条件**: Step 4 で承認が取れていること（未承認なら何もしない）
**アクション**: 承認された各ファイルについて:
```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
DST="${HOME}/.claude/<相対パス>"
[ -e "$DST" ] && cp "$DST" "${DST}.bak-${STAMP}"   # 上書き前に必ず backup
mkdir -p "$(dirname "$DST")"
cp "$KIT/<kit 相対パス>" "$DST"
```
hooks を入れたら `chmod +x` を付ける。反映後、何を入れ/何を見送り/どこに backup したかを要約する
**完了条件**: 承認分が反映され、backup 先と「見送った差分」がユーザーに伝わった

## Constraints

### 致命的 (Errors)
| Pattern | Preferred | Reason |
|---|---|---|
| 承認なしでファイルを書き換える | Step 4 の [stop] 承認を必ず通す | 利用者の育てた設定を勝手に破壊する |
| 上書き前に backup を取らない | `cp $DST $DST.bak-<stamp>` を必ず先に | 元に戻せなくなる（このskillの存在意義に反する） |
| CLAUDE.md を黙って masashi 版に置換 | 「あなたの編集が backup される」と明示確認 | 個人化の塊を無断置換すると信頼を失う |

### 注意 (Warnings)
| Pattern | Preferred | Reason |
|---|---|---|
| 🔴低（環境固有）を無条件で薦める | gbrain / Mac mini 等 masashi 固有依存は「他環境では不要かも」と添える | 動かない設定を増やすと混乱する |
| 全 SAME を逐一報告 | NEW/DIFF のみ提示 | ノイズで判断が鈍る |
| version ファイルを勝手に最新へ更新 | 部分反映では version を据え置く（全反映は setup.sh に任せる） | 「最新を全部入れた」と誤認させない |

## Related Skills / Resources
- `setup.sh`（kit 同梱）— 一括展開と 3 モード（fresh/safe/overwrite）。全部入れるならこちら
- `claude-stack-audit`（kit 同梱）— Claude Code 全体の新機能監査（本 skill の思想の源流・読み取り専用×推奨提案）
- `claude-config-audit`（kit 同梱）— settings.json/hooks の構造健全性点検

## Evidence Index
| ID | 出典 | 学び |
|---|---|---|
| E1 | masa-harness リリース設計 2026-06-20 | 「全上書き」と「良いとこ pick」は別経路にすべき。後者は読み取り優先＋承認後反映＋必ず backup |
