---
name: claude-skill-audit
description: |-
  `~/.claude` と管理対象 repo 配下の全 `.claude/skills/` から **個人 skill のみ** (gitignore/untracked、tracked=チーム作成は除外) を抽出し、`@.claude/rules/skill-template.md` 準拠でチェック (構造 / 行数 soft cap / anti-pattern grep) + Codex マルチモデルレビュー (大物 skill 限定) で Critical / Warning を集約 → 修正候補リストを出力。承認後は各自の PR フロー skill に delegate して反映。月 1 回 routine または skill 大改修後の checkpoint。「skill audit」「skill 健全性チェック」「個人 skill を template 準拠でチェック」「全 skill を Codex review」「skill の重複検出」「MECE / resolver 監査」「check resolvable」で発動。引数 `--repo=<name>` で個別リポ指定可、無指定で全 repo audit。Step 4b で registry 横断の DRY+MECE pass (YC `check_resolvable` 相当) も実施。
scope: local-only
disable-model-invocation: true
updated_at: 2026-06-13
---

# Claude Skill Audit

> **環境前提**: 管理対象 repo を置くディレクトリは環境変数 `REPOS_BASE`（既定 `$HOME/Developer`）で指定する。個人 skill / rules は user-global の `~/.claude` 配下にある前提。

`@.claude/rules/skill-template.md` (~/.claude/rules 配下、CLAUDE.md から import 済) のベスト形式に対して、個人 skill 群を機械的に監査する meta skill。

## Step 一覧 (8 段)

| Step | 内容 | 完了条件 |
|---|---|---|
| 1 | 対象 repo / skill リスト確定 (個人 skill のみ、git untracked) | repo × skill のリスト |
| 2 | 構造 audit (必須セクション有無、frontmatter validity) | section 欠落リスト |
| 3 | 行数 soft cap 監査 (>500 行で `references/` 外出し候補化) | 超過 skill リスト |
| 4 | Anti-pattern grep (対話式コマンド / undefined 変数 / 暗黙 skip / 絵文字濫用) | 検出箇所リスト |
| 4b | **registry 横断 DRY+MECE pass** (skill 同士の責務重複・MECE 欠落を検出。YC `check_resolvable` 相当) | 重複ペア / 集約候補リスト |
| 5 | Codex マルチモデルレビュー (大物 skill 限定 3-4 個に絞り usage limit 回避) | Critical / Warning リスト |
| 6 | 結果 summary + 修正候補表 → ユーザー承認 | 承認待ち |
| 7 | 承認後の修正 (= 各 repo の `multi-model-pr-flow` に delegate して PR 化、または個別 Edit) | 完了報告 |

## Constants

| 名前 | 値 |
|---|---|
| template SoT | `@.claude/rules/skill-template.md` (~/.claude/rules 配下) |
| 対象 repo | `<org>/<repo>` 形式で複数指定可 (存在するもののみ) |
| 必須セクション (template 準拠) | Step 一覧 / Constants / 責務範囲 / When to Use / Implementation Steps / Constraints / Related Skills / Evidence Index |
| 行数 soft cap | 500 行 |
| Anti-pattern (Critical) | `git add -p` / undefined `$PR` 等 / `/review:self-multi-model` の `--base` 省略 / `gh pr merge` 前 guard なし |
| Codex review 対象 | 250 行超 skill のみ (usage limit 回避) |
| 個人 vs チーム判定 | `git ls-files SKILL.md` が空 = 個人 |
| sprawl 閾値 (best practice 2026) | 1 layer **8–12 個**で "context tax" 発生。layer ごと **>10 で要 audit**・**未使用は即 disable** |
| context budget | skill description は context の約 **1%**。溢れると低頻度 skill の description 脱落 → `/doctor` で overflow 可視化 |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `claude-config-audit` (global) | `claude-stack-audit` (global) |
|---|---|---|---|
| **個人 skill 群の template 準拠 / 行数 / anti-pattern audit + Codex review** | ✅ | ❌ | ❌ |
| **skill registry 横断の DRY+MECE / 重複・集約候補検出 (`check_resolvable` 相当)** | ✅ Step 4b | ❌ | ❌ |
| `~/.claude` (CLAUDE.md / settings / hooks) 全体構成の健全性 | ❌ | ✅ | ❌ |
| Claude Code エコシステム update との差分監査 + 導入提案 | ❌ | ❌ | ✅ |

