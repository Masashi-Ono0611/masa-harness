---
name: worktree-pr-flow
description: |-
  Generic skeleton for worktree-first PR flow. When starting work on a protected branch, cuts a
  worktree then runs: implement → verify → multi-model review → PR → cleanup.
  Default flow for repos that don't have a repo-specific *-pr-flow skill yet.
  Triggered by "cut worktree", "worktree PR flow", "start work on main", or when the
  worktree-trigger hook detects a protected-branch edit and prompts this flow.
  Per-repo skills (<repo>-pr-flow) take precedence when they exist; this is the fallback / template.
updated_at: 2026-06-26
---

# Worktree-first PR Flow (Generic Skeleton)

**Policy**: on a protected branch (main/master/staging/trunk etc.), cut a worktree even for a
single task — not only when 2+ parallel tasks exist. This is the "jedi-style" default enforced
by the `worktree-trigger` hook. The hook is the enforcement layer ("it just happens"); this skill
is the flow layer ("here's how").

## Step Overview (6 stages)

| Step | Content | Required | Notes |
|---|---|---|---|
| 0 | Create worktree (auto-detect base) | ✅ | On protected-branch start. Skip for continuations / minor config edits |
| 1 | Implement inside worktree | ✅ | `.env` is not inherited — reference main checkout |
| 2 | Verify (test / build / lint) | ✅ | Goal-driven: success criterion first |
| 3 | Multi-model review | ✅ | `/review:self-multi-model --base <base>` |
| 4 | Create PR | ✅ | Target base branch. No direct push |
| 5 | Cleanup (worktree remove + branch) | ✅ | After merge |

## Constants

| Name | Value |
|---|---|
| Worktree path | `../<repo>-<slug>` (sibling dir of main checkout) |
| Branch naming | `feat/<slug>` (fix/chore also fine) |
| Base detection | Protected branch you started from: `origin/<current>` (fallback: local `<current>`) |
| Review command | `/review:self-multi-model --base <base>` |
| Enforcement hook | `~/.claude/hooks/worktree-trigger.py` |

## Responsibility Matrix (no overlap)

| Task | This skill | `<repo>-pr-flow` (per-repo) |
|---|---|---|
| Per-repo custom flow (board integration, staging base, etc.) | ❌ delegate | ✅ |
| Generic worktree + PR flow | ✅ | ❌ |
| Enforcement (protected-branch detection) | ❌ hook's job | ❌ hook's job |

When a repo accumulates enough repo-specific steps (different base branch, issue board wiring,
custom review command, multi-env deploy gates), create `<repo>-pr-flow` using this skill as the
starting template and retire this fallback for that repo.

> **Container directories** (a parent dir holding multiple independent repos, each with its own
> `.git`): cut a worktree *per sub-repo*, not for the container dir itself. The hook's
> `find_repo_root()` detects the correct `.git` boundary automatically — no extra config needed.
> Parallel work across *different* sub-repos doesn't need worktrees (they're already in separate
> directories).

## When to Use / Skip Conditions

**Trigger**: any repo without its own `*-pr-flow`, when on a protected branch (hook-prompted or
explicit request).

