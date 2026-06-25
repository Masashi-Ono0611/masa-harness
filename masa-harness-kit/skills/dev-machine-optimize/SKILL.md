---
name: dev-machine-optimize
description: |-
  macOS マシン全体 (SSD 空き容量 + RAM) を 1 ワークで最適化する。アクティブなプロジェクト (直近14日 commit) と現セッション/MCP を自動検出して除外しつつ、SSD のキャッシュ/依存物/ビルド成果物と RAM の重い/重複プロセスを「安全に解放可 / 確認要 / 触らない」に分類して提案、承認後のみ実行する。「マシン最適化」「Mac の SSD と RAM を掃除」「ストレージとメモリを一括で」「容量とメモリ両方空けたい」「Mac が重い・容量が少ない」で発動。SSD 単独 / RAM 単独でも本 skill で完結 (旧 dev-storage-cleanup / dev-ram-cleanup を統合)。
scope: local-only
updated_at: 2026-05-23
---

# Dev Machine Optimize

> **環境前提**: repo 群の置き場は環境変数 `REPOS_BASE`（既定 `$HOME/Developer`）で指定する。アクティブなプロジェクト判定（直近 commit の検索）の対象になる。

SSD と RAM を同じ「検出 → スキャン → 3層分類 → 提案 → 承認後実行 → before/after」骨格で横断最適化する。SSD だけ / RAM だけの依頼でも該当 track のみ走らせれば完結する。

## Step 一覧 (6 段)

| Step | 内容 | SSD track | RAM track | 完了条件 |
|---|---|---|---|---|
| 0 | 全体スナップショット + 除外確定 (アクティブなプロジェクト / 現セッション PID 祖先辿り / MCP) | ✅ | ✅ | 除外リスト + 現セッション PID 確定 |
| 1 | スキャン (実 Data volume `df` / caches / packages / build artifacts ‖ vm_stat / RSS / 重複) | ✅ | ✅ | サイズ・RSS 降順リスト |
| 2 | 分類 (安全解放可 / 確認要 / 触らない) | ✅ | ✅ | 各候補にラベル |
| 3 | ユーザーに提案 (表形式) | ✅ | ✅ | 承認待ち |
| 4 | 承認分のみ実行 (公式 prune ‖ graceful quit) | ✅ | ✅ | 実行完了 |
| 5 | before/after サマリ + 残候補再提示 | ✅ | ✅ | レポート出力 |

> 依頼が「SSD だけ」「RAM だけ」なら該当 track のみ。「マシン最適化」「両方」は両 track。

## Constants

| 名前 | 値 |
|---|---|
| アクティブなプロジェクト判定 | `${REPOS_BASE:-$HOME/Developer}` 配下で直近 14 日に git commit あり (maxdepth 4) |
| **実空き容量の計測元** | `df -h /System/Volumes/Data` (**`df -h /` はAPFSシステムスナップショットで誤読**) [E3] |
| SSD 安全解放可 (頻出大物) | `~/.cache/uv` / `~/Library/pnpm` store / `~/go/pkg`+`go-build` / `Caches/{trivy,Homebrew,pip,puppeteer,ms-playwright}` / ブラウザ Caches / 未使用 `node_modules`,`.next`,`dist`,`build` |
| SSD 公式 prune | `pnpm store prune` / `go clean -modcache -cache` / `uv cache clean` / `brew cleanup -s` / `trivy clean --all` / `npm cache clean --force` / `docker builder prune -f` + `docker image prune -a -f` (稼働コンテナ無関係に未使用層回収・[E8]) |
| **brew パッケージ撤去** | 直近 install の cruft は `ls -lt $(brew --prefix)/Cellar` で特定。leaf ツール除去は `brew uninstall <leaf> && brew autoremove` (autoremove は他から不要になった依存だけ安全連鎖除去・共有 lib は保持)。除去前に `brew uses --installed <dep>` で共有判定 [E7] |
| **docker reclaim の例外** | `docker prune` は VM **内部**の空きを作るだけ＝colima のディスクイメージは sparse high-water-mark でホスト `du ~/.colima` は即縮まない。ホスト解放には VM 停止＋イメージ圧縮が要るので稼働中はやらない。それでも内部 prune は「今後の build で .colima が更に膨らむのを防ぐ headroom」として有効 [E8] |
| **uv cache の例外** | `uv tool`/`uvx` 系 MCP (workspace-mcp 等) が `~/.cache/uv/.lock` を保持中は clean 不可。**`--force` は走行中ツール破損リスクで使わず**、MCP のない素ターミナルでの `uv cache clean` を案内 [E4] |
| RAM 除外 (kill 圏外) | `kernel_task`,`WindowServer`,`launchd`,`mds*`,`fseventsd`,`coreaudiod`,`loginwindow`,`cfprefsd`,`lsd`,`nsurlsessiond`, **現セッション (PID 祖先辿りで確定)**, アクティブ MCP server, 稼働中 colima/docker コンテナ + その postgres, **ローカル開発スタック (下記)** |
| **ローカル開発スタック (デフォルト保護)** | アクティブなプロジェクトがローカル起動する常駐物は SSD/RAM とも触らない。**例**: colima/lima VM + `.colima` / アプリのコンテナ群 (backend / db / graphql 等、各 LISTEN port) / **これらを転送する `limactl` + `ssh` プロセス (kill するとポート転送が全断)** / homebrew `postgresql@N` (ローカル DB)。`docker ps` + `lsof -iTCP -sTCP:LISTEN` で稼働中のものは在席判定して除外 [E6] |
| graceful 終了 | `osascript -e 'quit app "X"'` 優先 → `kill -TERM <PID>` → `kill -9` はユーザー再確認後 |
| `sudo purge` 判定 | `vm_stat` の compressor が **5GB 超かつ重プロセス終了後も残る** 場合のみ。重プロセス/古セッション終了で自力回復することが多い [E5] |