> **skills と commands/ は本 skill が owner**（SoT: `rules/config-hygiene.md`）。**sprawl 8–12 閾値・disable-unused・`/doctor` budget**（Step 1b）も本 skill が見る。settings/hooks/rules 剪定は `claude-config-audit`、memory の L1 昇格は `lesson-harvest` が兼務、規則追加は `lesson-harvest`。

## When to Use

- 月 1 回 routine (`/schedule` で月初に設定推奨)
- skill 大改修後の checkpoint (例: 今 session 末尾で 9 個一括最適化した直後)
- `skill-template.md` 改訂後に既存 skill が追随できているか確認
- 「skill audit」「skill 健全性チェック」「個人 skill を template 準拠でチェック」「全 skill を Codex review」

**スキップ条件**: 1 skill だけの軽微修正後は本 skill 不要 (直接 Edit で十分)

---

## Implementation Steps

### Step 1: 対象 repo / skill リスト確定

**目的**: 個人 skill のみを抽出 (tracked = チーム作成は除外)
**アクション**:
```bash
REPOS_BASE="${REPOS_BASE:-$HOME/Developer}"   # 管理対象 repo の置き場。環境変数で上書き可
# skill 引数は $ARGUMENTS で渡る (Claude Code 仕様)。--repo=<name> 形式をパース
TARGET_REPO=$(echo "${ARGUMENTS:-}" | sed -n 's/.*--repo=\([^ ]*\).*/\1/p')

# user-scope (~/.claude/skills) と各 repo の .claude/skills を全網羅
SKILL_ROOTS=("$HOME/.claude/skills")
# 管理対象 repo を列挙する (例: org1/repo1 org2/repo2)
for r in <org1>/<repo1> <org2>/<repo2>; do
  SKILL_ROOTS+=("$REPOS_BASE/$r/.claude/skills")
done

for skills_root in "${SKILL_ROOTS[@]}"; do
  [ -d "$skills_root" ] || continue
  repo_name=$(echo "$skills_root" | sed "s|$REPOS_BASE/||; s|$HOME/|~/|; s|/.claude/skills||")
  [ -n "$TARGET_REPO" ] && [ "$repo_name" != "$TARGET_REPO" ] && continue
  echo "=== $repo_name ==="
  cd "$(dirname "$(dirname "$skills_root")")" 2>/dev/null || cd "$REPOS_BASE"   # repo root (git ls-files 用)
  for skill_dir in "$skills_root"/*/; do
    skill_name=$(basename "$skill_dir")
    skill_file="${skill_dir}SKILL.md"
    [ -f "$skill_file" ] || skill_file="${skill_dir}TIPS.md"   # shared ref 対応
    [ -f "$skill_file" ] || continue
    if git ls-files --error-unmatch "$skill_file" >/dev/null 2>&1; then
      tag="TEAM (skip)"
    else
      tag="PERSONAL"
    fi
    lines=$(wc -l < "$skill_file")
    printf "  %-40s %5d lines  %s\n" "$skill_name" "$lines" "$tag"
  done
done
```

**完了条件**: 個人 skill のみのリスト + 各行数

---

### Step 1b: sprawl・context-budget・commands 棚卸し [config-hygiene best-practice]

**目的**: skill 数の肥大（"context tax"）/ 未使用 skill / context budget overflow / commands カバー漏れを検出（`rules/config-hygiene.md` で skills+commands は本 skill が owner）。
**アクション**:
```bash
# (1) layer ごとの skill 数（8–12 が分水嶺、>10 で警告）
# nested repo (<org>/<repo> 形式) も拾うため */ と */*/ の両方を glob
for d in "$HOME/.claude/skills" "$REPOS_BASE"/*/.claude/skills "$REPOS_BASE"/*/*/.claude/skills 2>/dev/null; do
  [ -d "$d" ] || continue
  n=$(ls -1d "$d"/*/ 2>/dev/null | wc -l | tr -d ' ')
  flag=""; [ "$n" -gt 10 ] && flag=" ⚠️ >10 (context tax)"
  echo "  $d : $n skills$flag"
done
# (2) commands/ も棚卸し（skill と同レーン・owner=本 skill）
for d in "$HOME/.claude/commands" "$REPOS_BASE"/*/.claude/commands "$REPOS_BASE"/*/*/.claude/commands; do
  [ -d "$d" ] && echo "  commands: $d : $(find "$d" -name '*.md' | wc -l | tr -d ' ') files"
done
# (3) /doctor は対話内で実行: `claude` 起動中に /doctor を打ち skill description budget overflow を控える
```
判定:
- layer >10 → **未使用 skill を `disable-model-invocation: true` 化 or 削除候補**として提示（使用実績は transcript / (任意) semantic 検索ツールで確認）
- `/doctor` が budget overflow → 低頻度 skill の description 短縮 or disable
- commands/ も template/重複の観点で Step 2-4b の対象に含める

