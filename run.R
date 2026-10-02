# wildtiles headless driver. Invoked by run.sh:
#   Rscript run.R <run_id> <commit> <workdir>
#
# No special read access: state comes from the PUBLIC endpoints
# (runs/latest.json, index/inventory.parquet). Signed access only to
# write. Teardown/reboot stays a human, interactive act.
#
# Truncation-tolerant by design: a run is a TIME-BOXED ATTEMPT, not a
# unit of work. State (run record + inventory) advances monotonically
# at checkpoints, the day loop exits gracefully before any walltime
# limit (WILDTILES_DEADLINE, epoch seconds), and the inventory doubles
# as the existence cache so completed days cost zero network calls to
# skip. Being killed loses at most one checkpoint interval.

args <- commandArgs(trailingOnly = TRUE)
run_id <- args[1]; commit <- args[2]; workroot <- args[3]

library(dplyr)
repo <- dirname(normalizePath(sub("--file=", "",
                                  grep("--file=", commandArgs(), value = TRUE))))
source(file.path(repo, "R", "pipeline.R"))

bucket     <- Sys.getenv("WILDTILES_BUCKET", "wildtiles")
bucket_url <- sprintf("https://projects.pawsey.org.au/%s", bucket)
prefix     <- sprintf("/vsis3/%s", bucket)
store      <- file.path(workroot, "starc-store")   # synced by run.sh
workdir    <- file.path(workroot, "stage")
dir.create(workdir, showWarnings = FALSE, recursive = TRUE)

plan_t0        <- as.Date("2023-01-01")   # stepping back fills history
recheck_days   <- 14
checkpoint_every <- 25   # days rendered between mid-region checkpoints
provider   <- "https://earth-search.aws.element84.com/v1/search"
collection <- "sentinel-2-c1-l2a"

set_gdal_envs()

## --- modest parallelization: day-level workers --------------------------------
## A day is the unit of work (one block warp per band, then carving).
## Workers only warp, carve, and PUT cube files; ALL state (run record,
## inventory, checkpoints) stays in this main process. Each worker is a
## separate process, and GDAL config is process-local (3.13 snapshots at
## init), so every worker calls set_gdal_envs() for itself. Default 4 is
## deliberately modest: workers x 1 block warp = concurrent upstream
## streams against Element84.

workers  <- max(1L, as.integer(Sys.getenv("WILDTILES_WORKERS", "4")))
use_pool <- workers > 1L && requireNamespace("mirai", quietly = TRUE)
if (workers > 1L && !use_pool)
  message("mirai not available in this image: running serial")
if (use_pool) {
  mirai::daemons(workers)
  mirai::everywhere({
    source(file.path(repo, "R", "pipeline.R"))
    set_gdal_envs()
  }, repo = repo)
}

## --- deadline: exit gracefully before SLURM kills us ------------------------

deadline <- suppressWarnings(as.numeric(Sys.getenv("WILDTILES_DEADLINE", "")))
time_up <- function() {
  is.finite(deadline) && as.numeric(Sys.time()) > deadline - 600
}

## --- registry: repo copy mirrored to the bucket ------------------------------

regions <- read.csv(file.path(repo, "data", "regions.csv"))
rt <- file.path(workdir, "tiles.parquet")
arrow::write_parquet(do.call(rbind, lapply(SPECS, spec_tiles)), rt)
put_file_at(rt, sprintf("%s/registry/tiles.parquet", prefix))
writeLines(BAND_KEYS, bt <- file.path(workdir, "BANDS.txt"))
put_file_at(bt, sprintf("%s/registry/BANDS.txt", prefix))

## --- public state: run record and inventory, read up front -------------------

latest <- tryCatch(
  jsonlite::fromJSON(paste0(bucket_url, "/runs/latest.json"),
                     simplifyVector = FALSE),
  error = function(e) NULL)