## 責務範囲 (被りなし)

| 用途 | 本 skill | `oss-clone-security` / `cso` | `claude-stack-audit` |
|---|---|---|---|
| SSD 空き容量 + RAM の系統的最適化 | ✅ | ❌ | ❌ |
| 取り込み瞬間/守備のセキュリティ監査 | ❌ | ✅ | ❌ |
| Claude 設定の健全性・導入提案 | ❌ | ❌ | ✅ |

> 旧 `dev-storage-cleanup` / `dev-ram-cleanup` は本 skill に統合・廃止済 (2026-05-23)。

## When to Use

- 「マシン最適化」「Mac の SSD と RAM を一括で掃除」「容量とメモリ両方空けたい」
- 「ストレージ掃除」「不要なパッケージを大きい順で」(SSD track のみ)
- 「メモリ掃除」「Mac が重い」「重いプロセスを大きい順で」(RAM track のみ)
- 容量警告 (<10%) / メモリ逼迫 (compressor 肥大・Free 数百MB) のとき

**スキップ条件**: 1 ファイル `rm` / 1 アプリ単発 quit なら本 skill 不要 (系統的監査用)

---

## Implementation Steps

### Step 0: 全体スナップショット + 除外確定 [必須]

**目的**: 削除/終了してはいけない対象 (アクティブなプロジェクト・現セッション・稼働 MCP) を先に確定する
**条件**: 必ず Step 1 より前。現セッション PID は **RSS 順位で推定せず祖先辿りで確定** (推定は誤る [E1])
**アクション**:
```bash
# 現セッションの claude PID を祖先辿りで特定 (自己保護の要)
pid=$$
while [ "$pid" -gt 1 ]; do
  ps -p "$pid" -o comm= 2>/dev/null | grep -qi claude && echo "現セッション claude PID = $pid"
  pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' '); [ -z "$pid" ] && break
done

# アクティブなプロジェクト (SSD track の除外)
find "${REPOS_BASE:-$HOME/Developer}" -maxdepth 4 -type d -name .git 2>/dev/null | while read g; do
  r=$(dirname "$g"); l=$(git -C "$r" log -1 --since='14 days ago' --format='%ar' 2>/dev/null)
  [ -n "$l" ] && echo "$l | ${r#$HOME/}"; done | sort

# 稼働中の他 claude セッション (cwd/tty 付きで識別)
for p in $(pgrep -f "claude --" 2>/dev/null); do
  cwd=$(lsof -a -p $p -d cwd -Fn 2>/dev/null | grep ^n | cut -c2-)
  echo "PID $p | tty=$(ps -p $p -o tty= | tr -d ' ') | $(ps -p $p -o etime= | tr -d ' ') | cwd=$cwd"; done

# 稼働 docker コンテナ + LISTEN ポート (.colima / ローカルスタックを触らない根拠)
docker ps --format '{{.Names}} ({{.Status}})' 2>/dev/null | head
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E "limactl|ssh|postgres|node|bun" | awk '{print $1,$2,$9}' | sort -u | head
```
**完了条件**: ユーザーが「現セッション + これらを保護、追加/削除ある?」に応答済。**他セッションは cwd/tty を提示し、"現セッションと取り違えていないか" を必ず確認**。**ローカル開発スタックが稼働中なら Constants の保護対象として既定で除外し、その VM/コンテナ/ポート転送 ssh は提案に載せない**

