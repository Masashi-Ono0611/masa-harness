# 変更履歴

このファイルは人間が読む用のリリースノートです。各タグの詳細な差分は
[GitHub Releases](https://github.com/OWNER/masa-harness/releases) を参照してください。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョンは [セマンティックバージョニング](https://semver.org/lang/ja/)（vMAJOR.MINOR.PATCH）に従います。

## [Unreleased]

## [1.2.0] - 2026-06-20

tar.gz 手渡し配布から、**GitHub Release + 1行インストール**へ移行したリリース。

### 追加
- **1行インストール** `install.sh`（`curl | bash`）。初回も更新も同じコマンド。
- **3モードの安全な setup.sh**:
  - `fresh` … 既存設定が無ければそのまま全展開
  - `safe`（既定）… 既存設定があれば**何も上書きせず**差分レポートを出すだけ
  - `overwrite` … `MASA_MODE=overwrite` で明示したときだけ、タイムスタンプ backup を取って上書き
- **`masa-harness-audit` skill** … 「全部上書き」ではなく、キットの良い差分だけを推奨理由付きで選んで反映する選択的アップグレード経路（skill は計 9 個に）。
- **バージョン追跡** … `VERSION` ファイル + `~/.claude/.masa-harness/`（manifest / version）。
- **削除追従** … キットから消えた skill / rule / hook は、利用者環境からも quarantine 退避される。
- **リリース自動化** … `.github/workflows/release.yml`（タグ push で Release 自動発行・ノート自動生成・tarball 添付）。

### 変更
- 上書き前の backup を**タイムスタンプ付き**（`*.bak-<日時>`）にし、再実行で原本が消えないように。
- 設定ファイル（CLAUDE.md / settings.json）は overwrite を明示しない限り**自動上書きしない**よう保護。
- kit README が独自に持っていたバージョン表記・変更履歴を、本 CHANGELOG と `VERSION` に一本化。

### セキュリティ
- 配布物の sanitize ガード（`.maint/kit-sync.sh`）を、ブランド名の誤検知を除き、実際の秘密形（個人パス・メール）に限定。
  公開したくない追加パターンは公開リポに出さず、ローカル専用ファイルに分離。

## [1.1.0] - 2026-06-19

### 追加
- `governance-gate.py` に BLOCK ルール2本 — `iac-destroy`（`terraform`/`tofu`/`pulumi`/`cdk` の destroy）、`destructive-git`（`git reset --hard` / `git clean -f` / `git stash drop|clear`）。新しめの Claude Code は auto mode で native ブロックするが version 依存のため、hook で version 非依存の belt にした（AI の無断実行のみ止め、本人は `!` で手動実行可）。
- `settings.json` の `permissions.ask` に `Agent(model:opus)` を追加（opus subagent の spawn を都度確認に。`agent-model-routing.md` を permission 層で執行）。

## [1.0.0] - 2026-06-19

初版。masashi 本体 harness を汎用化したスナップショット（CLAUDE.md 骨格 / rules 4 / skills 8 / hooks 3 / settings / 定期タスク）。
