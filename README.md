# wildtiles

Per-tile Sentinel-2 cubes for Antarctic and subantarctic wildlife
regions, on the aatgrid systematic tile scheme, fed from the starc
reference cache. Continuation of the ESTINEL line of work.

Everything except secrets lives in this repo: code (R/pipeline.R,
run.R, run.sh), the survey design in force (data/regions.csv + SPECS),
bucket infrastructure as code (setup/), and the container recipe
(container/). Data and run state live in the bucket; /scratch is pure
cache. Recovery test: git clone + env.sh + scrontab line rebuilds the
whole operation.

## Layout of the bucket (public read-only)

    cube/<tile_id>/<band>/<solarday>.tif   single-band COGs, native dtype
    registry/tiles.parquet, BANDS.txt      the design, mirrored from repo
    index/inventory.parquet                what exists (tile x band x day)
    runs/<run_id>.json, runs/latest.json   provenance; latest = state
    summaries/                             tier-P stats per (region, day)
    starc-store/                           canonical STAC reference cache

## Operating

One-time (human, credentialed): setup/setup.sh <bucket>; copy
setup/env.sh.example to $HOME/wildtiles-ops/env.sh; paste
setup/scrontab.txt. After that: pull, run -- the scrontab does both.

Region requests are pull requests: propose tiles with aatgrid, review
on the footprint plot ("missed this corner" / "drop that ocean tile"),
merge = design decision; the next run enacts it.

## Doctrine (each item has a dated scar)

- environment before GDAL init; config store over env; assert
  AWS_NO_SIGN_REQUEST=NO explicitly
- credentials fail loud, never silently anonymous
- append-only stores, dedup at read; re-runs always safe
- run record written last: an existing record is a completed run
- no special read access: the pipeline orients from the same public
  endpoints any external uses
- no hand-typed extents: all geometry derives from (zone, res, col, row)