---

### Step 1: スキャン

**目的**: SSD 使用量と RAM 消費を大きい順に取得
**アクション**:
```bash
# === SSD track ===
df -h /System/Volumes/Data   # 実空き (/ ではない)
du -sh ~/Library/Caches/* 2>/dev/null | sort -rh | head -15
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -rh | head -15
du -sh ~/.npm ~/.cache/uv ~/Library/pnpm ~/go/pkg ~/Library/Caches/go-build \
  ~/Library/Caches/{pip,Homebrew,trivy,ms-playwright,puppeteer} ~/.cargo ~/.colima 2>/dev/null | sort -rh
find "${REPOS_BASE:-$HOME/Developer}" -maxdepth 5 -type d \( -name node_modules -o -name dist -o -name build -o -name .next -o -name target -o -name out \) 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh | head -20
# Docker 内 reclaimable (.colima dir 自体は触らないが prune で内部回収可・コンテナ稼働中でも安全) [E8]
docker system df 2>/dev/null   # RECLAIMABLE 列を見る (build cache + 未使用 image が数GB 溜まりがち)

# === RAM track ===
vm_stat | awk '/Pages free/{f=$3}/Pages occupied by compressor/{c=$5}END{p=4096;
  printf "Free: %.2f GB | Compressed: %.1f GB\n", f*p/1073741824, c*p/1073741824}'
ps -caxm -o pid,rss,command | sort -k2 -rn | head -25
ps -ax -o command | sed 's/ .*//' | sort | uniq -c | sort -rn | awk '$1>=3' | head -12

# === 孤児/残留プロセス hunt (RSS に出ない「謎に残ってる」やつ・毎回実施) [E7] ===
ps -axo pid,ppid,stat,etime,comm | awk '$3 ~ /Z/'   # ゾンビ (state Z)
# PPID=1 に reparent された孤児の自動化/dev-server/CLI agent (親セッション消滅後も残る)
ps -axo pid,ppid,etime,rss,command | awk '$2==1' | grep -iE "node|bun|python|vite|next|playwright|puppeteer|chrom|headless|terminal-agent|dev|serve|daemon|proxy" | grep -viE "/System/|/Library/Apple|Visual Studio|Code Helper|/Applications/.*\.app/Contents/MacOS/[A-Z]" | head -15
# アプリ同梱 daemon が本体アプリ閉鎖後も残存することがある (例: 占有ポートも解放されない) — 本体プロセス不在なら孤児
ps -axo pid,etime,command | grep -iE "/Applications/.*/(Resources|bin)/.*(daemon|proxy|storage|server)" | grep -v grep | head
```
**完了条件**: SSD サイズ降順 + RAM RSS 降順 + 重複リスト + **孤児/残留プロセス (ゾンビ・PPID=1 reparent 孤児・本体閉鎖後の同梱 daemon)** 取得。孤児は RSS が小さくても「謎に残ってる」cruft なので必ず拾う [E7]

---

### Step 2: 分類 (3 階層)

**SSD**
| 分類 | 基準 | 例 |
|---|---|---|
| **安全解放可** | キャッシュ性質・再 DL 可・アクティブなプロジェクトで未使用 | `~/.cache/uv`(※lock 注意) / pnpm store prune / go cache / trivy / brew / ブラウザ Caches / **docker build cache + 未使用 image (`docker builder prune` / `docker image prune -a`・稼働コンテナ無関係) [E8]** |
| **確認要** | アクティブなプロジェクトでの使用可能性 / 再構築コスト大 | Claude `vm_bundles` / `ms-playwright` (ブラウザ自動化で使用?) / `~/.npm` |
| **触らない** | アクティブなプロジェクト依存・稼働中・設定 | `.colima` (コンテナ稼働中) / ローカル開発スタックの依存物 / ブラウザ Profile 本体 / Keychain / アクティブなプロジェクトの `node_modules` |

