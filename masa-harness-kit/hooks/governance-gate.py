#!/usr/bin/env python3
"""User-level PreToolUse governance gate.

責任領域 (governance / IAM / branch protection / release / repo policy)
＋ durable-state risk (破壊 / global-system / Claude 動作環境 / secrets / vendor)
に触れる操作を AI が無断で実行することを防ぐ user-level hook。

3 挙動に分岐:
    * BLOCK   (exit 2): 破壊 / global-system / Claude 動作環境 / secrets
    * LOG     (exit 0 + ops log append): 可逆だが team 可視な governance mutation
    * ALLOW   (exit 0): それ以外
  Edit/Write/MultiEdit も対象に追加 (settings.json / .env 等への書き込みを BLOCK)。

入力: stdin に Claude Code から JSON
    {"tool_name": "Bash", "tool_input": {"command": "..."}, ...}
    {"tool_name": "Edit", "tool_input": {"file_path": "..."}, ...}

出力 (Claude Code の hook exit code 規約):
    exit 0: 許可 (LOG 該当時は ops log へ1行 append してから許可)
    exit 2: ブロック (stderr の内容を Claude にフィードバックして再考させる)
    ※ PreToolUse をブロックできるのは exit 2 のみ。exit 1 や他の非ゼロは
       ブロックにならず素通りする (Unix の慣習と逆)。この hook を改変するときは注意。

設計方針:
- Bash / Edit / Write / MultiEdit を対象。それ以外は素通し
- パターンは慎重に絞り、誤検知で生産性を落とさない
- override: 本人が手動実行 / hook の PreToolUse を一時 off
- ログ書き込みは失敗しても作業を止めない (best-effort)

"""
from __future__ import annotations

import datetime
import json
import os
import re
import shlex
import sys
from collections.abc import Callable
from dataclasses import dataclass

OPS_LOG_PATH = os.environ.get(
    "OPS_LOG_PATH", os.path.expanduser("~/.claude/state/ops-governance-log.md")
)
BLOCK_LOG_PATH = os.environ.get(
    "BLOCK_LOG_PATH", os.path.expanduser("~/.claude/state/governance-blocks.log")
)

# 保護対象 branch / 本番 workflow は環境ごとに異なるため env で上書き可能にする。
# 各自の環境に合わせて GATE_PROTECTED_BRANCHES / GATE_PROD_WORKFLOWS を設定する
# (`|` 区切りの正規表現 alternation。既定は一般的な命名)。
def _safe_alternation(env_key: str, default: str) -> str:
    """env で上書き可能な regex alternation を返す。値が壊れた regex なら既定に
    フォールバックする (import 時に re.compile が例外を投げて hook ごと crash →
    PreToolUse が素通り = fail-open するのを防ぐ・codex 指摘)。"""
    val = os.environ.get(env_key, default)
    try:
        re.compile(val)
    except re.error:
        sys.stderr.write(
            f"[governance-gate] {env_key} の正規表現が不正です。既定値にフォールバックします。\n"
        )
        return default
    return val


PROTECTED_BRANCHES = _safe_alternation(
    "GATE_PROTECTED_BRANCHES", "main|master|staging|production|prod"
)
PROD_WORKFLOWS = _safe_alternation(
    "GATE_PROD_WORKFLOWS", "release-production|prod-deploy|terraform-apply-prod"
)


@dataclass
class Rule:
    name: str
    pattern: re.Pattern
    why: str
    instead: str
    # 任意: pattern が match しても True を返したら BLOCK を見送る (safe-target allowlist 等)
    allow_if: "Callable[[str], bool] | None" = None


@dataclass
class LogRule:
    name: str
    pattern: re.Pattern
    note: str


@dataclass
class AskRule:
    name: str
    pattern: re.Pattern
    reason: str


# ---------------------------------------------------------------------------
# destructive-rm safe-target allowlist (2026-06-08 fix)
# `rm -rf` の target が全て「再生成可能な ephemeral dir / tmp 配下」なら BLOCK を
# 見送る。node_modules / dist 等の日常的削除で gate が止まる摩擦を解消しつつ、
# $HOME / tmp 以外の絶対パス / .. / 変数展開 / glob 等の危険 target は従来通りブロック。
# ---------------------------------------------------------------------------
SAFE_RM_BASENAMES = {
    "node_modules", "dist", "build", "out", "target",
    ".next", ".nuxt", ".svelte-kit", ".turbo", ".vite", ".parcel-cache",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    "coverage", ".cache", ".venv", "venv",
}
SAFE_RM_PREFIXES = (
    "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/",
)


