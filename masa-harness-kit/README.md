# masa-harness-kit

個人用 Claude Code ハーネス「masa-harness」を、**全く新規の環境へ移植するための骨格 kit** です。
作者の環境固有情報（社名・プロジェクト名・実パス・鍵・外部接続）は除いてあり、思想と汎用部品だけを抜き出しています。

- **バージョン**: `VERSION` ファイル参照（変更履歴は repo ルートの `CHANGELOG.md`）
- **ライセンス**: 個人利用・改変自由、無保証。受け取った人が自分の環境向けに自由に書き換えて使う前提です。

> このページは tarball を直接受け取った人向けの「中身の説明」です。1行インストール・更新・アンインストールの
> 案内は repo ルートの `README.md` にまとまっています。

## 思想（なぜこの形か）

- **Thin Harness, Fat Skills**: グローバル指示（CLAUDE.md）は「pointer ＋ 必ず効く reflex」だけに保ち、ドメイン手順は on-demand な skill / doc に置く。
- **3 分業**: 知能 → **SKILL** ／ 実行 → **HOOK（deterministic tool）** ／ 記憶 → **MEMORY**。危険操作の執行は「お願い」でなく hook で決定論的に止める。
- **Karpathy 4 原則**: Think Before Coding / Simplicity First / Surgical Changes / Goal-Driven Execution。
- 詳細な設計思想は `docs/design.md`（作者の全体像の読み物。kit 同梱物ではなく作者本番環境の数値・外部接続例を含む）。

## 前提（必要なツール）

| ツール | 用途 | 無いとき |
|---|---|---|
| `bash` / `python3` | hook（governance-gate.py / `*.sh`） | **必須**。無いと hook が動かない |
| `jq` | audit-reminder.sh の定期タスク通知 | 通知を静かに skip（致命的でない） |
| `git` / `gh` | 一部 skill（stack-news の release 取得・各 skill の git 操作） | 該当 skill が空振り |
| `ripgrep`(rg) / `gitleaks` / `trivy` | `oss-clone-security` のスキャン | その skill 使用時のみ要 |
| `codex`（任意） | `claude-skill-audit` の Codex レビュー Step | その Step を skip |

**OS**: macOS を主に想定。`date` は BSD/GNU 両対応済なので Linux でも動く。formatter 系（ruff/prettier 等）は各言語を使うときに各自導入。

## 同梱物

```
masa-harness-kit/
├── README.md                      # このファイル
├── VERSION                        # キットのバージョン（SemVer）
├── setup.sh                       # 配置スクリプト（fresh / safe / overwrite の3モード）
├── CLAUDE.md.template             # グローバル運用ルールの骨格（{{...}} を記入）
├── settings.json.template         # permissions / hooks 配線（$HOME 相対）
├── hooks/
│   ├── governance-gate.py         # PreToolUse ガバナンス gate（BLOCK/LOG/ALLOW）
│   ├── audit-reminder.sh          # SessionStart: 定期タスクの due 通知（BSD/GNU date 両対応）
│   ├── post-edit-format.sh        # PostToolUse: 拡張子ごとに整形（ruff/prettier/gofmt 等・無ければ no-op）
│   └── tool-leak-guard.py         # Stop: 漏れた tool-call markup を検出し1回だけ出し直させる（Opus 4.8 既知バグ対策）
├── rules/
│   ├── typescript.md              # 言語別（python/solidity 等は各自追加）
│   ├── skill-template.md          # skill の書き方テンプレ
│   ├── config-hygiene.md          # 環境保守の owner マップ
│   └── agent-model-routing.md     # subagent のモデル選択 + 外部 review ルーティング指針
├── skills/                        # harness 改善系の汎用 skill（9 個）
│   ├── ask-after-grep/ lesson-harvest/ oss-clone-security/ dev-machine-optimize/
│   ├── claude-config-audit/ claude-skill-audit/ claude-stack-audit/ claude-stack-news/
│   └── masa-harness-audit/        # kit の良い差分だけ選んで取り込む（選択的アップグレード）
├── commands/
│   └── review/self-multi-model.md # 外部モデル（Codex/Antigravity）+ Claude のセルフ PR レビュー
├── state/
│   └── recurring-tasks.json.template   # 定期タスク・レジストリ（自己改善ループ3件入り）
└── docs/
    ├── design.md                  # 設計思想の詳細（作者の全体像・読み物）
    └── multi-model-review.md      # 外部 review CLI（Codex/Antigravity）の導入・認証手順
```

