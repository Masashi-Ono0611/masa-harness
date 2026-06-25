#!/usr/bin/env python3
"""PreToolUse hook: detect potential parallel work, suggest worktree.

Fires on Edit/Write. On first invocation per (session, repo) in a git
repo, checks git state. If uncommitted changes or stashes exist (and we
are NOT already inside a linked worktree), blocks once with a warning so
Claude must decide: continuation work (proceed) vs independent task
(propose `git worktree add` to user).
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path


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

    git_dir = git(repo_dir, ["rev-parse", "--git-dir"])
    in_linked_worktree = "/worktrees/" in git_dir

    pending = git(repo_dir, ["status", "-s"])
    stashes = git(repo_dir, ["stash", "list"])
    branch = git(repo_dir, ["branch", "--show-current"])

    marker.touch()

    if in_linked_worktree:
        return 0
    if not pending and not stashes:
        return 0

    msg = [
        "PARALLEL WORK CHECK - worktree decision needed (one-time per repo per session):",
        f"  Repo: {repo_dir}",
        f"  Branch: {branch}",
    ]
    if pending:
        msg.append(f"  Pending changes:\n{pending}")
    if stashes:
        msg.append(f"  Stashes:\n{stashes}")
    msg.append(
        "\nDecide:\n"
        "  - If new edit RELATES to pending work above -> retry the Edit (marker now set, hook skips)\n"
        "  - If new edit is INDEPENDENT -> ask user about worktree:\n"
        "      git worktree add ../<repo>-<feature> -b feat/<feature>\n"
        "Reference: CLAUDE.md '並列開発' (parallel development) section."
    )
    sys.stderr.write("\n".join(msg) + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