def _is_safe_rm_target(t: str) -> bool:
    """単一 rm target が『再生成可能 ephemeral』なら True。"""
    if not t or t in ("/", "~", "..", ".", "./", "*", "$HOME", "${HOME}"):
        return False
    if t[0] in "~$":  # ~ / ~/... / $HOME / 変数展開先は不明 → 危険扱い
        return False
    segs = t.split("/")
    # `..` での上位 escape と glob は absolute / tmp 配下を含め全 target で拒否。
    # 例: `/tmp/../etc` は prefix だけ見ると /tmp 配下に見えるが実体は /etc (codex 指摘)。
    if ".." in segs or any(("*" in s or "?" in s) for s in segs):
        return False
    if t.startswith(SAFE_RM_PREFIXES):
        return True
    if t.startswith("/"):  # tmp 以外の絶対パス → 危険扱い
        return False
    parts = [p for p in segs if p not in ("", ".")]
    if not parts:
        return False
    return parts[-1] in SAFE_RM_BASENAMES


def _rm_all_targets_safe(command: str) -> bool:
    """command 内の全 rm invocation の全 target が safe なら True (= BLOCK 見送り)。

    1 つでも未知/危険 target・parse 不能があれば False (= BLOCK 続行)。
    """
    saw_rm = False
    for seg in re.split(r"&&|\|\||[|;\n]", command):
        m = re.search(r"\brm\b(.*)$", seg.strip())
        if not m:
            continue
        saw_rm = True
        try:
            tokens = shlex.split(m.group(1))
        except ValueError:
            return False  # quote 不整合等は安全側に倒して BLOCK
        targets = [t for t in tokens if not t.startswith("-")]
        if not targets or not all(_is_safe_rm_target(t) for t in targets):
            return False
    return saw_rm


