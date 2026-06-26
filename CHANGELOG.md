# 変更履歴

このファイルは人間が読む用のリリースノートです。各タグの詳細な差分は
[GitHub Releases](https://github.com/Masashi-Ono0611/masa-harness/releases) を参照してください。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョンは [セマンティックバージョニング](https://semver.org/lang/ja/)（vMAJOR.MINOR.PATCH）に従います。

## [Unreleased]

## [1.6.0] - 2026-06-26

保護ブランチ上の作業を worktree に物理分離する「worktree-first」を L1 強制 hook ＋ 汎用フロー skill のペアで同梱し、あわせて継続セキュリティ診断 skill と汎用ワークフロー command 群を kit に加えたリリース。skill は「呼ばれないと発火しない」ため、デフォルト化の強制は hook、フローの中身は skill が担う分担。

### 追加
- **`hooks/worktree-trigger.py`** … 保護ブランチ（main/master/staging/trunk 等＋ `origin/HEAD` 由来の検出 default）上で Edit/Write に着手すると、1回/repo/session だけブロックして worktree 作成を提案する PreToolUse hook。独立作業なら `git worktree add` を促し、継続作業・設定の軽微編集なら retry でスルーする。linked worktree 内・feature ブランチ・detached HEAD は素通し。同梱 hook は 4 → 5 個に。
- **`skills/worktree-pr-flow/SKILL.md`** … 保護ブランチ着手時の「worktree 作成 → 実装 → 検証 → マルチモデルレビュー → PR → cleanup」を 6 段で回す repo 非依存の汎用フロー骨格。repo 固有事情が溜まったら `<repo>-pr-flow` を新設して卒業する設計。worktree-trigger hook とペアで機能する。
- **`skills/vuln-scan/`** … 全リポを定期診断し「依存（npm）CVE」+「ランタイム/コンテナ CVE」+「EOL ランタイム」を一括検出して『対応要 / 監視 / 無視』にトリアージする継続セキュリティ診断 skill。Trivy 1 本（＋ endoflife.date）で、Dependabot/npm audit が見られないランタイム本体の CVE（Node/Python/Go コア）まで捕捉する。clone 瞬間の `oss-clone-security` とは責務が別（継続・全リポ・ランタイム+EOL）。
- **汎用ワークフロー command 4 個**（`commands/` を review 1 個から 5 個に拡張）… `gh/commit-push-pr.md`（commit → push → PR を一括）/ `gh/fix-review.md`（現在ブランチの PR レビュー指摘を収集・修正）/ `review/pr-review.md`（指定 PR のコードレビュー）/ `debug/investigate.md`（エラー/バグの原因を構造化して調査）。`setup.sh` は `commands/**` を glob 配置するため自動で入る。

### 変更
- **`CLAUDE.md.template` の「並列開発」節を worktree-first reflex に更新** … 「同一リポで2件以上の並行作業」から「保護ブランチ上で着手したら1件でも worktree で物理分離」へ既定を引き上げ。強制 hook（L1）とフロー skill の分担、`.env` 等 gitignore 対象を worktree が引き継がない点（メイン checkout 参照）を明記。
- **`settings.json.template` に worktree-trigger を配線** … `Edit|Write|MultiEdit` matcher に governance-gate と並べて PreToolUse 登録。kit 利用者の環境でも実際に発火するようにした。
- **`hooks/tool-leak-guard.py` を本体最新と同期** … tool-call markup リーク検出の判定・誤検知抑制を改善。
- **rules / pointer の整合取り直し** … `rules/agent-model-routing.md` 等のマルチモデル review 記述を本体最新に同期。dangling だった参照を解消し、web デバッグ系の pointer を gstack 推奨に汎用化。

## [1.5.0] - 2026-06-21

外部モデルによるセルフ PR レビュー（multi-model review）を kit に同梱し、`commands/` を新カテゴリとして配布できるようにしたリリース。

### 追加
- **`commands/review/self-multi-model.md`** … PR 作成前にコードを第二モデル（Codex を primary、Antigravity CLI `agy` を fallback）と Claude の最低 2 つでレビューし、指摘を統合する `/review:self-multi-model` command。fallback 連鎖（Codex→Antigravity→Gemini bot→Claude）、大型 diff 向けの chunked `codex exec`、モデル名 SoT の一元管理を含む。外部CLIは任意で、無ければ Claude 単独で動く。
- **`docs/multi-model-review.md`** … Codex CLI（`codex login`）と Antigravity CLI（`agy` の導入・Google Sign-In）の導入・認証・トラブルシュート手順。外部CLIが任意であること、fallback 連鎖、モデル名 SoT の更新方針を明記。
- **`rules/agent-model-routing.md` に「外部モデル review のルーティング」節を追加** … review モデルを session 既定から decouple して明示固定する／tier より先に effort を疑う／別ベンダー CLI は Claude Code の更新で自動追従しないので腐る軸（モデル名）を1箇所に集約する、という判断軸（恒久）。腐る具体（モデル名・フラグ）は command の SoT ブロックに置く pointer 構成。

### 変更
- **`setup.sh` が `commands/` カテゴリを配布対象に追加** … これまで `rules` / `hooks` / `skills` のみだった kit-owned ツリーに `commands` を加え、`~/.claude/commands/` へ配置・更新・削除追従するようにした。
- **`CLAUDE.md.template`** … 「Agent モデルルート」節を「Agent モデルルート / マルチモデル review」に拡張し、`/review:self-multi-model` と setup doc への pointer を1行追加。

## [1.4.0] - 2026-06-21

配布 config の secret 読み取り防御を広げ、governance-gate の射程（sandbox ではない）を明文化したリリース。

### セキュリティ
- **`settings.json.template` の `deny` を拡張** … 既存の `.env*` / `secrets/**` / `credentials*` / `*.pem` / `id_rsa*` に加え、`*.key` / `*.p12` / `*.pfx` / `*.keystore` / `*.jks` / `.npmrc` / `.pgpass` / `kubeconfig` / `*.kubeconfig` / `.aws/**` / `.ssh/**` / `.netrc` / `service-account*.json` を Read 拒否に追加。クラウド認証情報・SSH 秘密鍵・パッケージレジストリトークン等の誤読を Read ツール経路で塞ぐ。
- **CLAUDE.md skeleton に「gate は sandbox ではない」注記を追加** … `governance-gate.py` は durable-state mutation の暴発防止であって sandbox ではない（Bash の write-primitive `cp`/`mv`/`tee`/`python -c open(w)` や機微ファイルの read `cat`/`grep` は素通しする）ことを明記。秘密の最終防御は「機微を Bash 経由で読み書きしない／settings.json・実 .env は Edit 経由で触る（hook が止める）」という運用規律であり、gate を sandbox 代わりにしない、と期待値を揃える。

## [1.3.0] - 2026-06-20

Opus 4.8 の「ツール呼び出しが素テキストとして漏れる」既知バグへの保護を一式追加したリリース。

### 追加
- **Stop hook `tool-leak-guard.py`** … アシスタントの最終メッセージに `<invoke>` / `<parameter>` 等の tool-call markup が**実行されずテキストとして残った**（＝リーク）ことを検出し、その場で1回だけ正しい tool call として出し直させる安全網。`stop_hook_active` で無限ループを防止し、コードフェンス内の引用・解説は誤検知しない。同梱 hook は 3 → 4 個に。
- **CLAUDE.md skeleton に reflex 2 件**:
  - ツール呼び出しを素テキストで吐かない（tool call を返信の先頭に置く・1メッセージ1コール・前置き prose を避ける）。上記 hook と対の振る舞い側の対策。
  - `governance-gate.py` は「コマンド文字列を literal grep」で BLOCK 判定するため、commit message / PR body / 説明文に危険語を書くと無関係な `git` / `gh` まで巻き添えになる。誤検知で止まったら言い換えて即リトライ。

### 変更
- `settings.json.template` の `hooks` に `Stop`（`tool-leak-guard.py`）配線を追加。

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
