#!/bin/bash
# Canonical text of the FROZEN bootstrap shim at ~/wildtiles-ops/run.sh.
# Copy once at setup; never edit the live copy after that. Its only job
# is: pull the repo, hand over. All logic lives in the repo's run.sh,
# which refuses to run without a checkout precisely so nobody runs it
# directly. Recovery recipe: this file + env.sh + the scrontab line.
set -eu
WORK=${MYSCRATCH:-$HOME}/wildtiles-run
REPO_URL=https://github.com/mdsumner/wildtiles.git
mkdir -p "$WORK"; cd "$WORK"
if [ -d repo/.git ]; then
  git -C repo fetch -q origin main && git -C repo reset -q --hard origin/main
else
  git clone -q --depth 1 "$REPO_URL" repo
fi
exec bash repo/run.sh