# ===========================================================================
# BLOCK rules (Bash) — exit 2
# ===========================================================================
RULES: list[Rule] = [
    # --- repo policy 変更 ---
    Rule(
        name="repo-policy-patch",
        pattern=re.compile(
            r"\bgh\s+api\s+(-X\s+)?(PATCH|DELETE)\s+repos/[^\s]+(?!.*\bsearch=)",
            re.IGNORECASE,
        ),
        why=(
            "repo settings (delete_branch_on_merge / allow_merge_commit / visibility 等) "
            "の変更は governance 領域。本人 sign-off が必要。"
        ),
        instead=(
            "1) どの設定を変えるか PR 本文 / Slack に書いて事前共有\n"
            "2) 本人が手動で `gh api -X PATCH ...` を叩く、または GitHub UI で設定変更\n"
            "3) 変更後に CONTRIBUTING.md / CHANGELOG.md を更新"
        ),
    ),
    # --- branch protection 変更 ---
    Rule(
        name="branch-protection",
        pattern=re.compile(
            r"\bgh\s+api\s+(-X\s+)?(PUT|PATCH|DELETE|POST)\s+[^\s]*branches?/[^\s]*/protection",
            re.IGNORECASE,
        ),
        why="branch protection 変更は production 経路への影響大、本人判断必須。",
        instead=(
            "1) 変更内容を Slack / GitHub Issue で事前合意\n"
            "2) 本人が手動で gh api または GitHub UI で設定変更"
        ),
    ),
    # --- IAM / permissions / collaborators ---
    Rule(
        name="iam-permissions",
        pattern=re.compile(
            r"\bgh\s+api\s+(-X\s+)?(PUT|PATCH|DELETE|POST)\s+repos/[^\s]+/(collaborators|teams|invitations)",
            re.IGNORECASE,
        ),
        why="collaborator / team / invitation 変更は権限境界に直結。本人最終判断。",
        instead="GitHub UI または本人が gh api を直接実行。",
    ),
    Rule(
        name="gcp-iam-binding",
        pattern=re.compile(
            r"\bgcloud\s+(projects|resource-manager)\s+(add|remove|set)-iam-policy-binding\b",
            re.IGNORECASE,
        ),
        why="GCP IAM binding は責任領域。AI が無断で role を付与/剥奪してはならない。",
        instead=(
            "1) 変更理由 + role + member を PR / Issue に書く\n"
            "2) 本人が承認後に gcloud を実行\n"
            "3) terraform 管理なら .tf 編集 → plan/apply のレビューフロー"
        ),
    ),
    # --- リリース作成 / publish (対外発信) ---
    Rule(
        name="release-create",
        pattern=re.compile(
            r"\bgh\s+release\s+(create|upload|delete)\b",
            re.IGNORECASE,
        ),
        why="リリース作成 / アセット公開は対外発信。本人最終判断。",
        instead=(
            "1) リリースノート / CHANGELOG を PR で merge\n"
            "2) 本人が手動で `gh release create` を実行"
        ),
    ),
    Rule(
        name="npm-publish",
        pattern=re.compile(
            r"\b(npm|pnpm|yarn)\s+publish\b",
            re.IGNORECASE,
        ),
        why="npm publish は対外公開・取り消し困難。本人最終判断。",
        instead="本人が手動で publish。version bump は PR / CHANGELOG で事前合意。",
    ),
    # --- 公開可視性切替 ---
    Rule(
        name="visibility-toggle",
        pattern=re.compile(
            r"\bgh\s+repo\s+edit\s+[^\n]*--visibility\b",
            re.IGNORECASE,
        ),
        why="リポジトリの公開/非公開切替は governance 領域。",
        instead="本人が GitHub UI または手動 gh コマンドで実行。",
    ),
    # --- secret 変更 ---
    Rule(
        name="secret-change",
        pattern=re.compile(
            r"\bgh\s+secret\s+(set|delete)\b",
            re.IGNORECASE,
        ),
        why="GitHub Actions secret の追加・削除は権限境界の変更。",
        instead="本人が手動で `gh secret set / delete` を実行。",
    ),
    # --- 大量 issue 操作 ---
    Rule(
        name="bulk-issue-close",
        pattern=re.compile(
            r"xargs[^|]*gh\s+issue\s+close|while\s+read[^;]*gh\s+issue\s+close",
            re.IGNORECASE,
        ),
        why="大量 issue close は本人 review なしには実行しない。",
        instead=(
            "1) close 候補リストを Slack / Issue に出す\n"
            "2) 本人が候補を選別\n"
            "3) 選別済リストを 1 件ずつ close"
        ),
    ),
    # --- prod デプロイ workflow trigger ---
    Rule(
        name="prod-workflow-dispatch",
        pattern=re.compile(
            rf"\bgh\s+workflow\s+run\s+[^\s]*({PROD_WORKFLOWS})",
            re.IGNORECASE,
        ),
        why="本番デプロイ workflow の手動 trigger は本人最終判断。",
        instead="本人が手動で `gh workflow run` を実行 or PR タグ push。",
    ),
    # --- force push to protected ---
    Rule(
        name="force-push-protected",
        pattern=re.compile(
            # force フラグと保護 branch を順序非依存で検知 (`git push origin main --force`
            # のように branch が force より前でも捕捉・codex 指摘)。
            rf"\bgit\s+push\b(?=.*(?:--force|--force-with-lease|-f\b))(?=.*\b(?:origin\s+)?(?:{PROTECTED_BRANCHES})\b)",
            re.IGNORECASE,
        ),
        why="保護対象 branch への force push は履歴破壊。",
        instead="本人が確認後に手動実行。または revert commit で対応。",
    ),
    # --- repo 削除 (不可逆) ---
    Rule(
        name="repo-delete",
        pattern=re.compile(
            r"\bgh\s+repo\s+delete\b",
            re.IGNORECASE,
        ),
        why="リポジトリ削除は不可逆。本人最終判断。",
        instead=(
            "1) 本当に削除か (archive で足りないか) を確認\n"
            "2) 本人が GitHub UI または手動 `gh repo delete` で実行"
        ),
    ),
    # --- 任意コード実行を伴うツール導入 (「ツール導入は事前確認」の機構化) ---
    # 2026-06-08: brew を除外。homebrew-core は curated・可逆・低リスクで日常頻度が高く、
    # ハードブロックは摩擦のみ。残す npm-g/yarn-g/pipx/gem/cargo/go は install/build 時に
    # postinstall・build.rs・setup.py 等が任意コードを実行する枠なので確認を維持。
    # (brew upgrade は別途 system-mutation 扱いで要確認 / milestone 等可逆操作はガードせず)
    Rule(
        name="global-pkg-install",
        pattern=re.compile(
            r"\b(?:npm|pnpm)\s+(?:i|install|add)\b[^\n]*\s(?:-g|--global)\b"
            r"|\byarn\s+global\s+add\b"
            r"|\bpipx\s+install\b"
            r"|\bgem\s+install\b"
            r"|\bcargo\s+install\b"
            r"|\bgo\s+install\b",
            re.IGNORECASE,
        ),
        why=(
            "任意コード実行を伴うツール導入 (global npm-pnpm / yarn global / pipx / "
            "gem / cargo / go install ＝ postinstall・build.rs・setup.py が走る) は "
            "本人確認必須。brew は除外済 (curated・可逆・低リスク, 2026-06-08)。"
        ),
        instead=(
            "1) なぜ要るか・外部サービス代替が無いかを提示\n"
            "2) 本人承認後に手動 install (oss-clone-security 該当なら先に scan)"
        ),
    ),
    # ===== durable-state risk 拡張 (BLOCK) =====
    # --- 破壊的: rm -rf / find -delete / pkg uninstall ---
    Rule(
        name="destructive-rm",
        # 短縮 recursive flag を任意位置で (-rf/-fr/-r/-Rf, `-v -rf`, `-f -r` も) ＋ 長形
        # `--recursive` を捕捉。force の有無は問わず recursive を危険とみなす (codex 指摘)。
        pattern=re.compile(
            r"\brm\s+(?:-\w+\s+)*-\w*r\w*"
            r"|\brm\s+(?:\S+\s+)*--recursive\b",
            re.IGNORECASE,
        ),
        why=(
            "`rm -rf` / `--recursive` は不可逆な再帰削除。誤指定で作業ツリー全消失の恐れ "
            "(node_modules / dist 等の再生成可能 dir・/tmp 配下は allowlist で通過)。"
        ),
        instead=(
            "1) 消す対象を `ls` で先に列挙して提示\n"
            "2) archive/ へ退避で足りないか検討\n"
            "3) 本人承認後に手動実行 (または対象を限定した個別 rm)"
        ),
        allow_if=_rm_all_targets_safe,
    ),
    Rule(
        name="find-delete",
        pattern=re.compile(r"\bfind\b[^\n]*\s-delete\b", re.IGNORECASE),
        why="`find ... -delete` は広域一括削除で不可逆。",
        instead="`-delete` を外して対象一覧を先に確認 → 本人承認後に実行。",
    ),
    # --- IaC destroy / 破壊的 git ---
    # 新しめの Claude Code は auto mode で IaC destroy / 破壊的 git を native ブロック
    # するが、これは CC version 依存。この hook にも入れて version 非依存の belt にする
    # (gate は AI の無断実行のみ止める=本人は `!` で手動実行可)。
    Rule(
        name="iac-destroy",
        pattern=re.compile(
            r"\b(?:terraform|tofu|terragrunt)\s+(?:-\S+\s+)*destroy\b"   # `terraform destroy`
            r"|\b(?:terraform|tofu|terragrunt)\b[^\n|;&]*\s-{1,2}destroy\b"  # `apply -destroy` flag 形
            r"|\bpulumi\s+(?:-\S+\s+)*destroy\b"
            r"|\bcdk(?:tf)?\s+(?:-\S+\s+)*destroy\b",
            re.IGNORECASE,
        ),
        why="IaC destroy (terraform/tofu/pulumi/cdk) は infra の不可逆破棄。本人最終判断。",
        instead=(
            "1) 破棄対象を `terraform plan -destroy` 等で先に提示\n"
            "2) 本当に destroy か (環境取り違えがないか) を確認\n"
            "3) 本人が承認後に手動実行"
        ),
    ),
    Rule(
        name="destructive-git",
        pattern=re.compile(
            r"\bgit\b(?:\s+-\S+)*\s+reset\b(?=[^\n]*--hard)"   # `git reset --hard`
            r"|\bgit\s+clean\b(?=[^\n]*\s-\w*f)"               # `git clean -f...` (force=実削除)
            r"|\bgit\s+stash\s+(?:drop|clear)\b",              # stash の破棄
            re.IGNORECASE,
        ),
        why=(
            "`git reset --hard` / `git clean -f` / `git stash drop|clear` は uncommitted "
            "/ untracked / stash を不可逆破棄 (reflog で戻らないものを含む)。AI の無断実行で "
            "作業中の変更が消える恐れ。"
        ),
        instead=(
            "1) 破棄される変更を `git status` / `git stash list` で先に提示\n"
            "2) 退避 (commit / stash / 別 branch) で足りないか検討\n"
            "3) 本人が承認後に手動実行 (`!` で本人実行は通る)"
        ),
    ),
    Rule(
        name="gh-api-delete",
        pattern=re.compile(r"\bgh\s+api\b[^\n]*-X\s+DELETE\b", re.IGNORECASE),
        why="`gh api -X DELETE` は GitHub 側 state の不可逆削除。本人最終判断。",
        instead="削除対象を提示 → 本人が手動実行 or UI で操作。",
    ),
    Rule(
        name="pkg-uninstall",
        pattern=re.compile(
            r"\b(?:npm|pnpm)\s+(?:uninstall|remove|rm)\b[^\n]*\s(?:-g|--global)\b"
            r"|\byarn\s+global\s+remove\b",
            re.IGNORECASE,
        ),
        why=(
            "global ツールの削除は他作業へ波及しうる環境変更。本人確認。"
            "brew uninstall は除外済 (可逆・install と対称, 2026-06-08)。"
        ),
        instead="影響範囲を提示 → 本人承認後に手動 uninstall。",
    ),
    # --- global / system mutation ---
    Rule(
        name="system-mutation",
        pattern=re.compile(
            r"\bbrew\s+upgrade\b"
            r"|\bsudo\s+pmset\b"
            r"|\blaunchctl\s+(load|unload|bootstrap|bootout|enable|disable)\b"
            r"|\bdefaults\s+write\b"
            r"|\btccutil\s+reset\b",
            re.IGNORECASE,
        ),
        why="macOS / system 設定 (launchd / defaults / TCC 権限 / 電源) の変更は環境全体に波及。本人最終判断。",
        instead="変更内容と理由を提示 → 本人が手動実行。",
    ),
    # --- MCP / plugin 変更 (Claude 動作環境) ---
    Rule(
        name="mcp-plugin-change",
        pattern=re.compile(
            r"\bclaude\s+mcp\s+(add|remove|delete|add-json)\b"
            r"|\bclaude\s+plugin\s+(enable|disable|install|uninstall|remove)\b",
            re.IGNORECASE,
        ),
        why="MCP server / plugin の追加・削除・有効化は Claude 動作環境の変更。orphaned permission を残す恐れ。本人確認。",
        instead="変更内容を提示 → 本人が手動で `claude mcp/plugin ...` を実行。",
    ),
    # --- auth / credential 操作 ---
    # 2026-06-08: gcloud は state を変える login/revoke/activate-service-account のみ
    # (global flag が auth の前に来ても捕捉・codex 指摘)。`application-default
    # set-quota-project`(config) / `print-access-token`(read) は state 不変なので通す
    # (set-quota-project は settings allow にも在る)。
    Rule(
        name="auth-change",
        pattern=re.compile(
            r"\bgh\s+auth\s+(login|logout|refresh|token|setup-git)\b"
            r"|\bgcloud\s+(?:-{1,2}\S+\s+)*auth\s+(?:application-default\s+)?(?:login|revoke|activate-service-account)\b",
            re.IGNORECASE,
        ),
        why="認証 state (gh / gcloud) の変更は account-sensitive。本人最終判断。",
        instead="本人が手動で auth 操作を実行。",
    ),
    # --- 保護対象 config / secrets への shell 経由 *書き込み* ---
    # 2026-06-08: 旧 pattern は redirect と path の間に任意 gap (`[^\n]*`) を許し、
    # `.env` / `settings.json` に言及するだけの read (cat/ls/grep) を誤検知していた。
    # → write のみに限定: redirect/tee/sed-i token に target が *隣接* する時だけ match。
    #   gap を消したので `cat .env 2>/dev/null` 等の read は通る (lookbehind は不要かつ
    #   `1>`/`&>` の write を取りこぼすので撤去・codex 指摘)。`>|`/`>&` も捕捉。
    #   CLAUDE.md / recurring-tasks.json は 2026-06-06 dial-back で対象外。
    # NOTE: これは best-effort の速度制限であって sandbox ではない。`cp`/`mv`/`dd`/
    #   `python -c open(w)` 等の任意 write primitive・tee 複数 target は捕捉しない。
    #   settings.json / 実 .env の最終防波堤は下の PROTECTED_WRITE_PATTERNS (Edit/Write)。
    Rule(
        name="config-write-via-shell",
        pattern=re.compile(
            r"(?:>>?[&|]?\s*|\btee\s+(?:-a\s+)?|\bsed\s+(?:-\S+\s+)*-i\b[^|;&\n]*?\s)"
            r"['\"]?[^\s'\"|;&]*"
            r"(?:\.env(?!\.(?:example|sample|template|dist)\b)(?:\.[\w-]+)?"
            r"|\.claude/settings(?:\.local)?\.json)",
            re.IGNORECASE,
        ),
        why=(
            "settings.json / .env への shell 書き込みは Claude 動作環境・secrets の "
            "durable 変更。読み取り (cat/ls/grep) は対象外、書き込み (> / >> / tee / "
            "sed -i) のみブロック (Cycle 0.1 / 2026-06-08 誤検知修正)。"
        ),
        instead="Edit ツールで差分を提示 → 本人承認、または本人が手動編集。",
    ),
]


