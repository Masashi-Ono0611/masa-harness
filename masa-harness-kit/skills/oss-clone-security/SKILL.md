---
name: oss-clone-security
description: |-
  外部 GitHub / 公開リポジトリを clone / fork / pull した瞬間の supply-chain 防衛フロー。gitleaks → trivy → ripgrep IOC スキャン → manual review → isolated execution の順を**強制**し、スキャン前の `npm install` / `pip install` / `docker build` / `make` / `bash *.sh` 等を一切禁止する。**信用度が極めて高い repo (適用除外リスト) 以外は毎回必ず発動**。新規 clone / fork / 未知 OSS の試用 / untrusted コード実行前のいずれかが発生したら呼ぶ。`cso` skill との違い: cso は守備の総合監査、本 skill は新規取り込み瞬間の防衛フロー。
scope: local-only
updated_at: 2026-05-18
---

# OSS Clone Security

外部 GitHub (社内・公開問わず) から clone したリポジトリに対する supply-chain 防衛手順。malware 実行・秘密情報漏洩・不正コード挙動を防ぐ。

## Step 一覧 (7 段)

| Step | 内容 | 完了条件 |
|---|---|---|
| 1 | Clone Policy (build/install/実行を一切禁止) | `git clone` のみ実行、他は Step 2 まで停止 |
| 2 | Immediate Security Scans (gitleaks → trivy → rg IOC) | High/Critical 0 件 |
| 3 | Manual Code Review (package.json/Dockerfile/.github/install.sh 等) | suspicious なし |
| 4 | Block Auto-Scripts (`--ignore-scripts` / venv / `--network=none`) | 安全モードで install |
| 5 | Isolated Execution (Docker `--network=none --read-only` or VM) | ホスト直接実行回避 |
| 6 | Final Adoption Decision (全条件満たす場合のみ採用) | 採用 or 中断 |
| 7 | Secrets Policy (未検証コードに `.env`/認証情報を置かない) | secrets 隔離 |

## Constants

| 名前 | 値 |
|---|---|
| 必須スキャンツール | `gitleaks`, `trivy`, `rg` (ripgrep) |
| IOC grep パターン | `curl ` / `wget ` / `eval` / `bash -c` / `base64` / `rm -rf` / `sudo ` |
| 適用除外 repo (自分が author / 業務組織管理 / 公式 SDK README 通り) | `<your-org>/*` (自社管理 repo), `anthropic-ai/anthropic-sdk-*`, `vercel/next.js` 等の公式 OSS |
| 関連 skill | `cso` (継続監査), `claude-stack-audit` Step 4b (外部配布物の信頼性スコア) |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `cso` | `claude-stack-audit` Step 4b |
|---|---|---|---|
| **新規 clone 瞬間** の supply-chain 防衛 | ✅ | ❌ | ❌ |
| 既存リポの守備総合監査 (OWASP / STRIDE / 依存脆弱性 trend) | ❌ | ✅ | ❌ |
| 配布物の信頼性スコア (star / contributor / license / hooks 権限) | ❌ | (詳細は cso へ) | ✅ |

## When to Use

**強制発動トリガ** (適用除外以外は必須):
- ユーザーが「clone してきた」「github から落としてきた」「外部リポを試したい」「fork した」「OSS を試したい」と発言
- 新規 `git clone` 直後、または `git pull` で **untrusted な変更**が入る直前
- `npm install` / `pip install` / `docker build` / `make` / `bash *.sh` 実行前で対象が適用除外でない
- 不明な依存 (`requirements.txt` / `package.json` / `go.mod` / `Cargo.toml`) の untrusted な追加検知

**スキップ条件 (適用除外)**:
- 自分が author / maintainer の personal repo
- 業務組織管理リポ (`<your-org>/*` 配下で過去利用実績あり)
- 公式 SDK / 大手 OSS で公式 README 通りインストール
- **判断に迷ったら適用する** ("よく知る repo に見える" は除外条件にならない、typo-squat / namespace 詐称対策)

---

## Implementation Steps

### Step 1: Clone Policy

**目的**: build / install / 実行を全て止めて scan を先行
**禁止コマンド** (Step 2 まで):
- `npm install` / `yarn install` / `pnpm install`
- `pip install`
- `go build` / `cargo build`
- `docker build` / `docker compose up`
- `make` / `bash install.sh` / 任意のシェルスクリプト

