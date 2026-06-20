# Agent モデルルート（時間対効果の最大化 + トークン予算管理）

Agent (subagent) 呼び出し時に **私 (Claude) がタスク特性 × トークン残量に応じて model を自動選択** するルール。

## 設計原則

- **目的は質の維持と時間対効果の最大化**。ただし **月次トークン予算は hard constraint**
- `仕事時間 = 推論時間 + 巻き戻し時間 + 統合時間 + リミット超過停止時間`
  - `リミット超過停止時間` は通常 0、超過時は ∞（その月の作業停止）→ **hard constraint**
- Opus は思考が深い代わりに latency + token 消費が高い。**軽いタスクで Opus を使うと、品質が上がらないまま遅くなり、かつ月次予算を消耗する**（二重の時間損）
- Haiku は速く・浅い。**重いタスクで Haiku を使うと、品質が落ちて巻き戻し時間が発生する**（時間損）
- **デフォルトは Sonnet**。Opus は「Sonnet では質が明らかに不十分」と判断できるタスクのみ
- **実験フェーズ token 観**: ルーチン実行（既知パターンの繰り返し）は Sonnet で温存してクオータを守り、**浮いた分を「一度作れば繰り返し効く構築物」（self-improving loop / 運用基盤 / skill 設計 = AI Founder 業務）に Opus で惜しまず投資**する。hard constraint（リミット超過 ∞）は維持しつつ、burn 先を "消費" でなく "資産形成" に寄せる

> 仕事時間 = 推論時間 + 巻き戻し時間 + 統合時間 + リミット超過停止時間。リミット超過は ∞ なので hard constraint。

---

## ルール記述の原則: Expiry Date Axis（腐る軸と腐らない軸を分ける）

routing rule を書く / 直すときは、**腐らない判断軸**と**腐る具体**を最初から分けて書く（混ぜると rule 全体が早く陳腐化する）。本ルールも同じ構造で読む:

- **腐らない（判断軸・恒久）**: 「軽い bounded タスクか / 深い cross-module・セキュリティ・前例なし tradeoff か」「巻き戻しコスト vs token コストの天秤」「hard constraint = 月次リミット超過は ∞」。この層は model 名が変わっても効く
- **腐る（具体・要更新）**: 個々の model 割当（`Explore`=Haiku 等）・tier 名・「実測した最適点」の数値。新 model 世代が出たら **この層だけ** 差し替える
- **含意**: 「作業=モデル A / 創造=モデル B」式の "今のモデルはこう" という割当を**恒久ルールとして書かない**（世代前提で陳腐化が速く dead rule 化する）。書くなら腐る層に隔離し、判断軸（= なぜその割当か）を恒久層に残す
- 含意の由来: 「作業=モデル A / 創造=モデル B」式の固定割当が model 世代交代で陳腐化する問題から（判断軸を恒久層に、割当を腐る層に分ける）

---

## デフォルトルート（タスク特性ベース）

| Agent (subagent_type) | デフォルト model | Opus に上げる条件 |
|---|---|---|
| `Explore` | **`haiku`** | ファイル名検索 / grep / 浅い読み込み。深く読む必要が出た時点で Sonnet |
| `general-purpose` | **`sonnet`** | 中庸な調査・列挙・集約。cross-module 整合性・セキュリティ判断が入れば Opus |
| `Plan` | **`sonnet`** ★ | **ファイル数 >10 / 新規アーキテクチャ / セキュリティ / 前例のない tradeoff** のみ Opus |
| `code-reviewer` | **`sonnet`** ★ | **セキュリティ / governance / incident 直結** のみ Opus |
| `worktree-dispatcher` / `parallel-planner` | **`sonnet`** | タスク分解は中庸な複雑度 |
| `claude-code-guide` | **`sonnet`** | Q&A、軽量 |
| Web-debug 系 (ブラウザ操作 agent) | **`sonnet`** | ブラウザ操作 + 簡易判定 |
| その他 specialized agent | agent definition の default | 各 SKILL.md / agent file が指定済なら尊重 |

★ **2026-05-13 変更**: 旧ルールは Opus デフォルト。月次リミット超過の実績を受け Sonnet に変更。

> **model 指定なし = 親 session と同じモデルにフォールバック**。タスク特性が上の表に該当するなら **必ず明示**。

---

## Opus を使うべきケース（絞り込んだ基準）

1. **大規模 codebase 解析**（>10 ファイル横断 / cross-module 整合性が必要）
2. **セキュリティ / 法務 / governance クリティカル**（漏れの時間損失が大きい）
3. **creative / 前提破壊**（AI Founder 業務、前例のない設計判断、tradeoff）。**self-improving loop / 運用基盤の新規構築など「一度作れば繰り返し効く資産形成」を含む**
4. **一発 precision-critical**（リトライコストが極めて高い。間違えると月をまたぐ被害）
5. **過去 incident 直結**（同じ事故再発防止が目的の調査）
6. **ユーザーが明示的に「深く」「丁寧に」「重く」と指示**

