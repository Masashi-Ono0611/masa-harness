#!/usr/bin/env python3
"""Stop hook: detect leaked tool-call markup and force an immediate self-correction.

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
  Fires on Stop. Reads the last assistant message from the transcript. If it contains
  the leak signature (``<invoke>``+``<parameter>`` or ``<function_calls>`` as text)
  AND that message produced zero real tool_use blocks, it returns decision=block with
  the corrective workaround. This converts a dead "leaked" turn into one automatic
  retry instead of leaving the session stuck on broken output.

Safety:
  - Honors ``stop_hook_active`` (never blocks twice in a row -> no infinite loop;
    re-arms on each new user turn).
  - Any error / missing transcript -> exit 0 silently (never breaks the session).
  - Only stdout carries the decision JSON; diagnostics go to stderr.

This is a SAFETY NET + auto-correct, not a root-cause fix. The real fix is upstream
(keep Claude Code updated) plus the behavioral reflex (tool-call-first).
"""

from __future__ import annotations

import json
import re
import sys

# Read at most this many bytes from the end of the transcript. The final assistant
# message (the one that may have leaked) is small; 1 MiB comfortably contains it
# while keeping the hook fast on huge transcripts.
TAIL_BYTES = 1_048_576

# Leak signatures. A properly parsed tool call never appears as text in the
# transcript (it becomes a tool_use block), so these tag names showing up as text
# in an assistant message with no tool_use is a leak by definition. Match with or
# without the (possibly garbled) namespace prefix.
INVOKE_RE = re.compile(r"<(?:antml:)?invoke\b", re.IGNORECASE)
PARAMETER_RE = re.compile(r"<(?:antml:)?parameter\b", re.IGNORECASE)
FUNCTION_CALLS_RE = re.compile(r"<(?:antml:)?function_calls\b", re.IGNORECASE)

# Markdown code spans, stripped before leak detection. Leaked tool-call markup is
# never wrapped in a code fence / backticks, whereas prose that *explains or quotes*
# the markup (like this very fix's write-up) almost always is. Stripping code spans
# is the principled discriminator that keeps the hook from blocking honest discussion.
FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")

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


def _last_assistant_content(transcript_path: str) -> list | str | None:
    """Return the message.content of the most recent assistant entry, or None."""
    tail = _read_tail(transcript_path)
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
        is_assistant = entry.get("type") == "assistant" or (
            isinstance(msg, dict) and msg.get("role") == "assistant"
        )
        if not is_assistant:
            continue
        if isinstance(msg, dict):
            return msg.get("content")
        return entry.get("content")
    return None


def _is_leak(content: list | str | None) -> bool:
    """True if the assistant message leaked tool-call markup with no real tool_use."""
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


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except (ValueError, TypeError):
        return 0

    if payload.get("stop_hook_active") is True:
        # Already forcing a continuation; do not block again (loop guard).
        return 0

    transcript_path = payload.get("transcript_path")
    if not transcript_path or not isinstance(transcript_path, str):
        return 0

    try:
        content = _last_assistant_content(transcript_path)
    except OSError as e:
        print(f"tool-leak-guard: cannot read transcript: {e}", file=sys.stderr)
        return 0

    if _is_leak(content):
        print(json.dumps({"decision": "block", "reason": CORRECTION}))

    return 0


if __name__ == "__main__":
    sys.exit(main())
