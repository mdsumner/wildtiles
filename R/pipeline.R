# wildtiles pipeline definitions. Nothing executes on source.
#
# Grid constants mirror aatgrid (GRID_ORIGIN, PIXELS_PER_TILE); replace
# with aatgrid:: imports once the container pins aatgrid.

OX <- 140000; OY <- 20000; NPIX <- 720L

BAND_KEYS <- c("red", "green", "blue", "nir", "nir08", "nir09", "coastal",
               "rededge1", "rededge2", "rededge3", "swir16", "swir22",
               "aot", "wvp", "scl", "cloud", "snow", "visual")

NOSTAT_KEYS <- c("visual")

## the survey design in force (registry migration will retire this).
## Indices are on the 720-pixel lattice: tile_size(10) = 7200 m,
## tile_size(60) = 43200 m. Derived in code from region coordinates
## (pyproj densified transforms), never retyped:
##   auster    colony E540796 N2523234 (41S) -> L2 (55, 347), 3x3 block
##   heard     coast bbox densified     (43S) -> L1 cols 4:6 rows 94:95
##   macquarie station E496011 N3960989 (57S) -> L2 (49, 547), 3x3 block
SPECS <- list(
  list(region_id = "auster",         zone = 41L, res = 10,
       cols = 54:56, rows = 346:348),
  list(region_id = "heard_mcdonald", zone = 43L, res = 60,
       cols = 4:6,   rows = 94:95),
  list(region_id = "macquarie_island_south", zone = 57L, res = 10,
       cols = 48:50, rows = 546:548)
)

tile_extent <- function(col, row, res) {
  ts <- NPIX * res
  c(xmin = OX + col * ts, xmax = OX + (col + 1) * ts,
    ymin = OY + row * ts, ymax = OY + (row + 1) * ts)
}

spec_tiles <- function(sp) {
  g <- expand.grid(col = sp$cols, row = sp$rows)
  ex <- t(mapply(tile_extent, g$col, g$row, MoreArgs = list(res = sp$res)))
  data.frame(
    tile_id = sprintf("%02dS_R%04d_%04d_%04d", sp$zone, sp$res, g$col, g$row),
    region_id = sp$region_id,
    zone_epsg = sprintf("EPSG:327%02d", sp$zone),
    res = sp$res, col = g$col, row = g$row, ex)
}

spec_block <- function(sp) {
  ts <- NPIX * sp$res
  c(xmin = OX + min(sp$cols) * ts, xmax = OX + (max(sp$cols) + 1) * ts,
    ymin = OY + min(sp$rows) * ts, ymax = OY + (max(sp$rows) + 1) * ts)
}

#' GDAL config for signed Pawsey S3. Config store, not env: GDAL
#' snapshots the environment at init, and a global no-sign in a gdalrc
#' outranks env -- we assert our intent explicitly (Sep 2026).
set_gdal_envs <- function() {
  key <- Sys.getenv("PAWSEY_AWS_ACCESS_KEY_ID")
  sec <- Sys.getenv("PAWSEY_AWS_SECRET_ACCESS_KEY")
  if (!nzchar(key) || !nzchar(sec)) {
    stop("PAWSEY_AWS_* credentials not set in this session")
  }
  if (nchar(key) < 16 || nchar(sec) < 16) {
    stop("PAWSEY_AWS_* look like placeholders, not credentials")
  }
  opts <- c(
    AWS_ACCESS_KEY_ID = key,
    AWS_SECRET_ACCESS_KEY = sec,
    AWS_S3_ENDPOINT = "projects.pawsey.org.au",
    AWS_VIRTUAL_HOSTING = "NO",
    AWS_NO_SIGN_REQUEST = "NO",
    CPL_VSIL_USE_TEMP_FILE_FOR_RANDOM_WRITE = "YES",
    GDAL_HTTP_MAX_RETRY = "4",
    GDAL_HTTP_RETRY_DELAY = "10"
  )
  for (nm in names(opts)) gdalraster::set_config_option(nm, opts[[nm]])
  gdalraster::vsi_curl_clear_cache()
}

put_file_at <- function(local, remote) {
  con <- new(gdalraster::VSIFile, local, "r")
  bytes <- con$ingest(-1); con$close()
  con1 <- new(gdalraster::VSIFile, remote, "w")
  con1$write(bytes); con1$close()
  if (!gdalraster::vsi_stat(remote, "exists")) stop("put failed: ", remote)
  invisible(TRUE)
}

band_path <- function(prefix, tile_id, band, day) {
  sprintf("%s/cube/%s/%s/%s.tif", prefix, tile_id, band, day)
}