# ===========================================================================
# LOG rules (Bash) — exit 0 + ops log append (可逆だが team/public 可視)
# ===========================================================================
LOG_RULES: list[LogRule] = [
    LogRule(
        name="gh-milestone-move",
        pattern=re.compile(r"\bgh\s+issue\s+edit\b[^\n]*--milestone\b", re.IGNORECASE),
        note="milestone 付替 (reversible)",
    ),
    LogRule(
        name="gh-pr-edit",
        pattern=re.compile(r"\bgh\s+pr\s+edit\b", re.IGNORECASE),
        note="PR メタ編集 (reversible)",
    ),
    LogRule(
        name="gh-label",
        pattern=re.compile(r"\bgh\s+label\s+(create|delete|edit|clone)\b", re.IGNORECASE),
        note="label 操作 (reversible)",
    ),
    LogRule(
        name="gh-project-edit",
        pattern=re.compile(
            r"\bgh\s+project\s+(item-edit|item-add|item-archive|edit)\b", re.IGNORECASE
        ),
        note="project board 操作 (reversible)",
    ),
    LogRule(
        name="gh-api-write",
        pattern=re.compile(
            r"\bgh\s+api\b[^\n]*-X\s+(PATCH|POST|PUT)\b[^\n]*(issues|projects|labels|milestones)",
            re.IGNORECASE,
        ),
        note="gh api 書き込み (issues/projects, reversible)",
    ),
]