**アクション**:
```bash
git clone <url>   # --recurse-submodules は NG、サブモジュールは review 後
cd <repo>
```
**完了条件**: clone のみ完了、他のコマンドは未実行

---

### Step 2: Immediate Security Scans

**目的**: 秘密情報・脆弱性・IOC を機械検出
**アクション** (順番厳守):
```bash
# 1. Gitleaks — 秘密情報・キー・認証情報
gitleaks detect --source .

# 2. Trivy (repo scan) — 脆弱性・漏洩 secret・misconfig
trivy repo .

# 3. ripgrep IOC quick scan
rg -n -e "curl " -e "wget " -e "eval" -e "bash -c" -e "base64" -e "rm -rf" -e "sudo "
```
**完了条件**: High / Critical 検出 0 件 (1 件でも検出 → 即停止 + ユーザーにエスカレーション)

---

### Step 3: Manual Code Review

**目的**: 自動 scan で拾えない suspicious コードを人間目視
**必須レビュー対象**:
- `package.json` — `postinstall` hook、怪しい npm scripts
- `requirements.txt` / `Pipfile` — 不明・untrusted 依存
- `Dockerfile` / `docker-compose.yml` — 自動 download / `curl`/`wget`/remote script
- `.github/workflows/` — supply chain action
- `.devcontainer/` / `.vscode/` — 自動実行設定
- `install.sh`, `Makefile`, `*.sh` — 破壊的コマンド・隠しコマンド

**完了条件**: suspicious 行動 0 件

---

### Step 4: Block Auto-Scripts and Unsafe Installs

**目的**: install scripts の自動実行を block
**アクション**:
```bash
# Node
npm install --ignore-scripts

# Python (必ず venv)
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt   # スキャン後のみ

# Docker (network 隔離可能なら)
docker build --network=none .
```
**完了条件**: install 成功 + 不審動作なし

---

### Step 5: Isolated Execution

**目的**: untrusted コード実行を隔離環境のみに限定
**許可**:
- ✅ Docker `--network=none --read-only`
- ✅ snapshot 復元可能な VM

**禁止**:
- ❌ ホストマシン直接実行
- ❌ 実環境変数 / `~/.ssh` / クラウド認証情報を渡す

**完了条件**: 隔離環境で動作確認済

---

### Step 6: Final Adoption Decision

**目的**: 全条件を満たした場合のみ正式採用
**採用条件**:
- スキャンで Critical / High 検出 0
- manual review で suspicious 0
- 依存が trusted かつ active maintenance

**完了条件**: 採用 or 「疑問が残るなら escalate して中断」

---

### Step 7: Secrets Policy

**目的**: 検証完了前の repo に secrets を渡さない
**ルール**:
- 未検証コードに `.env` / secrets / 認証情報を置かない
- prior review なしで外部ネットワーク呼び出しするコードは実行禁止

**完了条件**: secrets は採用後に別途投入

---

## Constraints

| Pattern | Preferred | Reason |
|---|---|---|
| Step 2 (scan) 前に `npm install` 等を実行 | clone → 全 scan → review → install の順厳守 | postinstall hook で malware 実行リスク |
| `--recurse-submodules` で初回 clone | サブモジュールは review 後に取得 | 親 repo の sub が悪意ある可能性 |
| 適用除外リスト外で本 skill を skip | 判断に迷ったら適用、"よく知る repo" は除外条件にならない | typo-squat / namespace 詐称対策 |
| Scan High/Critical 検出 1 件でもあるのに進める | 即停止 + ユーザーにエスカレーション | 1 件残しでサプライチェーン汚染リスク |
| untrusted コードをホスト直接実行 | Docker `--network=none --read-only` or VM | ホスト環境への 2 次感染防止 |
| `.env` / `~/.ssh` を未検証 repo に渡す | secrets は採用後に隔離環境で投入 | キー漏洩・認証情報盗難 |

## Related Skills

| Skill | 関係 |
|---|---|
| `cso` | **継続監視**。本 skill (取り込み瞬間) → cso (継続) の直列 |
| `claude-stack-audit` Step 4b | 外部配布物 (skills / plugins / MCP) の信頼性スコア (star / license / 権限) で本 skill 発動可否判定 |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | 過去 OSS 取り込み事例 | `usedhonda/claude-skills` 等の配布者 identity 検証必要 (claude-stack-audit Step 4b で関連) |
| E2 | typo-squat 一般 | "よく知る repo に見える" は除外条件にならない、必ず適用 |