**RAM**
| 分類 | 基準 | 例 |
|---|---|---|
| **安全終了可** | 重複・古い別セッション・閉じ忘れ dev server・**孤児プロセス** | 古い claude セッション (cwd/tty で識別) / 重複 MCP / ゾンビ / **PPID=1 reparent 孤児 (例: 親消滅後も残る長命 agent・自動化 headless・dev server) [E7]** / **本体アプリ閉鎖後も残る同梱 daemon (占有ポートも解放される) [E7]** |
| **確認要** | 業務関連の可能性 | Brave/Chrome (タブ多) / Slack / Notion / IDE / Telegram |
| **触らない** | システム・現セッション・稼働コンテナ | システム系 / 現セッション (祖先辿り確定) / colima VM + コンテナ + その postgres / **ローカルスタックのポート転送 `limactl`・`ssh` (kill で全断)** / homebrew postgres (アクティブなプロジェクトの DB 保持時) |

**判断保留の大物**: Claude `vm_bundles` (local-agent VM) / Docker VM (`docker system prune` で部分可) / ブラウザ本体 (quit でタブ復元)

---

### Step 3: ユーザーに提案

**目的**: 安全なものから表形式で提示 → 承認待ち
**フォーマット**:
| track | 対象 | サイズ/RSS | コマンド | 影響 |
|---|---|---|---|---|
| SSD | `~/.cache/uv` | 11G | `uv cache clean` (lock 時は素ターミナル案内) | 初回 build 再DL |
| RAM | PID 16357 (古いセッション, 20h) | 126MB | `kill -TERM 16357` | 古いセッション、業務影響なし |

**完了条件**: ユーザーが解放対象を選択。**`sudo purge` / `kill -9` / vm_bundles 削除は個別に明示確認**

---

### Step 4: 実行

**SSD** (公式 prune 優先):
```bash
pnpm store prune; go clean -modcache -cache; brew cleanup -s; trivy clean --all; npm cache clean --force
docker builder prune -f; docker image prune -a -f   # 稼働コンテナ/イメージは保護・未使用層のみ [E8]
brew uninstall <leaf> && brew autoremove            # 直近 install の cruft 撤去 (共有依存は autoremove が保持)
uv cache clean   # ← lock エラーなら --force せず Step 5 で素ターミナル案内に回す
```
**RAM** (graceful 優先):
```bash
osascript -e 'quit app "Brave Browser"'   # GUI は graceful (未保存ダイアログで中断)
kill -TERM <PID>                            # CLI プロセス・孤児 (PPID=1 の長命 agent/同梱 daemon 等)
# kill -9 はユーザー再確認後のみ
```
**`sudo purge`**: compressor 5GB 超かつ重プロセス終了後も残る場合のみ、ユーザーに `! sudo purge` 実行を依頼 (sandbox 内不可)
**完了条件**: 承認分の実行完了 (uv lock は「保留」として記録)

---

### Step 5: before/after サマリ

**アクション**:
```bash
df -h /System/Volumes/Data | tail -1 | awk '{print "SSD 空き "$4" ("$5")"}'
vm_stat | awk '/Pages free/{f=$3}/Pages occupied by compressor/{c=$5}END{p=4096;
  printf "RAM Free %.2fGB | Compressed %.1fGB\n", f*p/1073741824, c*p/1073741824}'
```
**出力**:
- before/after の SSD 空き + RAM Free/Compressed
- 実行済み一覧
- **保留候補の再提示** (uv lock → 素ターミナルで実行 / vm_bundles / 残「確認要」) を次回向けに

---

## Constraints