# ===========================================================================
# ASK rules (Bash) — exit 0 + PreToolUse permissionDecision:ask
# 暴発防止の「使用確認」ゲート: 破壊的ではないが課金/重いコマンドを、実行直前に
# 毎回ユーザー確認させる (BLOCK と違い、承認すれば実行できる)。
# 例: 従量課金の重い CLI を実行直前に確認したい場合、ここに AskRule を足す。
# ===========================================================================
ASK_RULES: list[AskRule] = [
    # 例 (必要に応じて各自で追加):
    # AskRule(
    #     name="costly-llm-cli",
    #     pattern=re.compile(r"\bsome-paid-cli\b", re.IGNORECASE),
    #     reason="従量課金コマンド。意図した実行か実行前に確認。",
    # ),
]


# ===========================================================================
# Edit/Write 保護パス (Claude 動作環境 / secrets / vendor) — exit 2
# ===========================================================================
PROTECTED_WRITE_PATTERNS: list[tuple[str, re.Pattern]] = [
    ("claude-settings", re.compile(r"/\.claude/settings(\.local)?\.json$")),
    # 2026-06-06 dial-back (試験フィードバック): 摩擦の大きい以下は allowlist (BLOCK しない)。
    #   - CLAUDE.md: 日常的に育てる資産で委譲編集が多い。変更頻度低・影響大の settings.json のみ残す。
    #   - recurring-tasks.json: last_run 更新等で頻繁に触る低 blast-radius registry。
    # 2026-06-08: allow `.env.example`/`.sample`/`.template`/`.dist` (templates, no secrets);
    # real `.env` / `.env.local` / `.env.production` etc. stay protected.
    ("env-secrets", re.compile(r"\.env(?!\.(?:example|sample|template|dist)$)(\.|$)|accessKeys|/credentials(\.|$)|/\.aws/credentials")),
]


