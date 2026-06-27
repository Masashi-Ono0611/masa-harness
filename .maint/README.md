# .maint — masa-harness-kit メンテ専用（配布物の外）

ここは **kit を作る側（作者）専用**のツール。`masa-harness-kit/` の外に置いてあり、tar.gz にも含めない（受け取った人には無意味＋台帳に個人絶対パスを含むため）。

## 何のためか

`masa-harness-kit/` は本体（`~/.claude/` と `~/Developer/.claude/skills/`）から**手作業で汎用化**した配布物（個人パス・org 名・未同梱 skill 参照を除去/placeholder 化）。本体を直しても kit は自動追従しないので、**ズレても気づけない**（実際 stack-audit の概念変更が kit に取り残された）。

`kit-sync` は「本体が前回同期時から変わったか」を検出する。`cp` 自動同期は**しない**理由:
- 本体↔kit はほぼ全ファイルが generalized（意図的な汎用化差分）。verbatim は `rules/typescript.md` のみ。
- 単純 cp は (1) 個人情報を配布物に漏らし (2) 汎用化を破壊する。

## ファイル

- `kit-manifest.tsv` — 同期台帳。`kit相対パス〔TAB〕本体ソース(~/...)〔TAB〕sync_type〔TAB〕baseline_sha256`。`baseline_sha256` = 「kit がこの本体状態まで追従済み」の基準点。
- `kit-sync.sh` — 下記サブコマンド。**ファイル同期 drift（hash）**を見る。
- `capability-check.sh` — `masa-harness-kit/capability-manifest.json`（機械可読 owner マップ）と kit 構成の整合を検証する別レイヤーのゲート。**capability-layer drift** を見る＝orphan（ship 済だが capability 未宣言）/ dangling（実在しない component を指す）/ id 重複 / policy_ref の実在。read-only・exit 1 で fail。`release-guard.yml`（PR/push）が呼ぶ。

## サブコマンド

| コマンド | 動作 |
|---|---|
| `kit-sync.sh check`（既定） | 本体ソースの現 sha を baseline と比較し DRIFT を列挙＋ sanitize ガード（kit に個人情報混入がないか）。drift 0 & clean で exit 0 |
| `kit-sync.sh sanitize` | sanitize ガードだけを走らせる（本体パス不要）。`release.yml` が release 前の gate に使う（`check` は CI では MISSING になり使えない） |
| `kit-sync.sh apply` | **verbatim の drift のみ** 本体→kit に cp し baseline 更新。generalized は触らず手反映を促すのみ |
| `kit-sync.sh diff <kit_rel>` | その entry の 本体 vs kit を diff（汎用化を保って手反映する補助） |
| `kit-sync.sh stamp <kit_rel \| --all>` | baseline を本体現 sha に更新（generalized を手反映し終えた後に叩いて「追従済み」を確定） |
| `kit-sync.sh pack` | `masa-harness-kit/` を `masa-harness-kit.tar.gz` に再生成（`*.bak-*` / `__pycache__` / `.DS_Store` 除外） |
| `kit-sync.sh release-status [--strict]` | 最新タグ `vX.Y.Z` 以降に配布物（`masa-harness-kit/` 配下、VERSION/CHANGELOG を除く）が変わったのに VERSION 据え置きなら **未リリースの漏れ**として列挙。`--strict` で漏れ時 exit 1（CI gate 用） |
| `kit-sync.sh doc-check [--strict]` | README と実配布物（skills/commands/hooks/rules）の整合を検証＝**stale tree 防止**。**hard gate=各配布物名が README に列挙されているか**（`grep -F` 固定文字列＋ skills は末尾 `/` で境界化）。実数は informational に出力（散文カウントは phrasing 依存で脆いため gate にしない）。`--strict` で未記載時 exit 1（CI gate 用） |

> `release-status` / `doc-check` は `release-guard.yml`（PR/push）が `--strict` で呼ぶ＝**リリース漏れ・README stale を構造的に防ぐ**。`doc-check` を PR の required status check にすれば stale な README の merge をブロックできる。

## 標準ワークフロー（本体を直したとき）

```
bash .maint/kit-sync.sh check                 # 1. drift と sanitize を確認
bash .maint/kit-sync.sh apply                 # 2. verbatim drift を自動反映
bash .maint/kit-sync.sh diff <generalized_file>  # 3. generalized は diff を見て…
#    …汎用化（placeholder・未同梱 skill 参照除去）を保ったまま kit/ を手で編集
bash .maint/kit-sync.sh stamp <generalized_file>  # 4. 手反映できたら baseline 確定
bash .maint/kit-sync.sh check                 # 5. drift 0 / sanitize clean を確認
bash .maint/kit-sync.sh pack                  # 6. tar.gz 再生成
```

## sanitize ガード

`check` / `sanitize` は kit/ 全体を `SECRET_PAT` で grep し、個人パス・メール・org 名の混入を検出する（汎用化漏れの最終防波堤）。

- **公開リポに置く `kit-sync.sh` の `SECRET_PAT` には作者本人の識別子だけ**（個人パス `masashi_mac_ssd` / メール `masashi.ono`）を書く。
- **業務 org 名など公開したくない追加パターンは `.maint/.secret-extra`**（gitignore 済み・公開リポに出ない）に `a|b|c` 形式で 1 行。`kit-sync.sh` が存在時のみ OR 連結する。
- bare `masashi`（kit のブランド名 = masashi の harness）は意図的に除外（誤検知防止。秘密の実形は path/email で捕捉）。

> CI（`release.yml`）では `.secret-extra` が無いので、本人識別子のみで sanitize gate がかかる。org 名チェックはローカル（`.secret-extra` がある環境）でのみ効く。

## kit-native ファイル（本体ソース無し＝drift 追跡対象外）

本体に対応物が無く配布の仕組みのために作ったファイルは manifest に載せない（drift 検出の対象外）。現在:
`install.sh` / `setup.sh` / `VERSION` / `skills/masa-harness-audit/` / `docs/`（`design.md` / `multi-model-review.md`）、repo ルートの `README.md` / `CHANGELOG.md` / `.github/workflows/release.yml`。

## リリース（GitHub Release）

ローカルの `pack` は tarball のプレビュー/手渡し用。**正規のリリースは git タグ push**:

```
# 本体 drift を反映し sanitize clean を確認したあと
# masa-harness-kit/VERSION を上げて commit（PR 経由）
git tag vX.Y.Z && git push origin vX.Y.Z   # → release.yml が Release 自動発行
```

`release.yml` は push 時に sanitize gate → タグと VERSION の一致確認 → shell 構文チェック → tarball ビルド → `gh release create --generate-notes` を実行する。

## 注意

- baseline は「今を基準」に置いてある（既存の未追従 stale は遡及していない）。その箱所が次に本体側で変わった時に drift として拾われる。
- skill は `SKILL.md` 単位で追跡する（kit には各 skill の SKILL.md のみ同梱）。本体 skill に `references/` 等が増えて kit に入れたくなったら manifest に行を足す。
