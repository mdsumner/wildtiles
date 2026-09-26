# wildtiles headless driver. Invoked by run.sh:
#   Rscript run.R <run_id> <commit> <workdir>
#
# No special read access: state comes from the PUBLIC endpoints
# (runs/latest.json, index/inventory.parquet). Signed access only to
# write. Teardown/reboot stays a human, interactive act.

args <- commandArgs(trailingOnly = TRUE)
run_id <- args[1]; commit <- args[2]; workroot <- args[3]

library(dplyr)
repo <- dirname(normalizePath(sub("--file=", "",
  grep("--file=", commandArgs(), value = TRUE))))
source(file.path(repo, "R", "pipeline.R"))

bucket     <- Sys.getenv("WILDTILES_BUCKET", "tnbc")
bucket_url <- sprintf("https://projects.pawsey.org.au/%s", bucket)
prefix     <- sprintf("/vsis3/%s", bucket)
store      <- file.path(workroot, "starc-store")   # synced by run.sh
workdir    <- file.path(workroot, "stage")
dir.create(workdir, showWarnings = FALSE, recursive = TRUE)

plan_t0      <- as.Date("2024-01-01")
recheck_days <- 14
provider     <- "https://earth-search.aws.element84.com/v1/search"
collection   <- "sentinel-2-c1-l2a"

set_gdal_envs()

## registry is the repo's copy; the run mirrors it to the bucket
regions <- read.csv(file.path(repo, "data", "regions.csv"))
rt <- file.path(workdir, "tiles.parquet")
arrow::write_parquet(do.call(rbind, lapply(SPECS, spec_tiles)), rt)
put_file_at(rt, sprintf("%s/registry/tiles.parquet", prefix))
writeLines(BAND_KEYS, bt <- file.path(workdir, "BANDS.txt"))
put_file_at(bt, sprintf("%s/registry/BANDS.txt", prefix))

## --- public state ------------------------------------------------------------

latest <- tryCatch(
  jsonlite::fromJSON(paste0(bucket_url, "/runs/latest.json"),
                     simplifyVector = FALSE),
  error = function(e) NULL)

complete_through <- function(region_id) {
  ct <- latest$regions[[region_id]]$complete_through
  if (is.null(ct)) plan_t0 - 1 else as.Date(ct)
}

## --- per region: top-up, plan, render ---------------------------------------

t1 <- format(Sys.Date() + 1)
report <- list(); new_rows <- list()

for (sp in SPECS) {
  rid   <- sp$region_id
  tiles <- spec_tiles(sp)
  block <- spec_block(sp)
  from  <- max(plan_t0, complete_through(rid) - recheck_days + 1)

  q <- starc::harvest(regions[regions$region_id == rid, ],
                      provider, collection, format(from), t1,
                      store = store)
  message(sprintf("[%s] topup %s..%s: %s, %d items",
                  rid, from, t1, q$status, q$n_items))

  plan <- plan_region(rid, store, plan_t0) |> filter(solarday >= from)
  days <- sort(unique(plan$solarday))
  st   <- character(length(days))

  for (i in seq_along(days)) {
    dp <- filter(plan, solarday == days[i])
    st[i] <- build_day(dp, days[i], sp, tiles, block, prefix, workdir)
    message(sprintf("[%s] %s %s", rid, days[i], st[i]))
    if (st[i] == "ok") {
      new_rows[[length(new_rows) + 1]] <- expand.grid(
        tile_id = tiles$tile_id, band = BAND_KEYS,
        stringsAsFactors = FALSE) |>
        mutate(solarday = days[i], run_id = run_id)
    }
  }

  good <- st %in% c("ok", "exists")
  ct_new <- if (all(good)) {
    if (length(days)) max(days) else complete_through(rid)
  } else {
    bad1 <- min(which(!good)); if (bad1 > 1) days[bad1 - 1] else from - 1
  }
  report[[rid]] <- list(
    from = format(from), days_planned = length(days),
    days_ok = sum(st == "ok"), days_existing = sum(st == "exists"),
    days_failed = sum(!good), complete_through = format(ct_new))
}

## --- inventory increment -----------------------------------------------------

inv_old <- tryCatch({
  tf <- tempfile(fileext = ".parquet")
  utils::download.file(paste0(bucket_url, "/index/inventory.parquet"),
                       tf, quiet = TRUE, mode = "wb")
  arrow::read_parquet(tf)
}, error = function(e) NULL)

if (length(new_rows) > 0 || is.null(inv_old)) {
  inv <- bind_rows(inv_old, bind_rows(new_rows)) |>
    distinct(tile_id, band, solarday, .keep_all = TRUE)
  tf <- file.path(workdir, "inventory.parquet")
  arrow::write_parquet(inv, tf)
  put_file_at(tf, sprintf("%s/index/inventory.parquet", prefix))
}

## --- summaries push ----------------------------------------------------------

for (f in list.files(file.path(workdir, "summaries"), full.names = TRUE)) {
  remote <- sprintf("%s/summaries/%s", prefix, basename(f))
  if (!gdalraster::vsi_stat(remote, "exists")) put_file_at(f, remote)
}

## --- run record, written LAST ------------------------------------------------

rec <- list(run_id = run_id, commit = commit, started = run_id,
            completed = format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"),
            plan_t0 = format(plan_t0), recheck_days = recheck_days,
            bucket = bucket, regions = report,
            n_inventory_rows_added = sum(vapply(new_rows, nrow,
                                                integer(1))))
tf <- file.path(workdir, "run.json")
writeLines(jsonlite::toJSON(rec, auto_unbox = TRUE, pretty = TRUE), tf)
put_file_at(tf, sprintf("%s/runs/%s.json", prefix, run_id))
put_file_at(tf, sprintf("%s/runs/latest.json", prefix))
message("run ", run_id, " complete")

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
