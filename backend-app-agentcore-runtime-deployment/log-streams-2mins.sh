#!/bin/sh
set -eu

GROUP="/aws/bedrock-agentcore/runtimes/app-yGSwuh40YZ-DEFAULT"

PROFILE="AdministratorAccess-541474745272"
REGION="us-east-1"

# Time window (America/New_York)
START_MS=1756046340000   # 2025-08-24 10:39:00 EDT
END_MS=1756046460000     # 2025-08-24 10:41:00 EDT
OUT="log_output_all_streams_10_39_to_10_41.txt"

: > "$OUT"

aws logs describe-log-streams \
  --log-group-name "$GROUP" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --output text \
  --max-items 100000 \
  --query 'logStreams[].logStreamName' \
| tr '\t' '\n' \
| sed '/^$/d' \
| xargs -n100 /bin/bash -c '
  DUMMY="$0"; GROUP="$1"; START="$2"; END="$3"; REGION="$4"; PROFILE="$5"; shift 5
  aws logs filter-log-events \
    --log-group-name "$GROUP" \
    --start-time "$START" \
    --end-time "$END" \
    --interleaved \
    --region "$REGION" \
    --profile "$PROFILE" \
    --page-size 1000 \
    --max-items 100000 \
    --output text \
    --log-stream-names "$@" >> "'"$OUT"'"
' _ "$GROUP" "$START_MS" "$END_MS" "$REGION" "$PROFILE"

echo "Wrote $(wc -l < "$OUT") lines to $OUT"