**完了条件**: layer 別 skill/commands 数 + >10 layer + disable 候補 + budget 状態

---

### Step 2: 構造 audit (必須セクション有無)

**目的**: `skill-template.md` 準拠の必須 H2 セクションが揃っているか確認
**アクション**:
```bash
REQUIRED_SECTIONS=("## Step 一覧" "## Constants" "## 責務範囲" "## When to Use" "## Implementation Steps" "## Constraints" "## Related Skills" "## Evidence Index")

for skill in <Step 1 で確定した PERSONAL skill 一覧>; do
  echo "--- $skill ---"
  for s in "${REQUIRED_SECTIONS[@]}"; do
    if grep -qF "$s" "$skill"; then
      echo "  ✅ $s"
    else
      echo "  ❌ MISSING: $s"
    fi
  done
  # frontmatter validity
  if head -1 "$skill" | grep -q "^---$"; then
    awk '/^---$/{c++; next} c==1' "$skill" | grep -qE "^(name|description):" || echo "  ❌ frontmatter incomplete"
  else
    echo "  ❌ frontmatter missing"
  fi
done
```
**完了条件**: 欠落セクションを skill ごとに列挙

> **柔軟性**: shared reference (`TIPS.md`) は SKILL.md とは別構造のため audit 対象外 (Step 1 で除外)。`Constants` / `Evidence Index` が無いケースは「短小 skill」として warning に降格

---

### Step 3: 行数 soft cap 監査

**目的**: 500 行超は `references/` 外出し候補
**アクション**:
```bash
SOFT_CAP=500
for skill in <PERSONAL skill 一覧>; do
  lines=$(wc -l < "$skill")
  if [ "$lines" -gt "$SOFT_CAP" ]; then
    # どの section が大きいか測る (awk で count, sort で数値降順)
    echo "⚠️ $skill: $lines lines (cap=$SOFT_CAP)"
    awk '/^## /{if (h) print count" "h; h=$0; count=0; next} {count++} END{if (h) print count" "h}' "$skill" \
      | sort -rn | head -5
  fi
done
```
**完了条件**: 超過 skill と「どの section が大きいか」top 5 を出力

---

### Step 4: Anti-pattern grep

**目的**: Critical anti-pattern (Codex review 由来) が混入していないか
**アクション**:
```bash
for skill in <PERSONAL skill 一覧>; do
  hits=""

  # (1) 対話式 git add -p
  grep -n "git add -p" "$skill" >/dev/null 2>&1 && hits="$hits\n  ❌ git add -p (対話式禁止)"

  # (2) /review:self-multi-model に --base が付いてない call
  if grep -q "/review:self-multi-model" "$skill"; then
    grep -n "/review:self-multi-model" "$skill" | grep -v -- "--base" | grep -v "本体" | grep -v "実行" | grep -v "delegate" \
      | head -3 | while read line; do
        hits="$hits\n  ⚠️ --base 不在の可能性: $line"
      done
  fi

  # (3) gh pr merge 前の base guard (ざっくり grep)
  if grep -q "gh pr merge" "$skill"; then
    grep -B5 "gh pr merge" "$skill" | grep -qE "(baseRefName|BASE_CHECK|baseRefName == staging|ABORT)" \
      || hits="$hits\n  ⚠️ gh pr merge 前の base guard が見当たらない"
  fi

  # (4) 装飾系絵文字 (📌🎉🔄)
  count=$(grep -cE "📌|🎉|🔄" "$skill")
  [ "$count" -gt 3 ] && hits="$hits\n  ⚠️ 装飾絵文字濫用 (📌🎉🔄 計 $count 件)"

  if [ -n "$hits" ]; then
    echo -e "--- $skill ---$hits"
  fi
done
```
**完了条件**: 検出箇所を skill ごとに列挙