## セットアップ

`setup.sh` は既存環境を壊さないよう **3モード**で動きます（モードは自動判定）:

```bash
bash setup.sh
```

| あなたの状況 | モード | 挙動 |
|---|---|---|
| `~/.claude` に設定がまだ無い | `fresh` | そのまま全展開（失うものが無い） |
| 既に設定がある（初回遭遇） | `safe` | **何も上書きせず**、差分レポート（`~/.claude/.masa-harness/AUDIT-REPORT.md`）を出して停止 |
| 全部このキットにしたい | `overwrite` | `MASA_MODE=overwrite bash setup.sh`。既存は `*.bak-<日時>` に退避してから配置 |

良いところ**だけ**取り込みたいときは、上書きせず Claude Code で `/masa-harness-audit`（または「masa-harness を audit して良い差分だけ取り込んで」）。
あなたの設定を主役にしたまま、差分を推奨理由付きで提示し、承認分だけ反映します。

手動で配置したい場合は、各 `*.template` から `.template` を外して `~/.claude/` 配下にコピーし、`hooks/*` に実行権限（`chmod +x`）を付けるだけです。

> **`$HOME` について**: `settings.json` の hooks command は `$HOME/.claude/hooks/...` です。Claude Code は hook を shell 経由で実行するため `$HOME` は展開されますが、万一展開されない環境では絶対パスに置換してください。

## skill の起動

- skill は **`/<skill ディレクトリ名>`** で起動します（例: `/lesson-harvest`、`/claude-config-audit`）。`/skills:name` のような prefix は不要です。
- `disable-model-invocation: true` の skill も手動 `/<name>` 起動は有効です（Claude の自動起動だけを無効化する設定）。

## 配置後にやること（プレースホルダ記入）

1. `~/.claude/CLAUDE.md` の `{{...}}` を自分の環境に置き換える:
   - `{{ORG_OR_PROJECT_*}}` … 自分の org / プロジェクト
   - `{{応答言語}}` … 例: 日本語
   - `{{your-org}}` … oss-clone-security の適用除外に使う自組織名
2. 使わない言語の `@~/.claude/rules/*.md` import 行を CLAUDE.md から削除（python/solidity 等の rule は同梱していないので、使うなら各自追加）。
3. skill 内に残るプレースホルダを、使うときに自分の値へ:
   - `<org>/<repo>`（claude-skill-audit の管理対象 repo）/ `<your-org>/*`（oss-clone-security の除外）/ `<project-board-id>`（skill-template の例）
4. repo 群を `~/Developer` 以外に置くなら: `export REPOS_BASE=~/code` のように指定（claude-skill-audit / claude-stack-audit / dev-machine-optimize が参照。未設定なら `~/Developer`）。
5. 保護 branch / 本番 workflow を変えるなら: `export GATE_PROTECTED_BRANCHES='main|master|develop'` / `export GATE_PROD_WORKFLOWS='...'`。

## 初回セッションについて

`recurring-tasks.json` の `last_run` が `2026-01-01` なので、配置後の初回セッションで登録3タスク（lesson-harvest 週次 / config-audit 週次 / skill-audit 隔週）が**すべて「due/overdue」通知**として出ます（配置直後に学習サイクルを促す意図）。各タスクを回したら `last_run` を当日に更新すれば静かになります。不要なら `enabled` を `false` に。

## 含むもの / 含まないもの

| 含む | 含まない（各自で） |
|---|---|
| 設計思想・Karpathy 4 原則・CLAUDE.md 骨格 | 作者の org / プロジェクト構成・社名・メール |
| hook 4 個（governance-gate / audit-reminder / format / tool-leak-guard） | 音声 UI（VOICEVOX 等の通知 hook） |
| 汎用 rule 4 個（typescript・skill-template・config-hygiene・agent-model-routing） | 外部接続（second brain / メッシュ VPN / 各種 MCP の実接続・トークン） |
| harness 改善系の汎用 skill 9 個 | 個人ドメイン skill・過去の作業データ・auto-memory の中身 |
| 外部モデル review command 1 個（self-multi-model）＋導入 doc | Codex / Antigravity のアカウント・認証（任意・各自で） |
| 定期タスクの仕組み＋自己改善ループ3件 | 作者の定期タスク本体 |

> skill のうち `lesson-harvest` / `claude-stack-*` / `ask-after-grep` は semantic 検索ツール（あれば）を併用する設計です。無くても主経路（grep / Explore agent）で成立します。
>
> `docs/design.md` に出てくる「69 skills」等の数値は**作者本番環境の例**で、この kit の同梱物（rules 4 / skills 9 / hooks 4 / commands 1）とは別物です。

