#!/usr/bin/env bash
# PostToolUse hook: auto-format files after Edit/Write
# - Runs the project's formatter on the edited file based on extension
# - Silent on success; never blocks the tool call (exit 0 always)
# - Skips formatting if formatter not installed

set -u

input=$(cat)

# jq is optional — fall back to grep if not present
if command -v jq >/dev/null 2>&1; then
  file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
  file_path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

if [ -z "${file_path:-}" ] || [ ! -f "$file_path" ]; then
  exit 0
fi

case "$file_path" in
  *.py)
    command -v ruff >/dev/null 2>&1 && ruff format "$file_path" >/dev/null 2>&1
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.yaml|*.yml|*.css|*.scss)
    command -v prettier >/dev/null 2>&1 && prettier --write --log-level=silent "$file_path" >/dev/null 2>&1
    ;;
  *.sol)
    command -v forge >/dev/null 2>&1 && forge fmt "$file_path" >/dev/null 2>&1
    ;;
  *.go)
    command -v gofmt >/dev/null 2>&1 && gofmt -w "$file_path" >/dev/null 2>&1
    ;;
  *.sh|*.bash)
    command -v shfmt >/dev/null 2>&1 && shfmt -w "$file_path" >/dev/null 2>&1
    ;;
  *.rs)
    command -v rustfmt >/dev/null 2>&1 && rustfmt "$file_path" >/dev/null 2>&1
    ;;
esac

exit 0