**Skip**:
- Already on a feature branch / inside a linked worktree (isolation in place)
- Continuing pending work or a minor config edit (retry the Edit — the hook marker is set, so it
  won't fire again this session for this repo)
- Parallel work across *different* repos (directory isolation is sufficient, no worktree needed)

## Implementation Steps

### Step 0: Create worktree

**Purpose**: physically isolate protected-branch work to prevent direct commits to main.
**Condition**: on a protected branch, independent new task. Skip for continuations / minor edits.
**Action**:
```bash
SLUG="<short-kebab>"                             # short identifier for the task
BASE_BRANCH=$(git branch --show-current)         # the protected branch you're starting from
BASE_REF="origin/${BASE_BRANCH}"
git rev-parse --verify --quiet "$BASE_REF" >/dev/null || BASE_REF="$BASE_BRANCH"  # fallback: local branch
REPO=$(basename "$(git rev-parse --show-toplevel)")
git worktree add "../${REPO}-${SLUG}" -b "feat/${SLUG}" "$BASE_REF"
cd "../${REPO}-${SLUG}"
```
> Base = the protected branch you *started from* (matches the hook's suggestion). If you start
> from `main`, base is `main`; from `staging`, base is `staging`. Don't hardcode `origin/HEAD`.

**Done when**: `git rev-parse --git-dir` differs from `--git-common-dir` (you're in a linked worktree).

### Step 1: Implement

**Purpose**: make the minimum change to fulfil the task (Simplicity / Surgical).
**Condition**: Step 0 complete (inside worktree).
**Action**: implement. Note — **worktrees do not inherit `.env` / `.venv` / `node_modules`**:
- `.venv` / `node_modules`: regenerated automatically by `uv run` / `pnpm install`.
- `.env` (secrets): reference the main checkout — e.g. `uv run --env-file <main>/.env ...`. Never
  expose secret values in shell args; resolve inside the script/config file.

**Done when**: every changed line traces directly to the task requirements.

### Step 2: Verify

**Purpose**: convert "I fixed it" to "the test / build passes" (Goal-Driven).
**Condition**: implementation done.
**Action**: run the repo's test/build/lint (`uv run pytest` / `pnpm test` / `forge test` etc.).
**Done when**: verification is green. If not, return to Step 1 — don't move forward unverified.

### Step 3: Multi-model Review

**Purpose**: second-model quality gate before PR.
**Condition**: verification green.
**Action**: run `/review:self-multi-model --base <BASE_BRANCH>`, fix Critical/Warning items.
**Done when**: Critical = 0 (fixed or explicitly accepted with rationale).

### Step 4: Create PR

**Purpose**: open a PR to the base branch (no direct push).
**Condition**: Critical issues resolved.
**Action**: split commits by logical unit → push → `gh pr create --base <base> --body ...`
(non-interactive). If multiple remotes are ambiguous, confirm which remote before pushing.
**Done when**: PR is open and CI is running.

### Step 5: Cleanup

**Purpose**: remove worktree and branch after merge — no stale worktrees.
**Condition**: PR is merged.
**Action**:
```bash
cd <main checkout>
git worktree remove "../${REPO}-${SLUG}"
git worktree list                # confirm only main checkout remains
git branch -D "feat/${SLUG}"    # squash merge: --merged won't detect it, check PR state=MERGED
```
**Done when**: `git worktree list` shows only the main checkout.

## Constraints

### Errors (fatal)
| Pattern | Preferred | Reason |
|---|---|---|
| Direct commit/push on protected branch | Step 0: cut worktree + branch | Bypasses the no-direct-push policy; worktree makes it structurally impossible [E1] |
| Skip verification because `.env` is missing in worktree | Reference main checkout `.env` | "No env" is not a valid reason to skip verification [E2] |
| Reporting done before verification is green | Step 2 as gate, fail-fast | Unverified work must not be marked done (Goal-Driven) |

### Warnings
| Pattern | Preferred | Reason |
|---|---|---|
| Using this skill for a repo with its own `*-pr-flow` | Use the per-repo skill | Per-repo SoT wins; this is fallback |
| Deleting branch with `git branch --merged` | Check PR state=MERGED | Squash merges are not detected by `--merged` [E3] |
| Placing worktree inside the main checkout dir | `../<repo>-<slug>` (sibling) | Git / some tools misidentify it as part of the main repo |

## Related Skills
- `/review:self-multi-model` — Step 3 delegates to this command
- `worktree-trigger` hook — enforcement layer (`~/.claude/hooks/worktree-trigger.py`)
- Per-repo `*-pr-flow` skills — repo-specific variants that supersede this skeleton for their repos

## Evidence Index
| ID | Source | Learning |
|---|---|---|
| E1 | CLAUDE.md §common-rules (no-direct-push reflex) | Protected-branch edits: worktree = structural enforcement of no-direct-push |
| E2 | CLAUDE.md parallel-development, `.env` inheritance note | Worktrees don't inherit gitignored files; reference main checkout instead |
| E3 | Common git pitfall | Squash merges don't appear in `git branch --merged`; use PR state |
