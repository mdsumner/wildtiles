# wildtiles: design and rationale

Status document, 29 September 2026. The pilot (Auster + Heard/McDonald,
2024-present) is validated and running headless on Setonix. This
document distils the deployed design, records why each decision was
made, and frames the open decisions for production scale-up toward
significant East Antarctic coverage (seeds first).

Lineage: the ESTINEL line of work. estinel-prod (the browse site)
continues untouched; wildtiles is the science successor -- all bands,
clouds as weights, systematic tiles, public state.

## 1. Landscape

Five components, each owning exactly one layer:

| layer                | component        | what it owns                                   |
|----------------------|------------------|------------------------------------------------|
| grid arithmetic      | aatgrid          | origin (140000, 20000), 600 px tiles, tile ids, nesting, MGRS bridge |
| discovery record     | starc            | append-only STAC reference store: queries, acquisitions, products, assets, raw stash |
| pixels + IO          | gdalraster       | warp, carve, VSI, S3 config                    |
| pipeline + policy    | wildtiles (repo) | SPECS, band list, runner, doctrine, survey design |
| state + data         | bucket (tnbc)    | cube tiles, starc-store (canonical), index, runs, summaries |

Supporting cast: GitHub (code and design, public), the container image
(ghcr.io/hypertidy/gdal-r-python-extras, digest-pinned in the repo),
Pawsey Setonix (scron + scratch cache + sif_lib), Element84
earth-search (the only provider so far).

The operating loop: scrontab fires a frozen ~10-line bootstrap shim ->
fresh repo checkout on scratch -> repo/run.sh (modules, lock, secrets,
digest-pinned image, store down-sync) -> run.R (top-up harvest, plan,
render, checkpoint) -> store up-sync -> public run record. Any person
or session orients from three public URLs: the repo, runs/latest.json,
index/inventory.parquet.

## 2. The deployed system

Bucket layout (public read-only; no public ListBucket):

    cube/<tile_id>/<band>/<solarday>.tif   single-band COG, native dtype
    registry/tiles.parquet, BANDS.txt      the design, mirrored from repo
    index/inventory.parquet                tile x band x day: what exists
    runs/<run_id>.json, runs/latest.json   provenance + live state
    summaries/                             tier-P stats per (region, day)
    starc-store/                           canonical reference store

Run lifecycle: a run is a TIME-BOXED ATTEMPT, not a unit of work.
State advances monotonically at checkpoints (every 25 rendered days
and each region boundary); the day loop exits gracefully before the
walltime deadline; the schedule is the loop and the backlog drains one
slice per firing. Days certified complete by the inventory are skipped
with zero network calls; per-file existence checks guard only the days
that actually run.

Doctrine (every line has a dated scar):

- environment before GDAL init; GDAL config via the config store, with
  AWS_NO_SIGN_REQUEST=NO asserted explicitly (a global no-sign in a
  Pawsey gdalrc silently unsigned all writes)
- credentials fail loud: presence AND plausibility checked (a
  placeholder "..." signed requests as user "...")
- secrets in exactly one hand-placed file (env.sh); modules and env
  spelled out in the runner, never in aliases; LD_LIBRARY_PATH cleared
  into the container
- append-only stores, write-once shards, dedup at read; overlapping or
  repeated work is always safe; rclone copy (never delete semantics)
  as store transport
- run record written last; an existing record is a completed (or
  honestly in-progress/timeboxed) run; "empty" is a positive fact
  distinct from "never asked"
- no special read access: the pipeline orients from the same public
  endpoints any external uses
- no hand-typed geometry: every extent derives from
  (zone, res, col, row); densified bounds for every reprojected
  extent (corner-only transformation loses real coastline)
- tiles are storage and processing units; sites read windows, never
  tiles (Atlas Cove, Auster, and Macquarie South all sit within
  ~1 km of tile seams -- with seams every 6 km this is arithmetic,
  not bad luck)
- recovery contract: git clone + env.sh + scrontab line rebuilds the
  entire operation; the ONLY unregenerable artifact is the starc
  store's sighting history, hence bucket-canonical with archival
  copies

## 3. Decisions and rationale (settled)

- Tile-keyed, region-free object paths. Regions are views over tiles;
  a third region or a shared tile never rekeys anything. Region
  membership lives in the registry, not in paths.
- Single-band files, native dtypes. UInt16 reflectance, Byte
  scl/cloud/snow; a day-stack is composed by the consumer (VRT over
  the fixed 17-key vocabulary), never baked in. Renders and analytical
  products are derived, versioned, disposable; raw bands are the
  immutable record.
- Clouds are weights, not filters. Nothing is discarded for weather;
  cloud_prob/snow_prob ride into every summary as uncertainty. This is
  the line that separates a science cube from a browse gallery, and
  the reason polar cloud/snow confusion is a modelling term rather
  than a data loss.
- Acquisition identity is provider-independent (platform + MGRS tile +
  datetime); reprocessings are sibling products; datastrip twins are
  complements that mosaic, never alternatives.