plan_region <- function(region_id, store, plan_t0) {
  q <- arrow::open_dataset(file.path(store, "queries")) |>
    dplyr::select(query_id, region_id) |> dplyr::collect() |>
    dplyr::filter(region_id == !!region_id)
  p <- arrow::open_dataset(file.path(store, "products")) |>
    dplyr::select(product_id, acquisition_id, query_id) |>
    dplyr::collect() |>
    dplyr::semi_join(q, by = "query_id") |>
    dplyr::distinct(product_id, .keep_all = TRUE)
  a <- arrow::open_dataset(file.path(store, "acquisitions")) |>
    dplyr::select(acquisition_id, solarday) |> dplyr::collect() |>
    dplyr::distinct(acquisition_id, .keep_all = TRUE)
  s <- arrow::open_dataset(file.path(store, "assets")) |>
    dplyr::select(product_id, asset_key, href) |> dplyr::collect() |>
    dplyr::semi_join(p, by = "product_id") |>
    dplyr::filter(asset_key %in% BAND_KEYS)
  p |> dplyr::inner_join(a, by = "acquisition_id") |>
    dplyr::inner_join(s, by = "product_id",
                      relationship = "many-to-many") |>
    dplyr::filter(solarday >= as.Date(plan_t0))
}

warp_band_to_block <- function(hrefs, block, epsg, res, workdir) {
  tf <- tempfile(fileext = ".tif", tmpdir = workdir)
  ok <- try(gdalraster::warp(
    paste0("/vsicurl/", hrefs), tf, t_srs = epsg,
    cl_arg = c("-te", block[c("xmin", "ymin", "xmax", "ymax")],
               "-tr", res, res, "-r", "near"),
    quiet = TRUE), silent = TRUE)
  if (inherits(ok, "try-error")) NA_character_ else tf
}

summarise_band <- function(tif, tile_id, band, day) {
  ds <- new(gdalraster::GDALRaster, tif)
  on.exit(ds$close(), add = TRUE)
  stopifnot(ds$getRasterXSize() == NPIX, ds$getRasterYSize() == NPIX)
  v <- ds$read(band = 1, xoff = 0, yoff = 0, xsize = NPIX, ysize = NPIX,
               out_xsize = NPIX, out_ysize = NPIX)
  v <- v[!is.na(v) & v > 0]
  data.frame(tile_id = tile_id, solarday = day, band = band,
             n_valid = length(v),
             mean = if (length(v)) mean(v) else NA_real_,
             sd   = if (length(v) > 1) stats::sd(v) else NA_real_,
             q05  = if (length(v)) unname(stats::quantile(v, .05)) else NA_real_,
             q50  = if (length(v)) unname(stats::quantile(v, .50)) else NA_real_,
             q95  = if (length(v)) unname(stats::quantile(v, .95)) else NA_real_)
}

#' Render one solarday for one region spec: warp per band to the block,
#' carve per-tile single-band COGs, ship, summarise. Returns a status
#' string; writes a per-(region, day) summaries parquet under workdir.
build_day <- function(day_plan, day, sp, tiles, block, prefix, workdir) {
  todo <- expand.grid(t = seq_len(nrow(tiles)), band = BAND_KEYS,
                      stringsAsFactors = FALSE)
  todo$remote <- band_path(prefix, tiles$tile_id[todo$t], todo$band, day)
  todo$exists <- vapply(todo$remote, gdalraster::vsi_stat, logical(1),
                        "exists")
  if (all(todo$exists)) return("exists")

  srows <- list()
  for (k in BAND_KEYS) {
    sub <- todo[todo$band == k & !todo$exists, ]
    if (nrow(sub) < 1) next
    hr <- day_plan$href[day_plan$asset_key == k]
    if (length(hr) < 1) return("missing-band")
    btif <- warp_band_to_block(hr, block,
                               sprintf("EPSG:327%02d", sp$zone),
                               sp$res, workdir)
    if (is.na(btif)) return("warp-failed")
    for (t in sub$t) {
      xoff <- (tiles$xmin[t] - block[["xmin"]]) / sp$res
      yoff <- (block[["ymax"]] - tiles$ymax[t]) / sp$res
      tt <- tempfile(fileext = ".tif", tmpdir = workdir)
      gdalraster::translate(btif, tt,
        cl_arg = c("-srcwin", xoff, yoff, NPIX, NPIX,
                   "-of", "COG", "-co", "COMPRESS=DEFLATE"),
        quiet = TRUE)
      put_file_at(tt, band_path(prefix, tiles$tile_id[t], k, day))
      if (!k %in% NOSTAT_KEYS) {
        srows[[length(srows) + 1]] <- summarise_band(tt, tiles$tile_id[t],
                                                   k, day)
      }
      unlink(tt)
    }
    unlink(btif)
  }
  if (length(srows) > 0) {
    sdir <- file.path(workdir, "summaries")
    dir.create(sdir, recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(dplyr::bind_rows(srows),
      file.path(sdir, sprintf("%s_%s.parquet", sp$region_id, day)))
  }
  "ok"
}
