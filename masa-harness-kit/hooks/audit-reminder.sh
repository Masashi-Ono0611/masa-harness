#!/usr/bin/env bash
# SessionStart hook: emit reminders for time-based recurring tasks that are due/overdue.
# Reads ~/.claude/state/recurring-tasks.json (single source of truth).
# Only acts on tasks with trigger="session-start-reminder" and enabled=true.
# Stdout is injected into Claude's context per Claude Code SessionStart hook spec.
# Always exits 0; silent when nothing is due.

set -u

STATE_FILE="$HOME/.claude/state/recurring-tasks.json"
[ ! -f "$STATE_FILE" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Parse YYYY-MM-DD to epoch seconds (BSD/macOS と GNU/Linux 両対応)
_date_to_epoch() {
  date -j -f "%Y-%m-%d" "$1" "+%s" 2>/dev/null || date -d "$1" "+%s" 2>/dev/null
}

today_epoch=$(date +%s)

# Interval-relative warn window: warn within (interval / 4) days before due,
# clamped to [1, 14]. Per-task `warn_window_days` in JSON overrides this.
#   interval  7d -> warn 1d before
#   interval 30d -> warn 7d before
#   interval 90d -> warn 14d before (capped)

lines=()
while IFS=$'\t' read -r _key label command last_run interval warn_override; do
  [ -z "${last_run:-}" ] && continue
  [ -z "${interval:-}" ] && continue

  # YYYY-MM-DD -> epoch (BSD/macOS と GNU/Linux 両対応)
  last_epoch=$(_date_to_epoch "$last_run") || continue
  days_since=$(( (today_epoch - last_epoch) / 86400 ))
  days_left=$(( interval - days_since ))

  if [ -n "${warn_override:-}" ] && [ "$warn_override" != "null" ]; then
    warn_window="$warn_override"
  else
    warn_window=$(( interval / 4 ))
    [ "$warn_window" -lt 1 ] && warn_window=1
    [ "$warn_window" -gt 14 ] && warn_window=14
  fi

  if [ "$days_left" -lt 0 ]; then
    overdue=$(( -days_left ))
    lines+=("- [OVERDUE by ${overdue}d] ${label} -> run: ${command}")
  elif [ "$days_left" -le "$warn_window" ]; then
    lines+=("- [DUE in ${days_left}d] ${label} -> run: ${command}")
  fi
done < <(jq -r '
  .tasks | to_entries[]
  | select(.value.enabled == true and .value.trigger == "session-start-reminder")
  | [.key, .value.label, .value.command, .value.last_run, (.value.interval_days|tostring), (.value.warn_window_days // "")|tostring]
  | @tsv
' "$STATE_FILE" 2>/dev/null)

if [ "${#lines[@]}" -gt 0 ]; then
  echo "[Claude Recurring Tasks Reminder]"
  printf '%s\n' "${lines[@]}"
  echo ""
  echo "After running a task, update its last_run in $STATE_FILE so this stops nagging."
fi

exit 0
