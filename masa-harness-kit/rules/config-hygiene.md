# Config Hygiene — owner マップ（Claude 環境保守の MECE 正本）

Claude 環境（settings/hooks・skills・commands・rules/CLAUDE.md・memory）の hygiene を **層ごとに単一 owner** へ割り当て、監査の重複（nag）と抜け（GAP）を防ぐ。各 audit skill は自レーンのみを担当し、越境しない。2026-06-07 制定（memory 層の owner 化を全 config 層へ横展開）。

## owner マップ（各層は1 owner）

| 層 | owner skill | 担当（する事） | 越境しない（しない事） |
|---|---|---|---|
| settings.json / hooks / 構造 | `claude-config-audit` | 公式ベスプラとの構造ギャップ、hook 健全性 | skill 中身・memory・skills sprawl |
| **rules / CLAUDE.md 本文の剪定** | `claude-config-audit`（**GAP を割当**） | 重複・stale・"5個でなく40個"肥大・規則衝突の**剪定**（削る側） | 規則の追加（lesson-harvest が担当） |
| skills / commands | `claude-skill-audit` | template 準拠・registry DRY/MECE・**8–12 sprawl 閾値・disable-unused・`/doctor` budget**・commands 棚卸し | settings 構造・memory |
| memory（L1昇格 + L2 整理） | `lesson-harvest`（L1昇格を兼務）+ 必要時に手動 | L1昇格候補の検出と反映は lesson-harvest が担当。cross-project 重複・stale path の整理は必要時に手動で | skill/settings 構造 |
| 規則の**追加**（足す側） | `lesson-harvest` | 繰り返し指摘 → CLAUDE.md/rules への追記起案 | 剪定（config-audit へ渡す） |

**重複解消の要点**: 「足す係（lesson-harvest）／削る係（config-audit）」を分離。dedup は「memory=lesson-harvest（L1昇格）/ skills=skill-audit / rules=config-audit」と層で分割し、同一 task を複数 audit が持たない。

> **横断統括 skill は設けない**: hygiene をまとめて点検したい時は各 owner skill（`claude-config-audit` / `claude-skill-audit` / `lesson-harvest`）を**個別に実行**する（束ねて一括で回す統括ランナーは存在しない）。
> **`claude-stack-audit` は本マップの対象外**（混同注意）: これは hygiene（環境保守）skill では**なく**、「**新着アップデート起点**」で新機能を「導入すべき/様子見/不要」に分類する採用判断＋セキュリティ監査 skill。「**公式ベスプラ起点**」で設定の健全性を診る `claude-config-audit` とは**起点も目的も別物**。名前が `*-audit` で似ているだけで owner レーンを持たない。

## best practice（2026 調査・実行基準）

- **グローバル規則は CLAUDE.md（lean・常時）／ドメイン手順は skill**（Thin Harness, Fat Skills と一致）
- **skill sprawl は 8–12 個が分水嶺**。超過分は "context tax"（使わなくても払うトークン）。**未使用 skill は即 disable**、layer ごと **>10 で audit 発火**
- skill description は context の約 **1%** にスケール、溢れると低頻度 skill の description から脱落 → **`/doctor` で budget overflow を可視化**（skill-audit が点検）
- **「lint であって nag でない」**: 監査本数を増やさない。統合と単一 owner で meta 疲労を抑える
- 外部 memory OSS（mem0/Zep/Letta/Cognee 等）を足すなら、既存の記憶系（CLAUDE.md 階層 + auto-memory）と機能重複しないか確認する（運用2系統化は負債）

## cadence（週次を down-service しない・効く範囲で軽く最適化のみ）

- **安い週次（据置）**: claude-stack-news（トレンド digest）など軽いものは週次のまま据え置く
- **hygiene 監査の週次 due は維持**（config / skill / memory）。実作業は軽いので**頻度は落とさない**（週次→月次のダウングレードはしない）
- hygiene をまとめて点検したい時は各 owner skill（config-audit / skill-audit / lesson-harvest）を**個別に実行**する。週次 due の置換ではなく上乗せ。明確に効く範囲でのみ軽く最適化する（過剰な統合をしない）。**`claude-stack-audit` はここに含めない**（新着アップデート起点の採用判断 skill であって hygiene の統括ランナーではない）

## 関連
- 各 owner skill: `claude-config-audit` / `claude-skill-audit` / `lesson-harvest`（`~/.claude/skills/`）
- 本マップ対象外（混同注意・新着アップデート起点）: `claude-stack-audit`（hygiene ではなく採用判断 skill）
- recurring: `~/.claude/state/recurring-tasks.json`（hygiene 監査を週次 entry として回す）
- メモリ3層モデル（L1=CLAUDE.md 階層 / L2=auto-memory / L3=任意の semantic 検索）は CLAUDE.md / README 参照
