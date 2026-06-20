# masa-harness

**Claude Code を「最初から強い状態」で使い始めるための harness 設定キット。**

Claude Code をインストールしただけの状態は「まっさらな新人」です。これは、その新人に
最初から運用ルール・安全装置・定型作業の自動化（skills）を仕込んでおくための設定一式です。
コードを書く人だけでなく、**ドキュメント作成・調査・日々の作業に Claude Code を使うすべての人**向け。

> 中身の詳しい説明は [`masa-harness-kit/README.md`](masa-harness-kit/README.md) を参照。

---

## インストール（初回も更新も同じ1行）

ターミナルに貼り付けるだけ:

```bash
curl -fsSL https://raw.githubusercontent.com/Masashi-Ono0611/masa-harness/main/install.sh | bash
```

これで repo を `~/.masa-harness` に取得し、設定を `~/.claude/` に展開します。
**更新したいときも、まったく同じ1行**を実行してください（最新を取り直して差分だけ反映します）。

終わったら **Claude Code を再起動**してください。

### git を使わない場合（手動ダウンロード）

1. [最新リリース](https://github.com/Masashi-Ono0611/masa-harness/releases/latest) の `masa-harness-kit.tar.gz` を落とす
2. 解凍して `masa-harness-kit/` に入る
3. `bash setup.sh` を実行

> ⚠️ GitHub の「Code → Download ZIP」は**テスト前の開発版（main）**を掴みます。
> 動作確認済みのものが欲しいときは、上の**最新リリース**から落としてください。

---

## あなたの既存設定は勝手に上書きされません

すでに自分で `~/.claude` を育てている人向けに、install は**安全側**で動きます。

| あなたの状況 | 何が起きるか |
|---|---|
| Claude Code 設定がまだ無い | そのまま全部インストール（失うものが無いので即展開） |
| **既に設定がある** | **何も上書きせず**、差分レポート（`~/.claude/.masa-harness/AUDIT-REPORT.md`）だけ出して停止 |

既に設定がある場合、取り込み方は2つ:

- **(A) 全部このキットの内容にする**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Masashi-Ono0611/masa-harness/main/install.sh | MASA_MODE=overwrite bash
  ```
  上書き前のファイルは消さず `*.bak-<日時>` に退避します。

- **(B) 良いところだけ取り込む（おすすめ）**
  Claude Code を開いて、こう頼んでください:
  > 「masa-harness を audit して、良い差分だけ取り込んで」

  あなたの設定を主役にしたまま、キットの良い差分だけを**推奨理由付きで提示**し、
  あなたが承認したものだけを反映します（`masa-harness-audit` skill）。

---

## 更新方法

インストールと同じ1行を再実行するだけです:

```bash
curl -fsSL https://raw.githubusercontent.com/Masashi-Ono0611/masa-harness/main/install.sh | bash
```

- skills / rules / hooks … キットの更新を自動で取り込みます（変更があったファイルは `*.bak-<日時>` に退避）
- CLAUDE.md / settings.json … あなたの個人設定は**自動では変えません**。最新を取り込みたいときは上の (A) か (B) で

---

## アンインストール

このキットが設置したファイルは `~/.claude/.masa-harness/manifest.txt` に記録されています。
丸ごとやめたい場合は、`~/.claude` を install 前のバックアップ（`*.bak-<日時>`）に戻すか、
manifest を見て該当ファイルを削除してください（不安なら Claude Code に手伝ってもらうのが安全です）。

---

## 動作環境

- **macOS / Linux**（hooks が bash / python3、setup は bash）
- **Windows は WSL（Windows Subsystem for Linux）が必要**です。ネイティブ Windows では動きません。
- `governance-gate.py`（危険コマンドの自動ブロック）には **python3** が必要です。

---

## バージョン

現在のキットのバージョンは [`masa-harness-kit/VERSION`](masa-harness-kit/VERSION)、
変更履歴は [`CHANGELOG.md`](CHANGELOG.md) を参照してください。
