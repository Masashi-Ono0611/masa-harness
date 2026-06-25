---
name: vuln-scan
description: |-
  全リポを定期診断し「依存(npm)CVE」+「ランタイム/コンテナ(ベースイメージ)CVE」+「EOL ランタイム」を一括検出して『対応要 / 監視 / 無視』にトリアージする継続セキュリティ診断 skill。Trivy 1本(+endoflife.date)で、Dependabot/npm audit が**見られないランタイム本体の CVE**（Node/Python/Go コア）まで捕捉する。「脆弱性診断」「vuln scan」「セキュリティ診断回して」「CVE チェック」「ランタイム EOL チェック」「Node の脆弱性大丈夫?」で発動。clone 瞬間の `oss-clone-security` / 単一リポ総合監査の `cso` とは責務が別（継続・全リポ・ランタイム+EOL）。
scope: local-only
updated_at: 2026-06-25
---

# vuln-scan

全リポの **依存 CVE / ランタイム CVE / EOL ランタイム** を定期診断し、所有(team/personal)と到達性で対応要否をトリアージする。

> **なぜ必要か**: `npm/pnpm audit`・Dependabot・Renovate は **npm パッケージしか見ない**。Node/Python/Go の**ランタイム本体 CVE**（例: Node TLS/HTTP2 系）や **EOL ランタイム**は検知できない。これらはコンテナ/ベースイメージスキャナ＋EOL 照合でしか拾えない。本 skill がその空きレーンを埋める。

## Step 一覧 (5 段)

| Step | 内容 | 完了条件 |
|---|---|---|
| 0 | Preflight（trivy/jq 存在・network・scope 決定） | 前提 OK、scope 確定 |
| 1 | Scan（`vuln-scan.sh` 実行＝決定論） | `scan-YYYY-MM-DD.json` 生成 |
| 2 | Triage（重大度 × 到達性 × 所有 で 対応要/監視/無視） | 全 finding に判定が付く |
| 3 | Report（`report-YYYY-MM-DD.md` 生成・personal/team で分割） | レポート出力完了 |
| 4 | 次回 due 記録（任意） | last_run 更新 or skip 明記 |

## Constants

| 名前 | 値 |
|---|---|
| 決定論スクリプト | `<skill-root>/scripts/vuln-scan.sh` |
| 必須ツール | `trivy`（`brew install trivy`）, `jq`, `curl` |
| 出力ディレクトリ | `${VULN_SCAN_OUT:-${REPOS_BASE:-$HOME/Developer}/.vuln-scan}` |
| 機械可読出力 | `scan-YYYY-MM-DD.json`（スクリプト生成） |
| 人間向けレポート | `report-YYYY-MM-DD.md`（Step 3 で生成） |
| EOL 照合元 | endoflife.date API（`/api/<product>.json`・`/tmp` キャッシュ） |
| 既定 scope | `--auto`（`${REPOS_BASE:-$HOME/Developer}` 配下の git repo を maxdepth 3 で自動検出） |
| 既定 severity | `HIGH,CRITICAL`（`--severity` で変更可） |
| **所有→対応ルート** | **team** repo → **ハンドオフ資料**（直接 push しない） / **personal** repo → 自分で feature ブランチ+PR |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `oss-clone-security` | `cso` | Dependabot/Renovate |
|---|---|---|---|---|
| **定期・全リポ・ランタイムCVE+EOL のトリアージ** | ✅ | ❌ | ❌ | ❌ |
| clone/pull 瞬間の supply-chain 防衛（gitleaks+trivy+IOC） | ❌ | ✅ | ❌ | ❌ |
| 単一リポの守備総合監査（OWASP/STRIDE/設計） | ❌ | ❌ | ✅ | ❌ |
| npm 依存の自動更新 PR（パッケージのみ・ランタイム不可） | ❌ | ❌ | ❌ | ✅ |

## When to Use

**発動トリガ**:
- ユーザーが「脆弱性診断」「vuln scan」「CVE チェック」「ランタイム EOL 確認」「Node/依存の脆弱性大丈夫?」と発言
- ベンダー（Node.js/Python/Go 等）のセキュリティリリース告知を受けて影響を確認したいとき
- 定期（週次など）の due が来たとき

**スキップ条件**:
- 直近（同日）に `scan-YYYY-MM-DD.json` がある & 新規 CVE 告知も無い → 再 scan せず既存レポートを参照
- 単一の新規 clone の安全確認だけが目的 → `oss-clone-security`（本 skill ではない）

---

## Implementation Steps

### Step 0: Preflight

**目的**: 前提不足での誤った「異常なし」を防ぐ
**条件 / アクション**:
```bash
command -v trivy >/dev/null || { echo "trivy 不在 → brew install trivy"; exit 1; }
command -v jq >/dev/null || { echo "jq 不在 → brew install jq"; exit 1; }
# scope: 既定は --auto。特定リポのみなら パスを列挙。
```
- network 必須（endoflife API 照合 + ベースイメージ層の pull）。オフライン時は `--skip-image` で依存+EOL のみに縮退し、**レポートにランタイム CVE 未検査である旨を明記**（観測してないものを PASS にしない）。

**完了条件**: trivy/jq あり、scope 決定

### Step 1: Scan（決定論）

