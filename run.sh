#!/bin/bash
# wildtiles scrontab entry point (Setonix).
# scrontab example:
#   #SCRON --time=02:00:00 --mem=16G --cpus-per-task=4
#   23 3 * * * $HOME/wildtiles-ops/run.sh
set -euo pipefail

OPS=$HOME/wildtiles-ops
REPO_URL=https://github.com/mdsumner/wildtiles.git
WORK=${MYSCRATCH:-$HOME}/wildtiles-run
SIF=$OPS/wildtiles.sif
RSCRIPT="singularity exec $SIF Rscript"     # or plain Rscript
BUCKET=${WILDTILES_BUCKET:-tnbc}
ENDPOINT=https://projects.pawsey.org.au

LOG_DIR=$OPS/logs; mkdir -p "$LOG_DIR" "$WORK"

exec 9>"$OPS/.run.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) busy, skip" >> "$LOG_DIR/runs.log"; exit 0; }

source "$OPS/env.sh"    # chmod 600; exports PAWSEY_AWS_*
: "${PAWSEY_AWS_ACCESS_KEY_ID:?}" "${PAWSEY_AWS_SECRET_ACCESS_KEY:?}"
export AWS_ACCESS_KEY_ID=$PAWSEY_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$PAWSEY_AWS_SECRET_ACCESS_KEY
export SINGULARITYENV_PAWSEY_AWS_ACCESS_KEY_ID=$PAWSEY_AWS_ACCESS_KEY_ID
export SINGULARITYENV_PAWSEY_AWS_SECRET_ACCESS_KEY=$PAWSEY_AWS_SECRET_ACCESS_KEY
export SINGULARITYENV_WILDTILES_BUCKET=$BUCKET

cd "$WORK"
if [ -d repo/.git ]; then
  git -C repo fetch -q origin main && git -C repo reset -q --hard origin/main
else
  git clone -q --depth 1 "$REPO_URL" repo
fi
SHA=$(git -C repo rev-parse --short HEAD)

## starc-store: bucket is canonical, scratch is cache (append-only,
## write-once shards make sync trivially safe in both directions)
aws s3 sync "s3://$BUCKET/starc-store" "$WORK/starc-store" \
  --endpoint-url "$ENDPOINT" --quiet

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
RUNLOG=$LOG_DIR/run_${RUN_ID}_${SHA}.log
echo "$(date -u +%FT%TZ) start $RUN_ID commit $SHA bucket $BUCKET" >> "$LOG_DIR/runs.log"

if $RSCRIPT repo/run.R "$RUN_ID" "$SHA" "$WORK" >> "$RUNLOG" 2>&1; then
  aws s3 sync "$WORK/starc-store" "s3://$BUCKET/starc-store" \
    --endpoint-url "$ENDPOINT" --quiet
  echo "$(date -u +%FT%TZ) OK    $RUN_ID" >> "$LOG_DIR/runs.log"
else
  echo "$(date -u +%FT%TZ) FAIL  $RUN_ID see $(basename "$RUNLOG")" >> "$LOG_DIR/runs.log"
  exit 1
fi
