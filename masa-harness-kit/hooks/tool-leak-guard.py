#!/usr/bin/env python3
"""Stop hook: detect leaked tool-call markup and force self-correction (up to N retries).

Background (2026-06-20):
  Claude Code has a known intermittent bug (anthropics/claude-code #64690 names
  Opus 4.8, plus #60584/#63870/#64108/#66400/#68354) where the ``antml:`` namespace
  prefix on a tool call gets dropped/garbled during generation. The parser then no
  longer recognizes the block as a tool call and renders the raw ``<invoke>`` /
  ``<parameter>`` markup to the user as plain text. The turn ends with NO tool_use
  produced, so a PreToolUse hook cannot catch it (there is no parsed call).

  The documented trigger that makes this far more likely: putting long explanatory
  prose *before* the tool call, in long / many-turn contexts.

What this hook does:
  Fires on Stop. Reads the transcript tail. If the most recent assistant message
  carries the leak signature (``<invoke>``+``<parameter>`` or ``<function_calls>`` as
  raw text) AND produced zero real tool_use blocks, it returns decision=block with the
  corrective workaround. It will do so for UP TO ``MAX_RETRIES`` consecutive leaks in
  the same incident, then give up so the session is never stuck in a block loop.

Loop guard (why this does NOT rely on ``stop_hook_active``):
  ``stop_hook_active`` is a boolean — it can only express "we already blocked once",
  which caps retries at 1. To allow N retries we instead COUNT the leaked assistant
  messages in the current incident:
    * An "incident" is the run of assistant turns since the last GENUINE user prompt
      (a real typed prompt, ``isMeta`` not True — NOT a tool_result, NOT a system-meta
      message, NOT our own injected block reason). Every turn-end (clean or given-up)
      returns control to the user, so a genuine prompt separates one incident from the next.
    * Each re-leak appends exactly one leaked assistant message, so the count strictly
      increases per retry and is hard-capped at MAX_RETRIES -> no infinite loop.
    * Intermediate CLEAN tool_use turns inside a retry do NOT reset the count (we break
      only on a genuine user prompt, not on a clean assistant turn), which prevents the
      "partial success then re-leak" case from resetting the counter and looping.
  Interaction with Claude Code's built-in recovery (confirmed from real transcripts):
    Claude Code already auto-retries a malformed/leaked tool call *mid-turn* by injecting
    a ``user`` message with ``isMeta=True`` and text "Your tool call was malformed and
    could not be parsed". Those meta messages are interleaved between leaked assistant
    turns, so they MUST be excluded from the genuine-prompt boundary (via the ``isMeta``
    check) — otherwise they reset the counter every retry and the cap never bites. This
    hook is the backstop for the case the built-in retry does NOT cover: the turn *ends*
    while leaked (next entry is a ``system`` stop, not a malformed-retry meta message).
  A second, generous absolute cap (``ABS_CAP`` leaked turns anywhere in the tail) is a
  paranoia backstop against pathological transcript shapes.

Safety:
  - Any error / missing transcript -> exit 0 silently (never breaks the session).
  - Only stdout carries the decision JSON; diagnostics go to stderr.

This is a SAFETY NET + auto-correct, not a root-cause fix. The real fix is upstream
(keep Claude Code updated) plus the behavioral reflex (tool-call-first, no preamble).
"""

from __future__ import annotations

import json
import re
import sys

# Block at most this many times for one leak incident, then give up (manual promote).
MAX_RETRIES = 5

# Absolute paranoia backstop: if this many leaked assistant turns appear anywhere in
# the tail, stop blocking regardless of incident accounting. Far above MAX_RETRIES so
# it never interferes with normal operation; only guards against pathological shapes.
ABS_CAP = 12

# Read at most this many bytes from the end of the transcript. Comfortably contains the
# recent incident (a handful of small messages) while staying fast on huge transcripts.
TAIL_BYTES = 1_048_576

# Leak signatures. A properly parsed tool call never appears as text in the transcript
# (it becomes a tool_use block), so these tag names showing up as text in an assistant
# message with no tool_use is a leak by definition. Match with or without the
# (possibly garbled) namespace prefix.
INVOKE_RE = re.compile(r"<(?:antml:)?invoke\b", re.IGNORECASE)
PARAMETER_RE = re.compile(r"<(?:antml:)?parameter\b", re.IGNORECASE)
FUNCTION_CALLS_RE = re.compile(r"<(?:antml:)?function_calls\b", re.IGNORECASE)

# Markdown code spans, stripped before leak detection. Leaked tool-call markup is never
# wrapped in a code fence / backticks, whereas prose that *explains or quotes* the
# markup (like this very fix's write-up) almost always is. Stripping code spans is the
# principled discriminator that keeps the hook from blocking honest discussion.
FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")

# Distinctive substring of CORRECTION below. Used to recognize our OWN injected block
# reason if Claude Code records it as a transcript entry, so it is never mistaken for a
# genuine user prompt (which would reset the incident counter and risk a loop).
MARKER = "tool-call markup のリーク"

CORRECTION = (
    "ツール呼び出しが実行されず、素テキストとして出力されました"
    "（Claude Code の既知の間欠バグ: tool-call markup のリーク）。"
    "直前のメッセージで意図したツール呼び出しを、今度は実際の tool call として出し直してください。"
    "再発を抑える出し方: (1) ツール呼び出しを返信の先頭に置く（前置きの prose を書かない）"
    " (2) 1メッセージにつき1コール (3) 説明は tool 結果が返ってからにする。"
)


