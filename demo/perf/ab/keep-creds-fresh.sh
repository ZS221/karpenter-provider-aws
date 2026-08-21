#!/usr/bin/env bash
# Refresh AWS credentials on a loop for the duration of the experiment.
#
# This exists because the session's Isengard credentials last roughly 30 minutes and a
# single cell is a ~25 minute uninterrupted window. Every script here fails fast on expired
# credentials rather than recording a partial window, which is correct but means an expiry
# at minute 12 costs you that cell. Three expiries in one afternoon made this worth
# automating.
#
# Deliberately loops `ada credentials update --once` rather than running bare
# `ada credentials update` as its own daemon: --once has documented, observed behaviour
# (refresh, exit 0) whereas the bare form's refresh cadence is not something to bet a
# four-hour experiment on.
#
# Run it in the background and leave it running:
#   ./keep-creds-fresh.sh &
#   ...run the experiment...
#   kill %1
#
# It refreshes immediately, then every INTERVAL seconds. Requires a valid Midway cert
# (`mwinit` if it starts failing -- that part is interactive and cannot be automated).

set -uo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
source "${HERE}/config.sh"

ROLE=${ROLE:-Admin}
PROFILE=${PROFILE:-default}
INTERVAL=${INTERVAL:-600}
LOG=${LOG:-/tmp/ab-creds.log}

printf '%sRefreshing %s/%s every %ss -> %s%s\n' "$DIM" "$ACCOUNT" "$ROLE" "$INTERVAL" "$LOG" "$R"

n=0
while true; do
  n=$((n + 1))
  if out=$(ada credentials update --once --account "$ACCOUNT" --role "$ROLE" --profile "$PROFILE" 2>&1); then
    who=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "STS check failed")
    printf '[%s] refresh #%s ok: %s\n' "$(date +%H:%M:%S)" "$n" "$who" >> "$LOG"
  else
    # Loud, because everything downstream depends on this and a silent failure here shows up
    # as a mysteriously dead cell twenty minutes later.
    printf '[%s] refresh #%s FAILED: %s\n' "$(date +%H:%M:%S)" "$n" "$out" >> "$LOG"
    printf '%s  credential refresh FAILED -- run mwinit, then restart this script%s\n' "$RED" "$R" >&2
  fi
  sleep "$INTERVAL"
done