complete_through <- function(region_id) {
  ct <- latest$regions[[region_id]]$complete_through
  if (is.null(ct)) plan_t0 - 1 else as.Date(ct)
}

## the inventory is BOTH the public index and the existence cache
inv <- tryCatch({
  tf <- tempfile(fileext = ".parquet")
  utils::download.file(paste0(bucket_url, "/index/inventory.parquet"),
                       tf, quiet = TRUE, mode = "wb")
  arrow::read_parquet(tf)
}, error = function(e) NULL)

## --- monotone state machinery -------------------------------------------------

report   <- list()
new_rows <- list()

write_state <- function(status) {
  rec <- list(run_id = run_id, commit = commit, started = run_id,
              updated = format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"),
              status = status,
              plan_t0 = format(plan_t0), recheck_days = recheck_days,
              bucket = bucket, regions = report)
  tf <- file.path(workdir, "run.json")
  writeLines(jsonlite::toJSON(rec, auto_unbox = TRUE, pretty = TRUE), tf)
  put_file_at(tf, sprintf("%s/runs/%s.json", prefix, run_id))
  put_file_at(tf, sprintf("%s/runs/latest.json", prefix))
}

flush_inventory <- function() {
  if (length(new_rows) == 0) return(invisible())
  inv <<- bind_rows(inv, bind_rows(new_rows)) |>
    distinct(tile_id, band, solarday, .keep_all = TRUE)
  new_rows <<- list()
  tf <- file.path(workdir, "inventory.parquet")
  arrow::write_parquet(inv, tf)
  put_file_at(tf, sprintf("%s/index/inventory.parquet", prefix))
}

## --- per region: top-up, plan, render -----------------------------------------

t1 <- format(Sys.Date() + 1)
timeboxed <- FALSE