def _read_tail(path: str) -> str:
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        start = max(0, size - TAIL_BYTES)
        f.seek(start)
        data = f.read()
    text = data.decode("utf-8", errors="replace")
    if start > 0:
        # Drop a possibly-partial first line.
        nl = text.find("\n")
        if nl != -1:
            text = text[nl + 1 :]
    return text


def _content_is_leak(content: list | str | None) -> bool:
    """True if an assistant message leaked tool-call markup with no real tool_use."""
    if content is None:
        return False

    text_parts: list[str] = []
    has_tool_use = False

    if isinstance(content, str):
        text_parts.append(content)
    elif isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                if isinstance(block, str):
                    text_parts.append(block)
                continue
            btype = block.get("type")
            if btype == "tool_use":
                has_tool_use = True
            elif btype == "text":
                text_parts.append(str(block.get("text", "")))
            elif "text" in block:
                text_parts.append(str(block.get("text", "")))
    else:
        return False

    if has_tool_use:
        # The turn actually executed a tool; mentioning invoke in prose is fine.
        return False

    text = "\n".join(text_parts)
    # Strip code spans so quoted/explained markup (in backticks or fences) is ignored;
    # only raw, unfenced markup — the actual leak shape — remains.
    text = FENCE_RE.sub("", text)
    text = INLINE_CODE_RE.sub("", text)
    if FUNCTION_CALLS_RE.search(text):
        return True
    return bool(INVOKE_RE.search(text) and PARAMETER_RE.search(text))


def _is_genuine_user_prompt(msg: dict | None) -> bool:
    """True only for a real typed user prompt (the caller also requires isMeta != True).

    Excludes tool_result carrier messages and our own injected block reason, both of
    which are user-role entries but must NOT count as an incident boundary. The
    built-in malformed-retry meta message is excluded upstream by the isMeta check.
    """
    if not isinstance(msg, dict):
        return False
    content = msg.get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "tool_result":
                    return False  # tool result carrier, not a user prompt
                if block.get("type") == "text" or "text" in block:
                    parts.append(str(block.get("text", "")))
            elif isinstance(block, str):
                parts.append(block)
        text = "\n".join(parts)
    else:
        return False
    if not text.strip():
        return False
    if MARKER in text:
        return False  # our own injected block reason, not a genuine prompt
    return True


def _analyze(transcript_path: str) -> tuple[bool, int, int]:
    """Walk the tail backward.

    Returns (last_is_leak, incident_leaks, total_leaks):
      - last_is_leak:   the most recent assistant turn leaked.
      - incident_leaks: leaked assistant turns since the last genuine user prompt
                        (including the current one); the retry counter.
      - total_leaks:    leaked assistant turns anywhere in the tail (ABS_CAP guard).
    """
    tail = _read_tail(transcript_path)
    last_is_leak: bool | None = None
    incident_leaks = 0
    total_leaks = 0
    incident_open = True

    for line in reversed(tail.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(entry, dict):
            continue

        msg = entry.get("message")
        role = msg.get("role") if isinstance(msg, dict) else None
        etype = entry.get("type")
        is_assistant = etype == "assistant" or role == "assistant"
        is_user = etype == "user" or role == "user"

        if is_assistant:
            content = msg.get("content") if isinstance(msg, dict) else entry.get("content")
            leak = _content_is_leak(content)
            if last_is_leak is None:
                last_is_leak = leak
            if leak:
                total_leaks += 1
                if incident_open:
                    incident_leaks += 1
            # A clean assistant turn does NOT close the incident: it may be an
            # intermediate tool step of a retry that re-leaks later.
        elif (
            is_user
            and incident_open
            and entry.get("isMeta") is not True  # exclude built-in malformed-retry meta
            and _is_genuine_user_prompt(msg)
        ):
            incident_open = False  # reached the prompt that started this incident
        # else: tool_result / malformed-retry meta / injected block reason / system -> skip

    return bool(last_is_leak), incident_leaks, total_leaks


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except (ValueError, TypeError):
        return 0

    transcript_path = payload.get("transcript_path")
    if not transcript_path or not isinstance(transcript_path, str):
        return 0

    try:
        last_is_leak, incident_leaks, total_leaks = _analyze(transcript_path)
    except OSError as e:
        print(f"tool-leak-guard: cannot read transcript: {e}", file=sys.stderr)
        return 0

    if not last_is_leak:
        return 0

    if total_leaks > ABS_CAP:
        print(
            f"tool-leak-guard: leak persists ({total_leaks} total > ABS_CAP {ABS_CAP}); "
            "giving up auto-retry, manual promote needed.",
            file=sys.stderr,
        )
        return 0

    if incident_leaks > MAX_RETRIES:
        print(
            f"tool-leak-guard: leak persisted through {MAX_RETRIES} retries; "
            "giving up auto-retry, manual promote needed.",
            file=sys.stderr,
        )
        return 0

    print(
        f"tool-leak-guard: leak detected, retry {incident_leaks}/{MAX_RETRIES}.",
        file=sys.stderr,
    )
    print(json.dumps({"decision": "block", "reason": CORRECTION}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
