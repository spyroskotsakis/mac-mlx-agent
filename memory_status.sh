#!/usr/bin/env bash
# One-shot memory overview for the local MLX stack: machine + server process.
# The menu-bar app shows the same numbers (plus the model's exact weight) live.
#
# Usage:
#   ./memory_status.sh
set -uo pipefail

TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
TOTAL_GB=$(awk -v b="$TOTAL_BYTES" 'BEGIN { printf "%.1f", b/1073741824 }')

# System-wide free percentage from `memory_pressure` (e.g. "… free percentage: 89%").
FREE_PCT=$(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: *\([0-9]*\)%.*/\1/p' | head -1)
[[ -z "$FREE_PCT" ]] && FREE_PCT=0

if (( FREE_PCT < 10 )); then PRESSURE="Critical"; elif (( FREE_PCT < 25 )); then PRESSURE="Warning"; else PRESSURE="Normal"; fi

# Server process footprint (RSS) if mlx_lm.server is running.
SERVER_PID=$(pgrep -f "mlx_lm.server" | head -1)
if [[ -n "$SERVER_PID" ]]; then
  RSS_KB=$(ps -o rss= -p "$SERVER_PID" 2>/dev/null | tr -d ' ')
  SERVER_GB=$(awk -v kb="${RSS_KB:-0}" 'BEGIN { printf "%.1f", kb/1048576 }')
else
  SERVER_GB="—"
fi

printf 'Memory\n'
printf '  Total:     %s GB\n' "$TOTAL_GB"
printf '  Free:      %s%%\n' "$FREE_PCT"
printf '  Used:      %s%%\n' "$((100 - FREE_PCT))"
printf '  Pressure:  %s\n' "$PRESSURE"
printf '  Server:    %s GB (pid %s)\n' "$SERVER_GB" "${SERVER_PID:--}"

# Optional: map a few common repos to approximate 4-bit weight GB. The app shows
# the exact per-model figure; this is just a quick terminal hint.
MODEL_ARG="${1:-}"
case "$MODEL_ARG" in
  *Qwen3.6-35B-A3B*|*Qwen3.5-35B-A3B*|*Heretic*) printf '  Model:     ~20 GB (35B 4-bit)\n' ;;
  *Qwen3-14B*) printf '  Model:     ~8 GB (14B 4-bit)\n' ;;
  *Qwen3-4B*|*Qwen3.5-4B*) printf '  Model:     ~2.5 GB (4B 4-bit)\n' ;;
  "") ;;
  *) printf '  Model:     see app (weights not mapped here)\n' ;;
esac