---

### Step 4b: registry 横断 DRY+MECE pass (YC `check_resolvable` 相当)

**目的**: skill registry 全体を見渡し、**責務が重複する skill ペア (DRY 違反)** と **カバー漏れ (MECE 欠落)** を検出する。Step 2-4 は per-skill 適合チェックだが、本 Step は「10 個の似た skill より 1 個のパラメータ化 skill」という registry レベルの最適化を見る (YC 動画 B246K_G7mHU で Gary Tan が skillify のたびに回すと述べた `check_resolvable` = DRY + MECE resolver 監査の取り込み)。
**条件**: 常時実行 (skill 数が増えるほど ROI が上がる)。registry 横断のため Step 1 の per-repo リストに **user-scope global 個人 skill** (`$HOME/.claude/skills/`) も合算して overlap matrix を作る (重複は global × repo を跨いで発生するため)
**アクション**:
```bash
# 全個人 skill の name + description (frontmatter) + 責務範囲表を 1 箇所に集約
GLOBAL_SKILLS="$HOME/.claude/skills"
{
  for f in "$GLOBAL_SKILLS"/*/SKILL.md 2>/dev/null; do
    [ -f "$f" ] || continue
    name=$(awk '/^name:/{print $2; exit}' "$f")
    desc=$(awk '/^description:/{flag=1} flag&&/^[a-z_]+:/&&!/^description:/{flag=0} flag' "$f" | head -3 | tr '\n' ' ')
    printf "%-30s | %s\n" "$name" "$desc"
  done
  # Step 1 で確定した per-repo PERSONAL skill も同形式で append
} > /tmp/skill-registry.txt
cat /tmp/skill-registry.txt
```
集約後、description / 責務範囲を突き合わせて以下を **人間 (Claude) が判断**して列挙する (機械 grep でなく意味的判断):
1. **重複ペア (DRY 違反候補)**: 同じ task が複数 skill に「✅」になっていないか。例: `claude-config-audit` × `claude-stack-audit` × `claude-skill-audit` の境界 (既に責務範囲表で分離済みか再確認)
2. **MECE 欠落**: あるべき機能のカバー漏れ / どの skill にも属さない隙間タスク
3. **集約候補**: 2 個以上の似た skill を 1 個のパラメータ化 skill に畳めるか (畳む場合の trade-off も)
4. **altitude (分解) smell-test**: 各 skill が「skill」の高度として妥当か (Tool/Skill/Subagent 取り違え) を判定。下記「## 分解 smell-test」を各 skill に当て、誤高度を列挙 (registry の DRY/MECE とは別軸＝個々の altitude)

> **判定原則** (skill-template.md「責務範囲 (被りなし)」と整合): 重複が見つかったら SoT を 1 箇所に決め、他は `❌ (delegate / 参照のみ)` に寄せる。**勝手に統廃合しない** — Step 6 で候補提示 → 承認後のみ。

**完了条件**: 「重複ペア」「MECE 欠落」「集約候補」を理由付きで列挙 (なければ「registry は DRY+MECE 良好」と明記)

---

### Step 5: Codex マルチモデルレビュー (250 行超 skill 限定)

**目的**: 大物 skill に対して構造 / 完了条件 / 副作用 guard / Constants 散在を Codex で深掘り
**条件**: 行数 250 超の skill のみ (usage limit 回避、軽量 skill は Step 2-4 で十分)

**アクション** (skill ごとに順次):
```bash
for skill in <250 行超 skill のみ>; do
  echo "=== Codex review: $skill ==="
  codex exec "以下の Claude Code skill ファイルを Anthropic 公式 Claude Code Skills docs と \`@.claude/rules/skill-template.md\` (~/.claude/rules) のベスト形式に基づいてレビューしてください。指摘は 3 分類で:
- (C) Critical: Claude が走らせると詰まる / 誤動作
- (W) Warning: 可読性 / 保守性で改善余地
- (S) Suggestion: あれば良いが必須でない

簡潔に、各指摘は 1-3 行で。ファイル: $skill" 2>&1 | tail -60
  echo ""
done
```

