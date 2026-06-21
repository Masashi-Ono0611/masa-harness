# マルチモデル セルフ PR レビュー — 外部CLIの導入

`/review:self-multi-model` command（`commands/review/self-multi-model.md`）は、PR を出す前にコードを **第二モデル（Codex を primary、Antigravity CLI `agy` を fallback）** と **Claude** の最低 2 つでレビューし、指摘を統合する。

**外部CLIは任意**。Codex も Antigravity も無ければ Claude 単独で動く（degrade してそのままレビューする）。第二モデルを足すと「2 モデルが一致した指摘＝信頼度高」「Claude の死角を別モデルが拾う」効果が得られる。下のいずれか片方だけでも multi-model は成立する。

## 第二モデルの優先順位

1. **Primary**: Codex CLI（`codex review`）
2. **Fallback**: Antigravity CLI（`agy`、Gemini 3.1 Pro）— Codex が usage limit 等で不能なとき
3. **必ず動く**: Claude（その session）

直列で両方走らせるのではなく、**第二モデル枠は 1 つだけ**走らせる設計。Codex の復活待ちでレビューを止めず、Antigravity へ fallback して即進む。

## Codex CLI（primary）

OpenAI の Codex CLI。`codex review` で diff を agentic にレビューする。

```shell
# 導入（未導入なら）。インストール方法は OpenAI の案内に従う。
which codex            # 導入済みか確認

# 認証（どちらか）
codex login            # ChatGPT Plus/Pro アカウントでサインイン
#   または OpenAI API クレジットを使う場合は API キーを設定

codex login status     # 認証済みか確認（command 側もこれで可否判定する）
```

- 認証が済んでいれば command の入力検証が `✅ 第二モデル: Codex (primary) を使用` を出す。
- **大型 diff（>~30 files）の注意**: `codex review --base` は agentic でレビュー中に repo を自己探索するため、大型 diff だと探索でトークンを食い尽くし **usage limit で途中中断**しやすい。その場合は command の Step 2a「大型 diff」に従い、高リスクのコードだけに絞った diff を stdin で渡す chunked `codex exec` single-shot に切り替える。

## Antigravity CLI（fallback）

Google の Antigravity CLI（`agy`）。無料の Antigravity Starter Quota で動く。旧 Gemini CLI は 2026-06-18 に無料/AI Pro/Ultra 枠が停止したため、こちらへ移行した。

```shell
# 導入
curl -fsSL https://antigravity.google/cli/install.sh | bash
#   → ~/.local/bin が PATH に入る（新しいシェルで有効）

# 認証: agy を素で1回起動して Google Sign-In（TUI なので実ターミナルで実行）
agy
#   サインイン後は keyring に保存され、以降は非対話で動く

# 利用できるモデルを確認
agy models
#   表示名をそのまま command の AGY_REVIEW_MODEL に入れる（例: "Gemini 3.1 Pro (High)"）
```

- 認証が済んでいれば command の入力検証が `✅ 第二モデル: Antigravity CLI (fallback・Gemini 3.1 Pro) を使用` を出す。

## fallback 連鎖（第二モデルが全滅しても止めない）

```
Codex（usage limit）
  → Antigravity CLI（agy・無料 Starter Quota／quota 切れなら次へ）
    → Gemini bot（PR がある repo なら `/gemini review` コメント・daily quota 制・~24h で復活）
      → Claude（必ず動く）
```

CLI が全滅しても Claude + Gemini bot で 2 モデル成立する。PR を「マージ直前で停止」する運用なら、Gemini bot レビューは async で merge 前に着けばよい。

## モデル名の SoT（"腐る軸"）

review に使うモデル名は command の「入力検証」冒頭の SoT ブロックで一元管理する：

```shell
CODEX_REVIEW_MODEL="gpt-5.5"               # codex review/exec に渡す強モデル
CODEX_REVIEW_EFFORT="high"                 # 推論深さ（最大は xhigh）
AGY_REVIEW_MODEL="Gemini 3.1 Pro (High)"   # agy fallback の強モデル
```

- **review は session 既定モデルに依存させず、明示的に強モデルへ固定する**（別作業で session を安いモデルへ切替えても review 品質を落とさないため）。
- **モデル名は別ベンダー CLI 側の都合で変わる**。Claude Code のアップデートでは追従しないので、世代が変わったら `codex --help` / `agy models` で確認してこのブロックだけ更新する。
- **tier を上げる前に effort を疑う**: モデル tier を上げる前に、推論深さ（`CODEX_REVIEW_EFFORT` / agy の Low/Medium/High 表記）で足りるか先に見る。

## トラブルシュート

| 症状 | 対処 |
|---|---|
| `agy` が `Please sign in ...` を返す / `agy models` がサインインを要求 | `agy` を素で1回起動して Google Sign-In（keyring 保存・以降は非対話） |
| `agy` 未導入 | `curl -fsSL https://antigravity.google/cli/install.sh \| bash`（`~/.local/bin` を PATH に） |
| Antigravity の quota 切れ | `agy models` で枠確認。尽きたら Gemini bot（`/gemini review`）か Claude 単独へ fallback |
| Codex が usage limit | command が復活時刻をレポート footer に記録。Antigravity へ fallback して即進む |
| 大型 diff で Codex が途中中断 | 高リスクコードだけに絞った diff を stdin で渡す chunked `codex exec`（command Step 2a） |
| 両方とも使えない | Claude 単独で続行（command がその旨をレポートに明記する） |