**目的**: 判断を挟まず機械的に全 finding を収集
**アクション**:
```bash
# 全リポ（既定）
bash <skill-root>/scripts/vuln-scan.sh --auto

# 特定リポのみ（パスを列挙）
bash <skill-root>/scripts/vuln-scan.sh ${REPOS_BASE:-$HOME/Developer}/<owner>/<repo>
```
スクリプトがリポごとに: ①ランタイム抽出（Dockerfile FROM / .tool-versions / .nvmrc / engines / CI node-version）②endoflife で EOL 判定 ③一意ベースイメージを `trivy image` ④`trivy fs` で依存 CVE → `scan-YYYY-MM-DD.json`。

**完了条件**: `scan-YYYY-MM-DD.json` が生成され `jq '.repos|length'` > 0

### Step 2: Triage

**目的**: 件数の羅列でなく「何を今やるか」に変換
**判定ロジック**（各 finding を分類）:

| 軸 | 観点 |
|---|---|
| 重大度 | trivy severity（HIGH/CRITICAL 既定） / EOL は単独で `対応要` 級 |
| 到達性 | デプロイ済みネット公開サービス? / TLS は直終端か上流(CDN/LB)終端か / ライブラリ・未デプロイ fork か |
| 所有 | team（ハンドオフ） / personal（自分で修正） |

→ ラベル:
- **対応要**: EOL ランタイムで稼働 / 到達可能な経路の HIGH-CRIT / 既知 exploit
- **監視**: デプロイ形態が不明 or 上流終端で直接到達しにくい / floating tag で再ビルドにより自然解消する見込み
- **無視**: 未デプロイの参照 fork / 到達経路の無い devDependency

> **正直さ**: デプロイ形態・TLS 終端位置が不明な finding を「届かないから無視」に倒さない（`監視`に置く）。`--skip-image` で走らせたら「ランタイム CVE 未検査」を必ず明記（BLOCKED≠PASS）。

**完了条件**: 全 finding に 対応要/監視/無視 が付く

### Step 3: Report

**目的**: 受け手（自分 / 各チーム）がそれだけで動ける資料
**アクション**: `${VULN_SCAN_OUT:-<出力ディレクトリ>}/report-YYYY-MM-DD.md` を生成。構成:
1. **対応要サマリ**（先頭・最重要のみ）
2. **personal（自分で修正）** — リポ別・対象ファイル・変更内容・理由
3. **team（ハンドオフ）** — チームごとに、転送できる粒度で対象ファイル・変更・理由
4. リポ別 全 finding 明細（監視/無視 含む）

**完了条件**: レポート生成、対応要が personal/team で分割されている

### Step 4: 次回 due 記録（任意）

**目的**: 次回 due 計算の基点を更新
**アクション**: 使用しているタスク管理（`recurring-tasks.json` / カレンダー等）の `last_run` を today に更新。不要なら skip を明記。

**完了条件**: 更新 or skip 明記

---

## Constraints

### 致命的 (Errors)
| Pattern | Preferred | Reason |
|---|---|---|
| `npm audit`/Dependabot 緑だけで「ランタイムも安全」と結論 | `trivy image`(ベースイメージ) と EOL 照合を必ず通す | ランタイム本体 CVE / EOL は依存スキャナで**原理的に見えない**（本 skill の存在理由）[E1] |
| team リポに本 skill が直接 push/PR | ハンドオフ資料を作り team へ連携 | 所有越境。team の review/CI フローを通さない変更は事故源 |
| `--skip-image` の結果を「ランタイム異常なし」と報告 | 「ランタイム CVE 未検査」と明記 | 観測してないものを PASS に倒す false-PASS（BLOCKED≠PASS と同根） |
| EOL ランタイムを severity 0 だからと `無視` | EOL は単独で `対応要` 級 | EOL=今後パッチが出ない＝CVE が累積する standing risk [E2] |

### 注意 (Warnings)
| Pattern | Preferred | Reason |
|---|---|---|
| デプロイ形態不明の finding を「届かない」と断定 | `監視` に置く | 過小評価。TLS 終端位置が未確認なら判断保留 |
| floating tag(`node:22-alpine`)を「常に脆弱」扱い | 「再ビルド+再デプロイで ≥patched に追従」と注記 | 過大評価。floating は rebuild で自然解消 |
| 全リポ毎回 image pull で重いと敬遠 | 一意イメージは dedupe 済・層はキャッシュ。重ければ `--skip-image` を週次/隔週で使い分け | 運用継続性 |

## Related Skills

| Skill | 関係 |
|---|---|
| `oss-clone-security` | clone/pull **瞬間**の防衛。本 skill は**継続**診断（直列・上流） |
| `cso` | 単一リポの守備総合監査。本 skill は横断・ランタイム+EOL に特化 |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | Node.js セキュリティリリース調査（本 skill 新設の契機） | CVE の多くが Node ランタイム本体（TLS/HTTP2/WebCrypto 等）。npm audit/Dependabot では検知不能 → `trivy image` でベースイメージを直接スキャンする設計に到達 |
| E2 | endoflife.date 照合の実運用 | Node 18/20 等の EOL 済みランタイムは今後パッチが出ない。EOL は severity と別軸で `対応要` |
| E3 | `--auto` 初回 run | Go 等 Node 以外のランタイムも検出できる汎用性を確認。floating `node:22-alpine` は rebuild 追従で大幅縮小 |