> usage limit 検出時はマルチモデルレビュー CLI fallback (`gh pr diff | <cli> -p "<prompt>"` 形式)。詳細は各自の PR フロー skill を参照。

**完了条件**: 全大物 skill に対し Critical / Warning / Suggestion 抽出済

---

### Step 6: 結果 summary + 修正候補表

**目的**: Step 2-5 を 1 つの表に集約 → ユーザー承認待ち
**フォーマット**:

```markdown
## Skill Audit Report (YYYY-MM-DD)

### 対象 (個人 skill のみ、N 個)
- <org>/<repo>: N 個 (合計 M 行)
- user-scope global: N 個 (合計 M 行)
- ...

### 修正候補

| Skill | 行数 | 必須セクション | Anti-pattern | Codex Critical | 推奨修正 |
|---|---|---|---|---|---|
| example-skill-A | 577 | ✅ | git add -p 残存 1 | $PR undefined 1 | 即修正 (~10 分) |
| example-skill-B | 421 | ❌ Constants 欠落 | なし | N/A (<250 行制限) | Constants 追加 (~5 分) |
| example-skill-C | 152 | ✅ | なし | N/A | 修正不要 |

### registry 横断 DRY+MECE (Step 4b)

| 種別 | 該当 | 推奨 |
|---|---|---|
| 重複ペア (DRY) | `<skillA>` × `<skillB>` が task X で両方 ✅ | SoT を一方に寄せ他は delegate |
| MECE 欠落 | task Y がどの skill にも属さない | 既存 skill に Step 追加 or 新規検討 |
| 集約候補 | `<skillC>` `<skillD>` をパラメータ化 1 個に | trade-off 提示の上で判断 |
| altitude (分解) | `<skillX>` は単一アクション → tool/hook 化候補 / 反復インライン手順 → skill 昇格候補 | deterministic tool へ寄せる / skill に集約 |
| (なければ) | registry は DRY+MECE 良好 | — |

### 推奨アクション
1. **Critical: 即修正必要** (N 件): ...
2. **Warning: 時間あれば**: ...
3. **修正不要**: ... 個

このまま **`<repo>` の PR フロー skill で PR 化**して反映しますか?  
それとも個別 Edit で対応? (skill 修正は単一ファイル変更が大半なので個別 Edit でも十分)
```

**完了条件**: ユーザーが修正方針を選択 ("PR 化" / "個別 Edit" / "後回し")

---

### Step 7: 承認後の修正

**条件**: ユーザーが「PR 化」または「個別 Edit」を選択
**アクション**:

#### Option A: PR 化 (該当 repo の PR フロー skill に delegate)

```
Skill(<project>-pr-flow) 入力: 修正対象 skill ファイル一覧 + 修正内容指示
期待出力: PR merged + QA Skip (skill = doc 扱いで QA 不要) + cleanup 済
```

#### Option B: 個別 Edit (skill 数件・行数小なら fast path)

各 skill に対し `Edit` で修正適用 → 完了報告のみ (PR 不要、個人 skill は gitignore 配下なので commit 不要)

**完了条件**: 全修正適用済 + 再 audit で Critical / Warning が解消

---

## 分解 smell-test (Tool / Skill / Subagent altitude)

agent-decomposition (CwC WS) 由来。Step 4b で各 skill に当て、**高度の取り違え**を検出する。「skill にすべきか」は registry の DRY/MECE とは別軸＝個々の altitude (CLAUDE.md「知能は skill へ・実行は deterministic tool へ・harness は薄く」の per-skill 適用)。

| 兆候 | 取るべき形 | 理由 |
|---|---|---|
| 単一の決定的アクション (多段なし・判断なし・毎回同じ副作用) | **Tool / hook / script** (skill でなく) | skill は description が常時 context を食う (context tax)。「実行は deterministic tool へ」と一致 |
| 「**常に X の前に Y**」等の不変手順が複数箇所で反復 | **Skill** に昇格 | 反復インライン指示は drift する。手順は skill に集約 |
| 出力が実質1値 (verdict / 件数 / pass-fail) で終わる委譲 | **subagent にしない** (inline / tool 1発) | subagent は多段・context 重・統合出力の機構。スカラー結果にはオーバーヘッド |
| tool 定義 or 典型出力が大きい (>~2k tok) | **code-exec / on-demand** へ | 毎ターン context を膨らませる。必要時ロードに |

