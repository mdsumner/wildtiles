#!/bin/bash
#SBATCH --job-name=wildtiles-backfill
#SBATCH --account=pawsey1362
#SBATCH --partition=work
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=36
#SBATCH --mem=64G
#
# Explicit backfill tier: same code path as the nightly scron tick
# (the frozen shim pulls main, repo run.sh does everything) with more
# workers. Submit by hand when a large drain is wanted:
#
#     sbatch jobs/backfill.sbatch
#
# The ops lock makes it mutually exclusive with the nightly run (the
# later arrival logs "busy, skip" and exits 0). The deadline comes
# from SLURM_JOB_END_TIME, so the run timeboxes and checkpoints like
# any other -- resubmit to continue the drain. Politeness gauge is the
# 503 rate in the run log: rare is fine, clustered means back off.

export WILDTILES_WORKERS=${WILDTILES_WORKERS:-32}
exec bash "$HOME/wildtiles-ops/run.sh"