### 致命的 (Errors)
| Pattern | Preferred | Reason |
|---|---|---|
| Step 0 (除外確定) を skip して prune/kill | アクティブなプロジェクト + 現セッション PID + 稼働MCP/コンテナ確定後に進む | アクティブなプロジェクトの破損 / 現セッション kill で作業中断 |
| 現セッションを RSS 順位で推定して kill | **必ず PID 祖先辿りで現セッション確定** | RSS 最大≠現セッション、誤 kill リスク [E1] |
| `uv cache clean --force` を MCP 稼働中に実行 | lock 検出時は素ターミナルでの実行を案内 | 走行中 uv-tool MCP の環境破損 [E4] |
| 削除/kill をユーザー承認なしに実行 | Step 3 で表提示 → 承認後 Step 4 | データ永続消失 / 作業中断 |
| システム系プロセス kill | `kernel_task`/`WindowServer`/`launchd`/`mds*` 等は触らない | macOS 起動不能 |
| 稼働中 colima/コンテナの `.colima` 削除 | `docker ps` で稼働確認、稼働中は触らない | 開発環境破壊 |
| ローカル開発スタックの VM/コンテナ/ポート転送 `ssh`/`limactl` を kill・削除 | Constants の保護対象として既定で除外、提案に載せない | LISTEN port が全断、稼働中開発が停止 [E6] |

### 注意 (Warnings)
| Pattern | Preferred | Reason |
|---|---|---|
| `df -h /` で空き判定 | `df -h /System/Volumes/Data` | `/` はシステムスナップショットで実空きを誤読 [E3] |
| `sudo purge` を即実行 | compressor 5GB 超かつ終了後も残る時のみ | 重プロセス終了で自力回復しがち、不要な I/O スパイク回避 [E5] |
| ブラウザ稼働中に Cache 削除 | quit 後に Cache 削除 | 稼働中削除でキャッシュ不整合 |
| `kill -9` を即実行 | TERM → 効かない時のみ、再確認 | データ未保存喪失 |

## Related Skills

| Skill | 関係 |
|---|---|
| `oss-clone-security` / `cso` | セキュリティ監査 (本 skill は容量/メモリ最適化、別軸) |
| `claude-stack-audit` | Claude 設定健全性 (本 skill は OS リソース) |
| ブラウザ Profile / Cache の場所 | OS 標準位置（macOS は `~/Library/Caches/<browser>`）。web-debug 系ルールを持っていれば参照 |

## Evidence Index

| ID | 出典 | 学び |
|---|---|---|
| E1 | 2026-05-23 統合 cleanup (個人環境) | 現セッションは RSS 最大とは限らない (推定 97576 ≠ 実 13119)。PID 祖先辿りで確定すべき |
| E3 | 2026-05-23 同 | `df -h /` が 34Gi 空き表示 (スナップショット)、実体は `/System/Volumes/Data` で 166Gi 使用/34Gi 空き |
| E4 | 2026-05-23 同 | `uv cache clean` が lock timeout、保持元は現セッション子の `uvx workspace-mcp`。`--force` 不可、素ターミナル案内へ |
| E5 | 2026-05-23 同 | compressor 7.7GB が古セッション終了 + Brave quit だけで 0.3GB に自力回復、`sudo purge` 不要だった |
| E6 | 2026-05-23 (ローカルスタック保護要望) | ローカルスタックは colima/lima VM 上の docker コンテナ群で、ポートは `ssh` (lima 転送) 経由のことがある。この ssh/limactl を kill すると全ポート断。`.colima` + homebrew postgres 含めデフォルト保護に固定 |
| E2 | 旧 dev-ram-cleanup | uvx workspace-mcp 等の重複 MCP 起動は `uniq -c \| sort -rn` で検出 |
| E7 | 「謎に残ってる」プロセス hunt | RSS top では出ない孤児/残留が cruft の本体だったことがある: ① 長命 agent/dev-server が PPID=1 で数日孤児化 ② アプリ本体閉鎖後も同梱 daemon が残存しポート占有。両者 graceful kill で除去。逆にライブセッション紐付き MCP (PPID=稼働 claude) は孤児と誤認しない。brew cruft は `brew uninstall <leaf> && brew autoremove` で leaf+不要依存のみ除去、共有 lib は保持 |
| E8 | Docker 見落とし | `.colima` を「触らない」と過保護分類して docker 内 reclaimable を見落としやすい。`docker system df` で可視化必須。`docker builder prune`/`docker image prune -a` は稼働コンテナ無関係に未使用層を回収。**ただし colima ディスクは sparse high-water-mark でホスト `du` は即縮まず**、ホスト解放には VM 停止＋圧縮が必要。内部 prune は今後の膨張防止 headroom として有効 |