判定は機械でなく意味的に (Step 4b と同じく Claude 判断)。誤高度は Step 6 報告表の altitude 行に列挙し、**勝手に作り替えない**＝承認後のみ。

---

## Constraints

### 致命的 (Errors)

| Pattern | Preferred | Reason |
|---|---|---|
| チーム skill (tracked) も audit 対象に含める | Step 1 で `git ls-files` 判定で除外 | チーム規約と template は別、誤った修正提案で混乱 |
| Codex を全 skill (含む短小 skill) に走らせる | 250 行超に限定 | usage limit 消費、軽量 skill は Step 2-4 で十分 |
| ユーザー承認なしに修正適用 | Step 6 で必ず承認待ち、Step 7 で適用 | 機械判定の False Positive を弾く機会 |
| `references/` 外出し候補を audit が勝手に実行 | 推奨のみ提示、実 split は user 判断 + 個別 Edit | 構造変更は影響範囲大、人間判断必須 |

### 注意 (Warnings)

| Pattern | Preferred | Reason |
|---|---|---|
| `skill-template.md` が古いまま audit を回す | 直前に template 自体の更新が必要か `git log` 確認 | template ⇆ skill の双方向 drift があると noise が増える |
| Anti-pattern grep の False Positive を skill に修正反映 | Step 6 で必ず human review、文脈で問題ない grep 結果は skip 印 | 機械的 grep は context を見ない |
| Codex review の Suggestion を全部反映 | Critical / Warning のみ反映、Suggestion は将来課題として skill に TODO コメント残す | 重要度低の指摘で行数肥大化 |
| 月 1 routine をサボってから一気に全 skill 修正 | 定期実行 (月初) + skill 大改修直後の checkpoint | 一気にやると変更量大、Codex review も usage limit 直撃 |

---

## Related Skills / Resources

| Skill / Resource | 関係 |
|---|---|
| `@.claude/rules/skill-template.md` ($HOME/.claude/rules 配下) | **本 skill の audit 基準 SoT** |
| `claude-config-audit` (user-scope global) | 別軸: `~/.claude` 全体構成の健全性 (本 skill は個人 skill のみ) |
| `claude-stack-audit` (user-scope global) | 別軸: Claude Code エコシステム update との差分監査 |
| `<project>-pr-flow` (各自 PR フロー skill) | Step 7 (修正適用) で delegate 可、ただし skill = doc 扱いで QA は skip |
| `/schedule` | 月 1 routine 化に利用 (例: 月初 09:00 JST 自動起動) |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | 実運用セッション (個人 skill 9 個一括最適化) | テンプレ準拠で複数 skill を書き直した直後の checkpoint として audit があれば、行数 cap / 必須セクション / anti-pattern を機械検出できる |
| E2 | 実運用セッション (PR フロー skill マルチモデルレビュー) | マルチモデルレビュー CLI から Critical 5-6 件抽出可。skill ファイル単体 review は `codex exec` 等で行える (大物のみ走らせれば usage limit 回避) |
| E3 | `$HOME/.claude/rules/skill-template.md` 永続化 | CLAUDE.md `@` import 経由で全 repo の skill 生成時に template 展開される設計。audit はその template との差分検出 |
| E4 | YC 動画 B246K_G7mHU "How to Build Superintelligence Inside Your Company" (Gary Tan / Pete Koomen) | skillify のたび `check_resolvable` (全 skill/tool を DRY+MECE で見渡す resolver 監査) を回す運用。per-skill 適合 (Step 2-4) では捕れない registry レベル重複を Step 4b として取り込み |
| E5 | CwC WS `agent-decomposition` | Tool→Skill→Subagent の altitude 判定 (単一アクションは tool 化 / 反復手順は skill 昇格 / スカラー出力に subagent 不要) を Step 4b 判定項目 + 分解 smell-test 節として注入。registry DRY/MECE とは別軸の per-skill altitude チェック |