## 学習サイクルが回る仕組み

記憶を毎晩自動で蓄積・連想する外部の仕組み（second brain など）は **含めていません**。その代わり、週次の明示的な振り返りで自己改善の輪を閉じます:

1. 日々の作業で会話履歴（`~/.claude/projects/*/`）が残る
2. 週次 `lesson-harvest` がそれを Explore agent で振り返り、2 回以上の指摘・訂正を抽出
3. 承認した分だけ CLAUDE.md / rules / memory へ昇格（L1 / L2）
4. `claude-config-audit` が増えすぎ・古い記述を剪定（足す係＝lesson-harvest / 削る係＝config-audit を分離）

`recurring-tasks.json` に lesson-harvest（週次）/ config-audit（週次）/ skill-audit（隔週）が最初から入っているので、配置後はセッション開始時に「そろそろ振り返り」と通知が出ます。後から semantic 検索 MCP を足せば `lesson-harvest` / `ask-after-grep` が自動で併用します（無くても回ります）。

## ガバナンス gate が止めるもの（配置前に把握）

`governance-gate.py` は PreToolUse で次を **BLOCK**（exit 2）します。配置前に「何が止まるか」を把握してください:

| カテゴリ | 例 |
|---|---|
| 破壊 | `rm -rf` の危険 target（再生成不可なパス。node_modules / dist 等 ephemeral は許可） |
| グローバル導入 | `npm i -g` / `pipx` / `gem install` / `cargo install` / `go install`（postinstall が走る枠） |
| Claude 動作環境の改変 | settings.json への shell 書き込み（`>` / `tee` / `sed -i`。CLAUDE.md / recurring-tasks.json は摩擦軽減のため対象外） |
| secrets | `.env` 等への書き込み |
| 権限境界 | branch protection / IAM / release 作成 / publish / 保護 branch への force-push |

- **LOG**（exit 0 + 記録）: 可逆だが team 可視な mutation を ops ログに残して通す。
- **ALLOW**（exit 0）: それ以外は素通し（日常操作の摩擦ゼロ）。
- 保護対象は env `GATE_PROTECTED_BRANCHES` / `GATE_PROD_WORKFLOWS` で各自設定。誤検知時は本人の手動実行で回避（hook を一時 off）。
- **gate の限界（正直な但し書き）**: shell 経由の書き込みブロックは best-effort です。`>` / `tee` / `sed -i` は捕捉しますが、`cp` / `mv` / `python -c "open(...)"` 等の任意 write は通ります。settings.json / 実 `.env` の最終防波堤は Edit/Write tool 側の保護パスです。

## 安全に関する注意

- **`settings.json` の `permissions.deny`（`.env` / `credentials` / `*.pem` / `id_rsa` の読み取りブロック）は外さない**。ただし deny が止めるのは **Read tool** の読み取りだけで、Bash 経由の `cat .env` / `curl -F @.env` は止めません（gate も書き込みのみ対象で読み取りは見ない）。secrets の扱いは別途注意してください。
- 危険なスキップ系フラグ（`skipDangerousModePermissionPrompt` 等）は**意図的に同梱していません**。必要なら理解した上で各自追加してください（既定は付けない方が安全）。
- このハーネスは「お願いベースのルール」ではなく **hook による執行**を核にしています。`hooks/` を消すとガバナンスが効かなくなる点に留意してください。

## アンインストール

- **元に戻す**: 上書きを伴う配置（`overwrite`）は既存を `~/.claude/<file>.bak-<日時>` に退避しています。退避ファイルを戻せば原状復帰します（例: `mv ~/.claude/CLAUDE.md.bak-20260619-120000 ~/.claude/CLAUDE.md`）。
- **kit 由来物だけ消す**: このキットが設置したファイルは `~/.claude/.masa-harness/manifest.txt` に一覧があります。それを見て該当ファイル（hooks 4 / rules 4 / skills 9 / commands 1 / `state/recurring-tasks.json`）を削除し、`settings.json` の hooks セクションを外してください（または各 `.bak` から復元）。

## 変更履歴

変更履歴は repo ルートの `CHANGELOG.md`（および [GitHub Releases](https://github.com/Masashi-Ono0611/masa-harness/releases)）に一本化しました。現在のバージョンは同梱の `VERSION` を参照してください。