def _append_ops_log(category: str, summary: str, session_id: str) -> None:
    """LOG tier: 可逆だが可視な mutation を ops log に1行 append (best-effort)。"""
    try:
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        clean = summary.replace("\n", " ").replace("|", "/")[:120]
        newfile = not os.path.exists(OPS_LOG_PATH)
        os.makedirs(os.path.dirname(OPS_LOG_PATH), exist_ok=True)
        with open(OPS_LOG_PATH, "a", encoding="utf-8") as f:
            if newfile:
                f.write(
                    "# ops governance log\n\n"
                    "LOG tier: 可逆だが team/public 可視な "
                    "governance mutation を block せず記録 (stop でなく append)。\n\n"
                    "| Date | Category | Summary | Reversible | Session |\n"
                    "|---|---|---|---|---|\n"
                )
            f.write(f"| {ts} | {category} | {clean} | reversible | {session_id} |\n")
    except Exception:
        pass  # ログは絶対に作業を止めない


def _append_block_log(rule: str, target: str, session_id: str) -> None:
    """BLOCK tier: guard が止めた回数を記録（週次先行指標 / best-effort）。"""
    try:
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        clean = target.replace("\n", " ")[:160]
        os.makedirs(os.path.dirname(BLOCK_LOG_PATH), exist_ok=True)
        with open(BLOCK_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{ts}\t{rule}\t{session_id}\t{clean}\n")
    except Exception:
        pass


def _emit_ask(reason: str) -> None:
    """ASK tier: PreToolUse の permissionDecision:ask を stdout に JSON 出力。
    exit 0 で返すと Claude Code が実行前に許可プロンプトを出す (承認すれば実行可)。
    BLOCK (exit 2) と違い、暴発防止しつつ意図した実行は1クリックで通せる。"""
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    sys.stdout.write("\n")


def _emit_block(title: str, ident: str, why: str, instead: str) -> None:
    sys.stderr.write(
        f"\n🛑 GOVERNANCE GATE — operation blocked\n"
        f"\n"
        f"Rule: {title}\n"
        f"Target: {ident}\n"
        f"\n"
        f"Why blocked:\n  {why}\n"
        f"\n"
        f"What to do instead:\n  {instead}\n"
        f"\n"
        f"Reference: ~/.claude/hooks/governance-gate.py\n"
        f"\n"
        f"If this is a false positive, the user can:\n"
        f"  - run / edit it manually in their own terminal/editor\n"
        f"  - or temporarily disable this hook by commenting out the\n"
        f"    PreToolUse entry in ~/.claude/settings.json\n"
    )


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0  # parse 不能なら素通し (hook が壊れて作業を止めない)

    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input") or {}
    session_id = payload.get("session_id") or payload.get("session") or "-"

    # --- Bash: BLOCK rules → LOG rules → allow ---
    if tool == "Bash":
        command = tool_input.get("command", "")
        if not command:
            return 0
        for rule in RULES:
            if rule.pattern.search(command):
                if rule.allow_if and rule.allow_if(command):
                    continue  # safe-target allowlist 等で BLOCK 見送り
                snippet = command[:200] + ("..." if len(command) > 200 else "")
                _append_block_log(rule.name, command, session_id)
                _emit_block(rule.name, snippet, rule.why, rule.instead)
                return 2
        for ar in ASK_RULES:
            if ar.pattern.search(command):
                _emit_ask(ar.reason)
                return 0  # ask → Claude Code が実行前に許可プロンプトを表示
        for lr in LOG_RULES:
            if lr.pattern.search(command):
                _append_ops_log(lr.name, f"{lr.note}: {command}", session_id)
                return 0  # 可逆 → 記録のみで許可
        return 0

    # --- Edit/Write/MultiEdit: 保護パスへの書き込みを BLOCK ---
    if tool in ("Edit", "Write", "MultiEdit"):
        path = tool_input.get("file_path", "") or ""
        if not path:
            return 0
        for name, pat in PROTECTED_WRITE_PATTERNS:
            if pat.search(path):
                _append_block_log(f"protected-write:{name}", path, session_id)
                _emit_block(
                    f"protected-write:{name}",
                    path,
                    "Claude 動作環境 / secrets 所有ファイルへの書き込みは "
                    "durable-state 変更。弱い承認での無断変更を防ぐ。",
                    "差分を提示して本人承認を得る、または本人が手動で編集する。\n"
                    "  恒久的に許可したい path なら governance-gate.py の "
                    "PROTECTED_WRITE_PATTERNS から外す。",
                )
                return 2
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