for (sp in SPECS) {
  rid   <- sp$region_id
  tiles <- spec_tiles(sp)
  block <- spec_block(sp)
  ## plan the WHOLE window every run: the inventory certifies rendered
  ## days at zero network cost, so stepping plan_t0 back simply opens
  ## older history as pending backfill (the old complete_through clamp
  ## would have pinned us to the frontier forever)
  from  <- plan_t0

  q <- starc::harvest(regions[regions$region_id == rid, ],
                      provider, collection, format(from), t1,
                      store = store)
  message(sprintf("[%s] topup %s..%s: %s, %d items",
                  rid, from, t1, q$status, q$n_items))

  plan <- plan_region(rid, store, plan_t0) |> filter(solarday >= from)
  days <- sort(unique(plan$solarday))

  ## index certification: a day is complete when the inventory holds
  ## every (tile, band) for it -- zero network calls to skip it
  need <- nrow(tiles) * length(BAND_KEYS)
  certified <- as.Date(character())
  if (!is.null(inv) && length(days) > 0) {
    certified <- inv |>
      semi_join(tiles, by = "tile_id") |>
      filter(solarday %in% days) |>
      count(solarday) |>
      filter(n >= need) |>
      pull(solarday)
  }
  res <- data.frame(day = days,
                    status = ifelse(days %in% certified,
                                    "indexed", "pending"))
  message(sprintf("[%s] %d days planned, %d certified by index, %d to run",
                  rid, nrow(res), length(certified),
                  sum(res$status == "pending")))

  done_since_cp <- 0L
  record_day <- function(day, stx) {
    res$status[res$day == day] <<- stx
    message(sprintf("[%s] %s %s", rid, day, stx))
    if (stx %in% c("ok", "exists")) {
      ## "exists" rows too: the index self-heals for pre-index days
      new_rows[[length(new_rows) + 1]] <<- expand.grid(
        tile_id = tiles$tile_id, band = BAND_KEYS,
        stringsAsFactors = FALSE) |>
        mutate(solarday = day, run_id = run_id)
    }
    done_since_cp <<- done_since_cp + 1L
    if (done_since_cp >= checkpoint_every) {
      flush_inventory(); write_state("in-progress"); done_since_cp <<- 0L
    }
  }

  pending <- res$day[res$status == "pending"]
  if (!use_pool) {
    for (day in as.list(pending)) {
      if (time_up()) { timeboxed <- TRUE; break }
      dp <- filter(plan, solarday == day)
      record_day(day, build_day(dp, day, sp, tiles, block, prefix, workdir))
    }
  } else {
    ## keep up to `workers` days in flight; the deadline stops DISPATCH
    ## and in-flight days drain to completion (minutes, inside the
    ## deadline margin), so no work is half-recorded
    inflight <- list()
    i <- 1L
    while (length(inflight) > 0 ||
           (i <= length(pending) && !timeboxed)) {
      while (length(inflight) < workers && i <= length(pending) &&
             !timeboxed) {
        if (time_up()) { timeboxed <- TRUE; break }
        day <- pending[i]; i <- i + 1L
        dp <- filter(plan, solarday == day)
        inflight[[format(day)]] <- mirai::mirai(
          build_day(dp, day, sp, tiles, block, prefix, workdir),
          dp = dp, day = day, sp = sp, tiles = tiles, block = block,
          prefix = prefix, workdir = workdir)
      }
      if (length(inflight) == 0) next
      fin <- names(inflight)[!vapply(inflight, mirai::unresolved,
                                     logical(1))]
      if (length(fin) == 0) { Sys.sleep(0.5); next }
      for (nm in fin) {
        out <- inflight[[nm]]$data
        if (mirai::is_mirai_error(out) || !is.character(out)) {
          message(sprintf("[%s] %s worker error: %s", rid, nm,
                          paste(format(out), collapse = " ")))
          out <- "error"
        }
        record_day(as.Date(nm), out)
        inflight[[nm]] <- NULL
      }
    }
  }

  ## complete_through: last day before the first non-good status, so a
  ## failed or unreached day is retried (and all after it re-examined)
  good <- res$status %in% c("indexed", "ok", "exists")
  ct_new <- if (nrow(res) == 0) {
    complete_through(rid)
  } else if (all(good)) {
    max(res$day)
  } else {
    b1 <- min(which(!good))
    if (b1 > 1) res$day[b1 - 1] else from - 1
  }
  report[[rid]] <- list(
    from = format(from), days_planned = nrow(res),
    days_indexed = sum(res$status == "indexed"),
    days_ok = sum(res$status == "ok"),
    days_existing = sum(res$status == "exists"),
    days_failed = sum(!good & res$status != "pending"),
    days_unreached = sum(res$status == "pending"),
    complete_through = format(ct_new))

  flush_inventory(); write_state("in-progress")
  if (timeboxed) { message("[", rid, "] deadline reached"); break }
}

## --- summaries push -----------------------------------------------------------

for (f in list.files(file.path(workdir, "summaries"), full.names = TRUE)) {
  remote <- sprintf("%s/summaries/%s", prefix, basename(f))
  if (!gdalraster::vsi_stat(remote, "exists")) put_file_at(f, remote)
}

## --- final state ---------------------------------------------------------------

if (use_pool) mirai::daemons(0)
flush_inventory()
write_state(if (timeboxed) "timeboxed" else "completed")
message("run ", run_id, " ", if (timeboxed) "timeboxed" else "complete")

## audit_inventory(): rebuild index from a full listing (manual, occasional)
audit_inventory <- function() {
  keys <- grep("\\.tif$",
               gdalraster::vsi_read_dir(file.path(prefix, "cube"), recursive = TRUE),
               value = TRUE)
  p <- do.call(rbind, strsplit(keys, "/"))
  inv <- data.frame(tile_id = p[, 1], band = p[, 2],
                    solarday = as.Date(sub("\\.tif$", "", p[, 3])),
                    run_id = "audit")
  tf <- tempfile(fileext = ".parquet"); arrow::write_parquet(inv, tf)
  put_file_at(tf, sprintf("%s/index/inventory.parquet", prefix))
}