→ それ以外は **Sonnet を先に試す**。Sonnet 出力で質が不十分なら Opus に上げる。

## Opus を避けるケース

1. **単純な検索 / grep / file listing**（深い読みなし）
2. **既知パターンに従う mechanical な edit**（同形式の繰り返し）
3. **format / lint / typo 確認**
4. **1 ファイル内 / <100 行の浅い調査**
5. **中規模の実装計画**（ファイル数 <10、既存パターン踏襲）
6. **ルーティン code review**（新規セキュリティ懸念なし、既知パターン）

→ これらは Haiku/Sonnet の速度の方が体感アウトプット時間を縮め、かつ月次予算を温存する。

---

## Token-Pressure Mode（トークン圧迫時）

ユーザーが「リミット近い」「節約モードで」と指示したとき、または月後半で消費ペースが速いと判断したとき発動。

| 通常時 | Token-Pressure Mode |
|---|---|
| Plan → Sonnet / Opus | Plan → Haiku（骨格確認のみ） / Sonnet |
| general-purpose → Sonnet | general-purpose → Haiku |
| code-reviewer → Sonnet / Opus | code-reviewer → Sonnet（絶対 critical のみ Opus） |
| Explore → Haiku | Explore → Haiku（変わらず） |

追加施策（Token-Pressure 時は必ず適用）:
- subagent に `"report in under 200 words"` / `"bullet list only, no prose"` を付ける
- 並列 Opus agents を直列に変えてスパイクを避ける
- 大きな prompt に前回 output の要点のみ抜粋して渡す（全文再送しない）

**発動シグナル:**

| シグナル | アクション |
|---|---|
| ユーザーが「リミット近い」「節約して」と言う | Token-Pressure Mode に切替 |
| セッション内で Opus subagent を 3+ 回起動済み | 以降の新規 Opus spawn を Sonnet に格下げ |
| context が明らかに長い（要約が複数回入った） | 出力を短く保ち、必要なら新セッションを勧める |

> ユーザーが「そのまま続けて」と言えば解除。自動で固定しない。

---

## 私が Agent 呼び出し時に必ず指定する書式

```typescript
Agent({
  description: "...",
  subagent_type: "Explore",
  model: "haiku",          // ← タスク特性で選択
  prompt: "..."
})
```

`model` field を省略すると親 session 同モデルにフォールバック（多くの場合 Opus）。**タスク特性が上の表に該当するなら必ず明示**。

迷うときは Sonnet を選ぶ（中央値、巻き戻しコストが最小化される）。

---

## ユーザーが override したいとき

明示的に「Plan を Sonnet で」「Explore も Opus で」と指示があれば従う。本ルールは私の default 挙動を定義するもので、絶対のものではない。

特に **「速度より精度」「重く考えて」** と指示があれば全 Agent を Opus に上げる。

---

## 実測ベースの最適点（pointer＋reflex）

ルーティング既定は「主張」でなく実測で裏取りする。各自の環境で model × タスクの sweep を1度回し、grade とコストの実測値を最適点として記録しておく。

実測で確定した reflex（2026-06-12 初回 run）:
- **Opus/Sonnet に上げる前に、まず effort を疑う**: plan-tier で adaptive thinking が grade 不変のまま 14–20× コストになった実測あり。主コスト要因が tier でなく effort/thinking のことがある → 上位 tier に上げる前に effort↓で足りるか先に見る。
- **Explore→Haiku は最適点上**（実測: grade 1.0 を Sonnet比 1/3 コスト）。本表の Haiku 既定は据え置き。
- **Opus は測った全 archetype で品質ゲインゼロ** → 本表「Opus は Sonnet が明らかに不十分な時のみ」を実測が支持。

実測追補（discriminate run・難 fixture×ladder）: subtle bug / trap / 多ファイル root-cause でも Haiku が全通過 → **bounded single-shot タスクは Haiku で十分**（Explore 既定を補強）。tier 差は agentic 多段・大 context・生成品質など single-shot eval が届かない format で出る＝本表の Sonnet/Opus 条件と整合。よって **Plan/general-purpose/code-reviewer の Sonnet 既定は据え置き**（実タスクは大抵その「届かない format」側）。詳細 README。

---

## 関連

- 観測: セッションログを集計して model 配分（Opus 偏重）を監視するツールを各自で持つとよい。
- **改訂経緯の教訓**: 「Opus 比率削減を目標としない」運用は月次リミット超過を招いた。トークン予算を hard constraint として扱い、Plan / code-reviewer のデフォルトを Sonnet にした。