- The S2 MGRS scene-extent convention is archive-verified (0 m
  residual on 132 codes, both hemispheres) and pinned by tests in
  aatgrid; S2 10/20 m lattices coincide exactly with aatgrid, 60 m
  bands carry a constant (20, 20) m southern shift absorbed by the
  warp.
- Survey design is incremental and recorded: algorithm proposes tiles
  from a point/polygon, human review adjusts (add missed corners, drop
  ocean), the registry records memberships. Target workflow: region
  requests as pull requests, review deltas as provenance.

## 4. Decision A (RESOLVED): 720 px tiles

Resolved 29 Sep 2026, landed 2 Oct 2026: PIXELS_PER_TILE moves from
600 to 720 in aatgrid and wildtiles together -- the generative
invariant changes once, everywhere. tile_size(10) = 7200 m,
tile_size(60) = 43200 m; the resolution ladder {10, 20, 60, 120, 360}
steps (2, 3, 2, 3) all divide 720; whole-metre tile ids are retained
(R + 4-digit metres, 4-digit col/row; 1 m resolution floor). The 720
lattice produces NEW tile ids, so the change rides with the move to
the wildtiles bucket: empty inventory, full re-render; tnbc is parked
untouched as the 600-era record until wildtiles is validated. The
Option B question below (storage files as parent tiles of the same
lattice) remains open for the East Antarctic scale-up and is
unaffected by the 720 choice. Original analysis kept for the record:

The 600x600 px file is the aatgrid generative invariant (tile_size =
600 * res) inherited directly into storage: one object per (L2 tile,
band, day). At pilot scale this is fine; at East Antarctic scale the
arithmetic bites:

    illustrative year, ~60 seed regions, avg 9 L2 tiles, 17 bands,
    ~150 solardays: ~1.4M objects/yr at 600 px storage.

Costs of small files: object count (listing, sync, per-request
overhead), poor per-file compression amortisation, and only ONE
overview level (COG builds overviews while dim > 512: 600 -> 300,
stop), which starves any zoomed-out viewer.

Key insight for the alternative: aatgrid nesting means a LARGER file
can be an exact parent tile of the same lattice -- storage granularity
and logical granularity can differ without breaking index arithmetic.

- Option A (status quo): file = L2 tile (600 px). Simplest identity
  between file and grid; smallest object reads; worst object count.
- Option B (proposed): file = parent tile at storage level, content at
  native res. E.g. 10 m content stored as L1-extent files: 3600x3600
  px, exactly 36 L2 tiles per file. Object count divides by up to 36
  (~40k objects/yr in the scenario above); COG internal 512 tiling
  keeps ranged reads of any logical L2 window at one or two requests;
  overviews gain real depth (3600 -> 1800 -> 900 -> 450, three levels,
  viewer-friendly). Logical tiles remain L2 in the registry and
  summaries; extraction is -srcwin / ranged-read arithmetic. Naming
  needs one decision: storage ids at the parent (col, row) with an
  explicit content-res field.
- Option C (rejected): file = region block per band-day (what the warp
  produces before carving). Ties storage to region extents, violating
  the tile-keyed principle; blocks like Auster's 18 km 3x3 are not
  lattice tiles.

Migration cost is low BY DESIGN: tiles are derived artifacts, the
recipe (starc references + registry + code) regenerates them, and the
backfill machinery below makes re-rendering cheap. If Option B is
adopted, adopt it BEFORE the East Antarctic scale-up so the big render
happens once. Related knobs to settle at the same time: OVERVIEW
resampling (average for reflectance, nearest for scl/cloud/snow),
COMPRESS (DEFLATE vs ZSTD -- image now carries GDAL 3.13), and
whether summaries move to per-storage-tile granularity (no: keep
logical-L2 rows; they are the analysis unit).

## 5. Decision B (IMPLEMENTED): day-level worker pool

Implemented 2 Oct 2026 in run.R, as proposed below: mirai daemons,
WILDTILES_WORKERS (default 4, deliberately modest), every worker
sources pipeline.R and calls set_gdal_envs() itself, ALL monotone
state stays in the main process, the deadline stops dispatch and
in-flight days drain. Serial path preserved verbatim for workers=1 or
mirai absent from the image (logged, not fatal; mirai and nanonext
are already on gdal-r-python-extras). The explicit backfill.sbatch
tier remains backlog. Original analysis kept for the record:

Facts: the workload is network-bound (vsicurl reads dominate; CPU per
band is seconds); days are contention-free by construction (no two
workers share a day; per-file existence checks make retries safe;
summaries are day-keyed). Pawsey offers up to a full node (128 CPU,
230 GB) but the binding constraint is POLITENESS to Element84
(~16-32 concurrent streams is the ceiling of good manners), and RAM is
irrelevant (a block band is MBs).

Proposed design:

- Day-level parallelism with a worker pool (mirai or crew), workers =
  WILDTILES_WORKERS. Each worker renders whole days; the main process
  owns ALL state writes (inventory flush, run record) at checkpoints,
  collecting worker results -- the monotone-state machinery is
  untouched.
