#!/bin/bash
# wildtiles scrontab entry point (Setonix).
# scrontab:
#   #SCRON --time=02:00:00 --mem=24G --cpus-per-task=6
#   23 3 * * * $HOME/wildtiles-ops/run.sh
#
# Module loads come BEFORE strict mode: Lmod can trip over set -u.
module load rclone/1.68.1
module load singularity/4.1.0-slurm
set -euo pipefail

OPS=$HOME/wildtiles-ops
REPO_URL=https://github.com/mdsumner/wildtiles.git
WORK=${MYSCRATCH:-$HOME}/wildtiles-run
BUCKET=${WILDTILES_BUCKET:-wildtiles}
REMOTE=pawsey1197            # rclone remote (site config)
SIF_LIB=${MYSOFTWARE:-$HOME}/sif_lib

LOG_DIR=$OPS/logs; mkdir -p "$LOG_DIR" "$WORK" "$SIF_LIB"

# --- single-flight lock -------------------------------------------------
exec 9>"$OPS/.run.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) busy, skip" >> "$LOG_DIR/runs.log"; exit 0; }

# --- secrets: one file, fail loud, exported before anything loads GDAL --
source "$OPS/env.sh"
: "${PAWSEY_AWS_ACCESS_KEY_ID:?not set}" "${PAWSEY_AWS_SECRET_ACCESS_KEY:?not set}"
export SINGULARITYENV_PAWSEY_AWS_ACCESS_KEY_ID=$PAWSEY_AWS_ACCESS_KEY_ID
export SINGULARITYENV_PAWSEY_AWS_SECRET_ACCESS_KEY=$PAWSEY_AWS_SECRET_ACCESS_KEY
export SINGULARITYENV_WILDTILES_BUCKET=$BUCKET
export SINGULARITYENV_WILDTILES_DEADLINE=${SLURM_JOB_END_TIME:-$(date -d '+110 minutes' +%s)}
export SINGULARITYENV_WILDTILES_WORKERS=${WILDTILES_WORKERS:-4}

# --- code: clone or fast-forward to origin/main -------------------------
cd "$WORK"
[ -d repo/.git ] || { echo "no checkout at $WORK/repo -- run via the shim"; exit 1; }
SHA=$(git -C repo rev-parse --short HEAD)

# --- image: digest-pinned by the repo, lazily pulled, content-addressed -
IMAGE=$(cat repo/container/IMAGE)
DIGEST=$(echo "$IMAGE" | sed 's/.*sha256://' | cut -c1-12)
SIF=$SIF_LIB/gdal-r-python-extras_${DIGEST}.sif
[ -f "$SIF" ] || singularity pull "$SIF" "docker://$IMAGE"
RSCRIPT="singularity exec --env LD_LIBRARY_PATH= $SIF Rscript"

# --- starc-store: bucket canonical, scratch cache (copy never deletes) --
rclone copy "$REMOTE:$BUCKET/starc-store" "$WORK/starc-store" --transfers 16 -q

# --- run -----------------------------------------------------------------
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
RUNLOG=$LOG_DIR/run_${RUN_ID}_${SHA}.log
echo "$(date -u +%FT%TZ) start $RUN_ID commit $SHA bucket $BUCKET" >> "$LOG_DIR/runs.log"

if $RSCRIPT repo/run.R "$RUN_ID" "$SHA" "$WORK" >> "$RUNLOG" 2>&1; then
  rclone copy "$WORK/starc-store" "$REMOTE:$BUCKET/starc-store" --transfers 16 -q
  echo "$(date -u +%FT%TZ) OK    $RUN_ID" >> "$LOG_DIR/runs.log"
else
  echo "$(date -u +%FT%TZ) FAIL  $RUN_ID see $(basename "$RUNLOG")" >> "$LOG_DIR/runs.log"
  exit 1
fi
