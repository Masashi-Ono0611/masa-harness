#!/usr/bin/env python3
"""PreToolUse hook: enforce worktree-first work on protected branches.

Fires on Edit/Write. In a git repo, checks the CURRENT BRANCH. If we are
on a PROTECTED branch (main/master/staging/... or the repo's detected
default) and NOT already inside a linked worktree, blocks once so the
agent must decide:

  - independent task -> propose `git worktree add` to the user. This is
    the default: cut a worktree even for a single task, not only when
    2+ tasks run in parallel.
  - continuation of pending work / minor config edit -> retry the Edit
    (the marker is set when we block, so the hook stays silent for the
    rest of the session for this repo).

The per-(session, repo) marker is consumed ONLY when we actually block
(on a protected branch). Skipped paths (feature branch, detached HEAD,
linked worktree) do NOT touch it, so an early edit off a protected branch
can never make a later protected-branch edit false-pass.

This is the enforcement layer that makes "worktree-first" the default
across all repos without touching any per-repo skill -- a skill only
fires when invoked, so the enforcement ("it just happens") has to live in
a hook. The flow itself lives in the worktree-pr-flow skill (generic
skeleton) and each repo's own *-pr-flow skill. See CLAUDE.md section
'parallel development' (parallel development).
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

# Working directly on one of these triggers the worktree prompt. The
# repo's detected default branch (origin/HEAD) is unioned in at runtime,
# so repos whose default is not in this literal set are still covered.
PROTECTED_BRANCHES = {
    "main", "master", "staging", "develop", "development",
    "production", "prod", "release", "trunk",
}


def git(repo_dir: Path, args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_dir)] + args,
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except Exception:
        return ""


def find_repo_root(start: Path) -> Path | None:
    cur = start if start.is_dir() else start.parent
    while cur != cur.parent:
        if (cur / ".git").exists():
            return cur
        cur = cur.parent
    return None


def default_branch(repo_dir: Path) -> str:
    # origin/HEAD -> "origin/main" -> "main"; "" if not resolvable
    ref = git(repo_dir, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
    return ref.split("/", 1)[1] if "/" in ref else ""


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    if data.get("tool_name") not in ("Edit", "Write"):
        return 0

    file_path = data.get("tool_input", {}).get("file_path", "")
    if not file_path:
        return 0

    repo_dir = find_repo_root(Path(file_path))
    if repo_dir is None:
        return 0

    session_id = data.get("session_id", "default")
    repo_hash = hashlib.md5(str(repo_dir).encode()).hexdigest()[:8]
    marker = Path(f"/tmp/claude-worktree-check-{session_id}-{repo_hash}")
    if marker.exists():
        return 0

    if not git(repo_dir, ["rev-parse", "--is-inside-work-tree"]):
        marker.touch()
        return 0

    # Linked-worktree detection via common-dir comparison (path-name independent)
    git_dir = git(repo_dir, ["rev-parse", "--path-format=absolute", "--git-dir"])
    git_common = git(repo_dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    in_linked_worktree = bool(git_dir) and bool(git_common) and git_dir != git_common
    branch = git(repo_dir, ["branch", "--show-current"])

    # Skip without consuming marker -- a skipped edit must not let a later
    # protected-branch edit false-pass.
    if in_linked_worktree or not branch:
        return 0
    d = default_branch(repo_dir)
    protected = PROTECTED_BRANCHES | ({d} if d else set())
    if branch not in protected:
        return 0

    # Protected branch: consume marker now then block.
    pending = git(repo_dir, ["status", "-s"])
    stashes = git(repo_dir, ["stash", "list"])
    marker.touch()

    slug = "<slug>"
    msg = [
        "WORKTREE CHECK -- editing on a protected branch (once per repo/session):",
        f"  Repo: {repo_dir}",
        f"  Branch: {branch} (protected)",
    ]
    if pending:
        msg.append(f"  Pending changes:\n{pending}")
    if stashes:
        msg.append(f"  Stashes:\n{stashes}")
    msg.append(
        "\nPolicy: cut a worktree even for a single task on a protected branch.\n"
        "  - independent work -> create a worktree (then work inside it):\n"
        f"      git worktree add ../{repo_dir.name}-{slug} -b feat/{slug} origin/{branch}\n"
        f"      (no origin/{branch}? use the local branch as base instead)\n"
        "  - continuation / minor config edit -> just retry the Edit (marker set, hook skips)\n"
        "Flow: worktree-pr-flow skill (generic) / <repo>-pr-flow skill (per-repo).\n"
        "Reference: CLAUDE.md parallel-development section."
    )
    sys.stderr.write("\n".join(msg) + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
