# Cutover: tnbc (600 px) -> wildtiles (720 px)

One-time, human, interactive. After this, everything on Pawsey is
controlled by this repo plus $HOME/wildtiles-ops/env.sh (secrets only)
and the frozen shim. tnbc is PARKED, not deleted, until wildtiles is
validated -- it is the 600-era record.

Order matters only where marked. Steps 1-2 can run any time before
step 5.

## 1. Create and configure the bucket (any credentialed machine)

    git clone https://github.com/mdsumner/wildtiles
    cd wildtiles && ./setup/setup.sh wildtiles

What it does: `aws s3 mb` + the PublicReadOnly policy (GetObject on
wildtiles/*, no ListBucket) + an anonymous PUT probe that must print
403. After the first run writes objects, verify anonymous read:

    curl -sS -o /dev/null -w "%{http_code}\n" \
      https://projects.pawsey.org.au/wildtiles/runs/latest.json   # 200

## 2. Move the canonical starc-store BEFORE the first run

The store is the one unregenerable artifact (append-only reference
cache; everything else derives). Copy bucket-to-bucket, never delete:

    module load rclone/1.68.1
    rclone copy pawsey1197:tnbc/starc-store pawsey1197:wildtiles/starc-store \
      --transfers 16 -q
    rclone size pawsey1197:tnbc/starc-store
    rclone size pawsey1197:wildtiles/starc-store   # totals must match

## 3. Image: bake aatgrid 720 into -extras (ORDER: before 4)

gdal-r-ci builds ghcr.io/hypertidy/gdal-r-python-extras. mirai and
nanonext are already on the image; the only change needed is aatgrid
at the 720 commit (PIXELS_PER_TILE = 720, v0.3.0). wildtiles itself
stays OUT of the image: it arrives by git pull. When the image is
pushed, pin it:

    docker manifest inspect ghcr.io/hypertidy/gdal-r-python-extras:latest
    # -> edit container/IMAGE to the new @sha256: digest, commit

This step does not block the merge: pipeline.R still MIRRORS the grid
constants rather than importing aatgrid, so the current image runs the
720 design correctly (and mirai is already there). The pin matters the
moment pipeline.R switches to aatgrid:: imports -- do that switch only
after the digest bump lands.

## 4. Merge to main (ORDER: after 1 and 2)

Merging the 720 branch changes the default bucket to wildtiles, so do
not merge before the bucket exists (step 1) and the store is copied
(step 2).

## 5. On Pawsey: nothing but env.sh

- env.sh keeps only the two PAWSEY_AWS_* lines. If it ever exported
  WILDTILES_BUCKET=tnbc, remove that line -- the repo default is now
  wildtiles.
- Shim, scrontab entry, lock, logs: unchanged. The next scron run
  pulls main and enacts everything. Scrontab resources per
  setup/scrontab.txt (now 24G / 6 CPU for 4 workers + main).
- Optional manual first run (recommended, watch it):

      bash $HOME/wildtiles-ops/run.sh
      tail -f $HOME/wildtiles-ops/logs/run_<RUN_ID>_<SHA>.log

## 6. First-run expectations (720 lattice = blank slate)

- registry/tiles.parquet: 24 tiles (auster 9, heard_mcdonald 6,
  macquarie 9); BANDS.txt: 18 keys.
- No inventory, no latest.json yet: every region plans from
  2024-01-01, all days pending. macquarie_island_south top-up is a
  COLD harvest (its first query rows and references are appended to
  the store); auster/heard references are already present.
- With 4 workers expect roughly 3-4x serial throughput (network
  bound); the first timeboxed exit is normal -- the backfill drains
  across nightly runs, monotone complete_through per region.
- Nothing from tnbc/cube is reused: 720 tiles have new ids by design.

## 7. Validation before retiring anything

- runs/latest.json advancing; inventory rows = 18 x tiles x certified
  days per region; spot-check a cube COG anonymously in QGIS
  (/vsicurl/https://projects.pawsey.org.au/wildtiles/cube/...).
- tnbc stays until the three regions are drained to current and
  spot-checks pass. Deleting it is a separate, deliberate, human act.