- Every worker calls set_gdal_envs() itself: GDAL config is
  process-local (the gdalrc lesson wears a new hat in every forked
  process).
- Near-automatic policy: workers auto-scale to
  min(WILDTILES_WORKERS_MAX, pending_days) with serial (1) as the
  floor -- the daily scron run stays serial and humble; a backfill
  finds itself with hundreds of pending days and spins up without any
  separate code path.
- Deadline interaction: stop dispatching new days at deadline minus
  margin; let in-flight days finish; checkpoint; exit timeboxed.
- Two-tier resourcing stands: scron daily at 4-8 CPU; explicit
  jobs/backfill.sbatch at 16-32 CPU for region onboarding and any
  storage-geometry migration. The full node stays in reserve for
  genuinely CPU-bound futures (tier-P statistics at scale, browness
  classification).

## 6. Backlog (queued, discussed, not yet built)

Regions and rendering:
- Macquarie: JOINED 2 Oct 2026 on the 720 lattice (57S, L2 10 m,
  cols 48:50, rows 546:548, 9 tiles over the isthmus/station; the
  starc region macquarie_island_south drives discovery).
- Heard 10 m promotion: land-touching L2 tiles from the coastline
  intersection (~50-60 of 216), via a tiles-list spec or registry
  classes; the 60 m block remains the ocean-context tier.
- Tile classification in the registry: land / coastal / margin /
  ocean per tile (controlledburn or GEOS pass over coastlines);
  purposes select classes (policy chooses, classification is derived).
- Registry migration: SPECS out of code into data files; aatgrid
  constants imported, the inlined OX/OY/NPIX "keep in sync" block
  deleted; regions as tile sets with review provenance
  (proposed/added/dropped and why).

starc roadmap:
- Export marker()/marker_region() (currently ::: workarounds).
- Test fixtures: two datastrip-twin raw items.
- DEA ARD mapper (Tasmanian/Australian sites re-enter via routing
  policy); ga_s1_nrb SAR mappers (IW and EW) when DE Antarctica
  endpoints firm up -- winter/polar-night continuity is the scientific
  driver, and the coverage-map figure (sun elevation by month by
  region, derivable from the raw stash) is the briefing artifact for
  that conversation.
- scene_stats backfill from the raw stash (s2:* percentages,
  view:sun_elevation) -- free tier-P at scene granularity.
- Coverage-probe cadence (all providers x all regions, slow schedule)
  vs incremental cadence (policy-live pairs only).

Science (the browness program):
- Tier-P summaries exist per (tile, band, day); first pre-registered
  analysis: colony tile vs block neighbours, contrast ~ cloud_cover
  by band and month (detectability before any index).
- No browness index is baked into storage; formulations per signal
  class (emperor-on-ice, adelie-on-rock, seal-wallow, vegetation) are
  read-time and to be developed with the remote sensing specialists.
- Trigger taxonomy sketched: appearance / disappearance-in-season /
  displacement / background drift; the trigger log IS the candidate
  list and the escalation request format (S1 EW, ARD, VHR).
- estinel-prod: keeps running as browse + annotation surface (its
  ratings machinery is labelled training data); emperor and pinniped
  purposes migrate onto tiles demand-by-demand.

Operations:
- Bucket rename/migration (tnbc -> wildtiles) still optional; if done:
  store sync FIRST, teardown last. tnbc-as-name is otherwise harmless.
- Inventory growth: single parquet is fine to ~millions of rows;
  partition by tile prefix if it ever drags.
- audit_inventory() cadence: occasional, or after any irregular event.
- Old machines: openstack copy of the store is archival (never
  written again); estinel host unchanged.

## 7. Risks and watch items

- Upstream reprocessing (new S2 baselines) creates sibling products:
  identity handles it, but render policy should prefer newest
  baseline; not yet expressed anywhere.
- Element84 availability: transient 503s are absorbed by GDAL retry
  (observed working); a sustained outage simply timeboxes runs with
  honest state.
- Image digest rotation: rebuilds must bump container/IMAGE by commit;
  the sif_lib accumulates digest-named images (prune occasionally).
- Key rotation touches two files (env.sh, rclone config) -- noted.
- Scratch purge is harmless by design but the first run after a purge
  re-syncs the store (~minutes).
- geographiclib API is the one soft joint in the aatgrid MGRS bridge;
  its tests pin the verified convention.

## 8. The regroup question

Everything above serves one ambition: wildtiles as a store covering
significant parts of East Antarctica, seeds first -- colonies,
stations, islands as covered-areas on one fixed lattice, with the
discovery record, the effort record, and the design record all public
and replayable. The two open decisions (storage tile size, backfill
parallelization) are the ones to settle BEFORE onboarding the emperor
ring at scale, because both change what the big render produces and
how fast it happens -- and the recipe-not-payload architecture means
settling them late costs a re-render, not a redesign.
