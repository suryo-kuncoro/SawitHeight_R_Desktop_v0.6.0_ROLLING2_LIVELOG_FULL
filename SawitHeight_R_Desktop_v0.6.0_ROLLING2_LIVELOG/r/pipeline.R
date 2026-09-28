options(warn = 1)

args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args) >= 1) args[[1]] else 'run'
config_path <- if (length(args) >= 2) args[[2]] else NA_character_

if (!requireNamespace('jsonlite', quietly = TRUE)) {
  cat('APP_EVENT:{"type":"fatal","stage":"bootstrap","message":"Package jsonlite tidak tersedia."}\n')
  quit(status = 10)
}

suppressPackageStartupMessages({
  library(lidR)
  library(sf)
  library(terra)
  library(dplyr)
})

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || all(is.na(a))) b else a
as_num <- function(x, default = NA_real_) { y <- suppressWarnings(as.numeric(x)); if (!length(y) || !is.finite(y[1])) default else y[1] }
as_int <- function(x, default = NA_integer_) { y <- suppressWarnings(as.integer(x)); if (!length(y) || is.na(y[1])) default else y[1] }
as_bool <- function(x, default = FALSE) { if (is.null(x) || !length(x) || is.na(x[1])) default else isTRUE(as.logical(x[1])) }
clean_period <- function(x) {
  x <- toupper(gsub('[^A-Z0-9]', '', as.character(x %||% '')))
  if (!nzchar(x) || nchar(x) > 3) stop('Kode periode harus 1-3 karakter huruf/angka.', call. = FALSE)
  x
}

emit <- function(type, ..., .list = list()) {
  payload <- c(list(type = type, timestamp = format(Sys.time(), '%Y-%m-%dT%H:%M:%S')), list(...), .list)
  cat('APP_EVENT:', jsonlite::toJSON(payload, auto_unbox = TRUE, null = 'null', na = 'null'), '\n', sep = '')
  try(flush(stdout()), silent = TRUE)
  flush.console()
}

if (is.na(config_path) || !file.exists(config_path)) {
  emit('fatal', stage = 'bootstrap', message = 'Config JSON tidak ditemukan.')
  quit(status = 10)
}

cfg <- jsonlite::fromJSON(config_path, simplifyVector = FALSE)
inputs <- cfg$inputs %||% list()
p <- cfg$parameters %||% list()
run_dir <- normalizePath(cfg$app$run_dir %||% dirname(config_path), winslash = '/', mustWork = FALSE)
dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
shp_dir <- file.path(run_dir, 'shapefile')
qc_dir <- file.path(run_dir, 'qc')
dir.create(shp_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(qc_dir, recursive = TRUE, showWarnings = FALSE)
log_path <- file.path(run_dir, 'analysis.log')
if (file.exists(log_path)) file.remove(log_path)
current_stage <- 'bootstrap'

write_log <- function(level = 'INFO', message) {
  stamp <- format(Sys.time(), '%Y-%m-%d %H:%M:%S')
  line <- sprintf('[%s] [%s] [%s] %s', stamp, level, current_stage, message)
  cat(line, '\n', file = log_path, append = TRUE)
  emit('log', level = tolower(level), stage = current_stage, message = message)
}

set_stage <- function(stage, label, progress, detail = NULL) {
  current_stage <<- stage
  write_log('INFO', paste0('Tahap: ', label))
  emit('progress', stage = stage, label = label, progress = as.numeric(progress), detail = detail)
}

progress_event <- function(stage, label, progress, detail = NULL) {
  emit('progress', stage = stage, label = label, progress = as.numeric(progress), detail = detail)
}

stop_run <- function(...) stop(paste0(...), call. = FALSE)

safe_write_sf <- function(x, path) {
  if (file.exists(path)) try(unlink(path), silent = TRUE)
  suppressWarnings(sf::st_write(x, path, delete_layer = TRUE, quiet = TRUE))
}

file_ok <- function(x) is.character(x) && length(x) && nzchar(x[1]) && file.exists(x[1])

get_las_bbox <- function(las) {
  c(xmin = min(las$X, na.rm = TRUE), xmax = max(las$X, na.rm = TRUE), ymin = min(las$Y, na.rm = TRUE), ymax = max(las$Y, na.rm = TRUE))
}

bbox_overlap_ratio <- function(a, b) {
  ix <- max(0, min(a[['xmax']], b[['xmax']]) - max(a[['xmin']], b[['xmin']]))
  iy <- max(0, min(a[['ymax']], b[['ymax']]) - max(a[['ymin']], b[['ymin']]))
  inter <- ix * iy
  area_a <- max(0, a[['xmax']] - a[['xmin']]) * max(0, a[['ymax']] - a[['ymin']])
  area_b <- max(0, b[['xmax']] - b[['xmin']]) * max(0, b[['ymax']] - b[['ymin']])
  denom <- min(area_a, area_b)
  if (!is.finite(denom) || denom <= 0) return(0)
  inter / denom
}

low_fence <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) < 4L) return(0)
  max(0, as.numeric(stats::quantile(x, 0.25, na.rm = TRUE, names = FALSE)) - 1.5 * stats::IQR(x, na.rm = TRUE))
}

upper_fence <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) < 4L) return(Inf)
  as.numeric(stats::quantile(x, 0.75, na.rm = TRUE, names = FALSE)) + 1.5 * stats::IQR(x, na.rm = TRUE)
}

top_mean <- function(z, prop) {
  z <- z[is.finite(z)]
  if (!length(z)) return(NA_real_)
  z <- sort(z, decreasing = TRUE)
  n <- max(1L, ceiling(length(z) * prop))
  mean(z[seq_len(n)], na.rm = TRUE)
}

metrics_one_clip <- function(clip, min_veg_h) {
  if (is.null(clip)) return(data.frame(n_all = 0L, n_veg = 0L, veg_ratio = NA_real_, p95 = NA_real_, p99 = NA_real_, top10 = NA_real_, top20 = NA_real_, top30 = NA_real_))
  n_i <- tryCatch(npoints(clip), error = function(e) 0L)
  if (!is.finite(n_i) || n_i <= 0L) return(data.frame(n_all = 0L, n_veg = 0L, veg_ratio = NA_real_, p95 = NA_real_, p99 = NA_real_, top10 = NA_real_, top20 = NA_real_, top30 = NA_real_))
  z_all <- clip$Z[is.finite(clip$Z)]
  z_veg <- z_all[z_all >= min_veg_h]
  if (!length(z_all)) return(data.frame(n_all = 0L, n_veg = 0L, veg_ratio = NA_real_, p95 = NA_real_, p99 = NA_real_, top10 = NA_real_, top20 = NA_real_, top30 = NA_real_))
  if (!length(z_veg)) return(data.frame(n_all = length(z_all), n_veg = 0L, veg_ratio = 0, p95 = NA_real_, p99 = NA_real_, top10 = NA_real_, top20 = NA_real_, top30 = NA_real_))
  data.frame(
    n_all = as.integer(length(z_all)),
    n_veg = as.integer(length(z_veg)),
    veg_ratio = length(z_veg) / length(z_all),
    p95 = as.numeric(stats::quantile(z_veg, 0.95, na.rm = TRUE, names = FALSE)),
    p99 = as.numeric(stats::quantile(z_veg, 0.99, na.rm = TRUE, names = FALSE)),
    top10 = top_mean(z_veg, 0.10),
    top20 = top_mean(z_veg, 0.20),
    top30 = top_mean(z_veg, 0.30)
  )
}

metrics_all_trees <- function(las, coords, min_veg_h, radius, chunk_size, label, stage, p0, p1) {
  n <- nrow(coords)
  out <- vector('list', n)
  starts <- seq.int(1L, n, by = max(1L, chunk_size))
  for (s in starts) {
    e <- min(n, s + chunk_size - 1L)
    ix <- s:e
    clips <- tryCatch(
      clip_circle(las, xcenter = coords[ix, 1], ycenter = coords[ix, 2], radius = radius),
      error = function(err) NULL
    )
    vector_ok <- is.list(clips) && length(clips) == length(ix)
    if (!vector_ok) {
      clips <- vector('list', length(ix))
      for (j in seq_along(ix)) {
        k <- ix[j]
        clips[[j]] <- tryCatch(clip_circle(las, xcenter = coords[k, 1], ycenter = coords[k, 2], radius = radius), error = function(err) NULL)
      }
    }
    vals <- lapply(clips, metrics_one_clip, min_veg_h = min_veg_h)
    out[ix] <- vals
    frac <- e / n
    pct <- p0 + (p1 - p0) * frac
    detail <- sprintf('%s: %s / %s TREE_ID (%.1f%%)', label, format(e, big.mark = ','), format(n, big.mark = ','), frac * 100)
    write_log('INFO', detail)
    progress_event(stage, label, pct, detail)
  }
  dplyr::bind_rows(out)
}

presence_support <- function(m) {
  cuts <- list(n_all = low_fence(m$n_all), n_veg = low_fence(m$n_veg), ratio = low_fence(m$veg_ratio))
  data_ok <- is.finite(m$n_all) & m$n_all >= cuts$n_all
  canopy <- is.finite(m$p95) & is.finite(m$n_veg) & is.finite(m$veg_ratio) & m$n_veg >= cuts$n_veg & m$veg_ratio >= cuts$ratio
  list(flags = data.frame(data_ok = data_ok, canopy_support = canopy), cuts = cuts)
}

safe_metric_spread <- function(v) {
  v <- v[is.finite(v)]
  if (length(v) < 2L) return(NA_real_)
  max(v) - min(v)
}

safe_n_negative <- function(v) {
  v <- v[is.finite(v)]
  if (!length(v)) return(0L)
  sum(v < 0)
}

sample_ground_df <- function(ground, max_points = 0L, seed = 42L) {
  n <- npoints(ground)
  if (n <= 0L) return(data.frame())
  idx <- seq_len(n)
  if (is.finite(max_points) && max_points > 0L && n > max_points) {
    set.seed(seed)
    idx <- sort(sample(idx, max_points))
  }
  data.frame(X = ground$X[idx], Y = ground$Y[idx], Z = ground$Z[idx])
}

terrain_holdout_qc <- function(las_grounded, dtm_res, train_frac, seed, min_ground, max_ground) {
  ground <- filter_ground(las_grounded)
  n_total <- npoints(ground)
  if (n_total < min_ground) return(data.frame(n_ground = n_total, n_used = n_total, rmse = NA_real_, median = NA_real_, nmad = NA_real_, p95_abs = NA_real_, method = 'HOLDOUT_CSF'))
  gdf <- sample_ground_df(ground, max_ground, seed)
  if (nrow(gdf) < min_ground) return(data.frame(n_ground = n_total, n_used = nrow(gdf), rmse = NA_real_, median = NA_real_, nmad = NA_real_, p95_abs = NA_real_, method = 'HOLDOUT_CSF'))
  set.seed(seed)
  n_train <- max(3L, floor(train_frac * nrow(gdf)))
  idx <- sample(seq_len(nrow(gdf)), size = n_train)
  train_xyz <- gdf[idx, , drop = FALSE]
  test_xyz <- gdf[-idx, , drop = FALSE]
  if (nrow(test_xyz) < 3L) return(data.frame(n_ground = n_total, n_used = nrow(gdf), rmse = NA_real_, median = NA_real_, nmad = NA_real_, p95_abs = NA_real_, method = 'HOLDOUT_CSF'))
  train_las <- LAS(data.frame(X = train_xyz$X, Y = train_xyz$Y, Z = train_xyz$Z, Classification = 2L))
  st_crs(train_las) <- st_crs(las_grounded)
  dtm_train <- rasterize_terrain(train_las, res = dtm_res, algorithm = tin())
  test_vect <- terra::vect(test_xyz, geom = c('X', 'Y'), crs = terra::crs(dtm_train))
  zhat <- terra::extract(dtm_train, test_vect)[, 2]
  r <- test_xyz$Z - zhat
  r <- r[is.finite(r)]
  if (length(r) < 3L) return(data.frame(n_ground = n_total, n_used = nrow(gdf), rmse = NA_real_, median = NA_real_, nmad = NA_real_, p95_abs = NA_real_, method = 'HOLDOUT_CSF'))
  med <- stats::median(r)
  r0 <- r - med
  data.frame(
    n_ground = n_total,
    n_used = nrow(gdf),
    rmse = sqrt(mean(r0^2)),
    median = med,
    nmad = 1.4826 * stats::median(abs(r0)),
    p95_abs = as.numeric(stats::quantile(abs(r0), 0.95, names = FALSE)),
    method = 'HOLDOUT_CSF'
  )
}

terrain_external_qc <- function(las_grounded, dtm, min_ground, max_ground, seed) {
  ground <- filter_ground(las_grounded)
  n_total <- npoints(ground)
  if (n_total < min_ground) return(data.frame(n_ground = n_total, n_used = n_total, rmse = NA_real_, median = NA_real_, nmad = NA_real_, p95_abs = NA_real_, method = 'GROUND_VS_EXTERNAL'))
  gdf <- sample_ground_df(ground, max_ground, seed)
  v <- terra::vect(gdf, geom = c('X', 'Y'), crs = terra::crs(dtm))
  zhat <- terra::extract(dtm, v)[, 2]
  r <- gdf$Z - zhat
  r <- r[is.finite(r)]
  if (length(r) < 3L) return(data.frame(n_ground = n_total, n_used = nrow(gdf), rmse = NA_real_, median = NA_real_, nmad = NA_real_, p95_abs = NA_real_, method = 'GROUND_VS_EXTERNAL'))
  med <- stats::median(r)
  r0 <- r - med
  data.frame(
    n_ground = n_total,
    n_used = nrow(gdf),
    rmse = sqrt(mean(r0^2)),
    median = med,
    nmad = 1.4826 * stats::median(abs(r0)),
    p95_abs = as.numeric(stats::quantile(abs(r0), 0.95, names = FALSE)),
    method = 'GROUND_VS_EXTERNAL'
  )
}

ensure_dtm_crs <- function(dtm, las_crs, label) {
  dcrs <- sf::st_crs(terra::crs(dtm))
  if (is.na(dcrs)) stop_run('CRS ', label, ' kosong.')
  if (!identical(las_crs$wkt, dcrs$wkt)) stop_run('CRS ', label, ' berbeda dengan LAS. Samakan CRS terlebih dahulu; aplikasi tidak melakukan reprojection otomatis.')
}

make_html_report <- function(summary, preview, path) {
  esc <- function(x) { x <- as.character(x); x <- gsub('&', '&amp;', x, fixed=TRUE); x <- gsub('<', '&lt;', x, fixed=TRUE); x <- gsub('>', '&gt;', x, fixed=TRUE); x }
  rows <- paste0('<tr><th>', esc(names(summary)[vapply(summary, function(x) length(x) == 1L && !is.list(x), logical(1))]), '</th><td>', esc(vapply(summary[vapply(summary, function(x) length(x) == 1L && !is.list(x), logical(1))], function(x) ifelse(is.null(x) || is.na(x), '', as.character(x)), character(1))), '</td></tr>', collapse = '')
  preview_html <- ''
  if (nrow(preview)) {
    headrow <- paste0('<th>', esc(names(preview)), '</th>', collapse = '')
    body <- apply(preview, 1, function(r) paste0('<tr>', paste0('<td>', esc(r), '</td>', collapse = ''), '</tr>'))
    preview_html <- paste0('<h2>Preview TREE_ID</h2><table><thead><tr>', headrow, '</tr></thead><tbody>', paste(body, collapse = ''), '</tbody></table>')
  }
  html <- paste0('<!doctype html><html><head><meta charset="utf-8"><title>MAS POPO Report</title><style>body{font-family:Segoe UI,Arial;background:#0b0f11;color:#e7edee;padding:30px}h1,h2{color:#e3a73f}table{border-collapse:collapse;width:100%;margin:15px 0}th,td{border:1px solid #263135;padding:8px;text-align:left}th{background:#171f22;color:#e3a73f}p{color:#8fa0a4}</style></head><body><h1>MAS POPO Rolling 2-Period v0.6.0</h1><p>P95 relative height · terrain QC · technical uncertainty · peer-based residual.</p><table>', rows, '</table>', preview_html, '</body></html>')
  writeLines(html, path, useBytes = TRUE)
}

validate_config <- function(deep = FALSE) {
  set_stage('validation', 'Validasi konfigurasi', 2)
  prev_file <- as.character(inputs$prev_point_cloud %||% '')
  curr_file <- as.character(inputs$curr_point_cloud %||% '')
  tree_file <- as.character(inputs$tree_points %||% '')
  out_root <- as.character(inputs$output_root %||% '')
  if (!file_ok(prev_file)) stop_run('Point cloud periode sebelumnya tidak ditemukan.')
  if (!file_ok(curr_file)) stop_run('Point cloud periode saat ini tidak ditemukan.')
  if (!file_ok(tree_file)) stop_run('Titik pokok tidak ditemukan.')
  if (!nzchar(out_root)) stop_run('Folder output belum ditentukan.')
  prev_period <- clean_period(p$prev_period_code)
  curr_period <- clean_period(p$curr_period_code)
  if (prev_period == curr_period) stop_run('Kode periode sebelumnya dan saat ini tidak boleh sama.')
  if (!nzchar(as.character(p$tree_id_field %||% ''))) stop_run('Field TREE_ID belum diisi.')
  if (!as_bool(p$registration_qc_confirmed, FALSE)) stop_run('Spatial Registration QC belum dikonfirmasi.')
  for (side in c('prev', 'curr')) {
    tm <- toupper(as.character(p[[paste0('terrain_mode_', side)]] %||% 'CSF_TIN'))
    if (!(tm %in% c('CSF_TIN', 'EXTERNAL_DTM'))) stop_run('Terrain mode ', side, ' tidak valid.')
    if (tm == 'EXTERNAL_DTM' && !file_ok(inputs[[paste0('external_dtm_', side)]])) stop_run('External DTM ', side, ' tidak ditemukan.')
  }
  if (deep) {
    trees <- suppressWarnings(sf::st_read(tree_file, quiet = TRUE))
    id_field <- as.character(p$tree_id_field)
    if (!(id_field %in% names(trees))) stop_run('Field ID pohon tidak ditemukan pada data titik: ', id_field)
    if (any(is.na(trees[[id_field]]))) stop_run('TREE_ID memiliki nilai NA/kosong.')
    if (anyDuplicated(trees[[id_field]]) > 0L) stop_run('TREE_ID tidak unik.')
    gtype <- unique(as.character(sf::st_geometry_type(trees)))
    if (!all(gtype %in% c('POINT', 'MULTIPOINT'))) stop_run('TREE_FILE harus POINT/MULTIPOINT.')
    peer_field <- trimws(as.character(p$peer_field %||% ''))
    if (nzchar(peer_field) && !(peer_field %in% names(trees))) stop_run('Peer group field tidak ditemukan: ', peer_field)
    emit('validation-result', status = 'success', message = paste('Validasi berhasil;', nrow(trees), 'TREE_ID siap diproses.'), tree_count = nrow(trees))
  }
  invisible(TRUE)
}

run_pipeline <- function() {
  validate_config(FALSE)
  PREV <- clean_period(p$prev_period_code)
  CURR <- clean_period(p$curr_period_code)
  id_field <- as.character(p$tree_id_field)
  peer_field <- trimws(as.character(p$peer_field %||% ''))
  buffer_m <- as_num(p$buffer_radius_m, 2.0)
  min_veg_h <- as_num(p$min_veg_h_m, 0.30)
  dtm_res <- as_num(p$dtm_resolution_m, 0.5)
  train_frac <- as_num(p$holdout_train_frac, 0.80)
  hold_seed <- as_int(p$holdout_seed, 42L)
  min_ground <- as_int(p$holdout_min_ground, 100L)
  max_ground <- as_int(p$holdout_max_ground, 0L)
  chunk_size <- as_int(p$metrics_chunk_size, 250L)
  threads <- as_int(p$threads, 4L)
  try(lidR::set_lidr_threads(threads), silent = TRUE)

  set_stage('load', paste('Load point cloud ', PREV, ' & ', CURR), 5)
  write_log('INFO', paste('Load PREV:', inputs$prev_point_cloud))
  las_prev <- readLAS(inputs$prev_point_cloud)
  if (is.null(las_prev) || npoints(las_prev) == 0L) stop_run('Point cloud PREV kosong/gagal dibaca.')
  write_log('INFO', paste('Load CURR:', inputs$curr_point_cloud))
  las_curr <- readLAS(inputs$curr_point_cloud)
  if (is.null(las_curr) || npoints(las_curr) == 0L) stop_run('Point cloud CURR kosong/gagal dibaca.')
  input_prev_n <- npoints(las_prev); input_curr_n <- npoints(las_curr)
  write_log('INFO', paste('PREV points:', format(input_prev_n, big.mark = ',')))
  write_log('INFO', paste('CURR points:', format(input_curr_n, big.mark = ',')))

  epsg <- as_int(p$fallback_epsg, 0L)
  if (is.na(st_crs(las_prev)) && epsg > 0L) st_crs(las_prev) <- epsg
  if (is.na(st_crs(las_curr)) && epsg > 0L) st_crs(las_curr) <- epsg
  if (is.na(st_crs(las_prev)) || is.na(st_crs(las_curr))) stop_run('CRS salah satu LAS kosong. Isi fallback EPSG yang benar.')
  if (!identical(st_crs(las_prev)$wkt, st_crs(las_curr)$wkt)) stop_run('CRS dua LAS berbeda. Samakan CRS terlebih dahulu.')
  if (isTRUE(st_is_longlat(st_crs(las_prev)))) stop_run('Gunakan CRS proyeksi meter sebelum buffer 2 m.')
  bb_prev <- get_las_bbox(las_prev); bb_curr <- get_las_bbox(las_curr)
  overlap <- bbox_overlap_ratio(bb_prev, bb_curr)
  write_log('INFO', sprintf('BBox overlap ratio terhadap area lebih kecil: %.1f%%', overlap * 100))
  if (overlap < 0.25) write_log('WARNING', 'Overlap spatial dua LAS rendah. Pastikan pair memang area yang sama.')

  qc_one <- function(las, label) {
    n0 <- npoints(las)
    if (as_bool(p$remove_duplicates, TRUE)) {
      write_log('INFO', paste(label, '- hapus duplikat dimulai.'))
      las <- filter_duplicates(las)
      write_log('INFO', paste(label, '- duplikat dibuang:', format(n0 - npoints(las), big.mark = ',')))
    }
    if (as_bool(p$run_noise_filter, TRUE)) {
      write_log('INFO', paste(label, '- SOR noise filtering dimulai.'))
      n_before <- npoints(las)
      las <- tryCatch({ tmp <- classify_noise(las, sor(k = as_int(p$sor_k, 10L), m = as_num(p$sor_m, 3))); filter_poi(tmp, Classification != 18L) }, error = function(e) { write_log('WARNING', paste(label, '- noise filter gagal/dilewati:', conditionMessage(e))); las })
      write_log('INFO', paste(label, '- noise points dibuang:', format(n_before - npoints(las), big.mark = ',')))
    }
    write_log('INFO', paste(label, '- menghitung density raster 1 m.'))
    dens <- rasterize_density(las, res = 1)
    avg <- tryCatch(as.numeric(terra::global(dens, 'mean', na.rm = TRUE)[1,1]), error = function(e) NA_real_)
    write_log('INFO', paste(label, '- average density:', round(avg, 2), 'points/m2'))
    list(las = las, density = dens, avg_density = avg)
  }

  set_stage('qc', 'QC point cloud dua periode', 10)
  qc_prev <- qc_one(las_prev, PREV); las_prev <- qc_prev$las
  progress_event('qc', 'QC point cloud dua periode', 14, paste('QC', PREV, 'selesai.'))
  qc_curr <- qc_one(las_curr, CURR); las_curr <- qc_curr$las
  progress_event('qc', 'QC point cloud dua periode', 18, paste('QC', CURR, 'selesai.'))

  set_stage('registration', 'Spatial registration audit', 20)
  if (as_bool(p$use_master_reference, FALSE)) {
    master_period <- clean_period(p$master_period_code)
    write_log('INFO', paste('Master registration metadata:', master_period))
    if (file_ok(inputs$master_point_cloud)) write_log('INFO', paste('Master LAS/LAZ (audit only):', inputs$master_point_cloud))
  } else write_log('INFO', 'Master registration tidak digunakan; rolling pair diasumsikan sudah berada pada frame yang sama berdasarkan konfirmasi pengguna.')
  write_log('INFO', 'Tidak ada ICP/transformasi otomatis di aplikasi. Registration harus divalidasi pada stable features di workflow point-cloud dedicated bila diperlukan.')

  trees <- suppressWarnings(st_read(inputs$tree_points, quiet = TRUE))
  if (!(id_field %in% names(trees))) stop_run('Field ID pohon tidak ditemukan pada data titik: ', id_field)
  if (any(is.na(trees[[id_field]])) || anyDuplicated(trees[[id_field]]) > 0L) stop_run('TREE_ID harus non-NA dan unik.')
  gt <- unique(as.character(st_geometry_type(trees)))
  if (any(gt == 'MULTIPOINT')) trees <- st_cast(trees, 'POINT')
  if (!all(as.character(st_geometry_type(trees)) == 'POINT')) stop_run('TREE_FILE harus POINT.')
  trees <- st_transform(trees, st_crs(las_prev))
  trees$tree_id <- as.character(trees[[id_field]])
  if (anyDuplicated(trees$tree_id) > 0L) stop_run('TREE_ID tidak unik setelah geometry cast.')
  coords <- st_coordinates(trees)
  if (nrow(coords) != nrow(trees)) stop_run('Koordinat TREE_ID tidak satu-ke-satu.')
  write_log('INFO', paste('TREE_ID valid:', format(nrow(trees), big.mark = ',')))

  set_stage('ground', 'Ground classification & DTM', 24)
  classify_ground_one <- function(las, label) {
    write_log('INFO', paste(label, '- classify_ground CSF dimulai.'))
    g <- classify_ground(las, csf(cloth_resolution = as_num(p$csf_cloth_resolution,0.5), class_threshold = as_num(p$csf_class_threshold,0.3), rigidness = as_int(p$csf_rigidness,2L)))
    n_g <- sum(g$Classification == 2L, na.rm = TRUE)
    pct <- n_g / npoints(g) * 100
    write_log('INFO', paste(label, '- ground Class 2:', format(n_g, big.mark=','), sprintf('(%.2f%%)', pct)))
    if (n_g == 0L) stop_run(label, ': tidak ada ground hasil CSF.')
    list(las = g, n = n_g, pct = pct)
  }
  gp <- classify_ground_one(las_prev, PREV); g_prev <- gp$las
  progress_event('ground', 'Ground classification & DTM', 28, paste('Ground', PREV, 'selesai.'))
  gc <- classify_ground_one(las_curr, CURR); g_curr <- gc$las
  progress_event('ground', 'Ground classification & DTM', 32, paste('Ground', CURR, 'selesai.'))

  terrain_mode_prev <- toupper(as.character(p$terrain_mode_prev %||% 'CSF_TIN'))
  terrain_mode_curr <- toupper(as.character(p$terrain_mode_curr %||% 'CSF_TIN'))
  make_dtm <- function(g, mode, file, label, suffix) {
    if (mode == 'CSF_TIN') {
      write_log('INFO', paste(label, '- rasterize_terrain TIN dimulai.'))
      d <- rasterize_terrain(g, res = dtm_res, algorithm = tin())
      out <- file.path(run_dir, paste0(label, '_DTM_', suffix, '.tif'))
      terra::writeRaster(d, out, overwrite = TRUE)
      write_log('INFO', paste(label, '- DTM tersimpan:', out))
      return(list(dtm = d, path = out, generated = TRUE))
    }
    write_log('INFO', paste(label, '- load external DTM:', file))
    d <- terra::rast(file)
    ensure_dtm_crs(d, st_crs(g), paste('DTM ', label))
    list(dtm = d, path = normalizePath(file, winslash='/', mustWork=FALSE), generated = FALSE)
  }
  dprev <- make_dtm(g_prev, terrain_mode_prev, inputs$external_dtm_prev, PREV, 'prev'); dtm_prev <- dprev$dtm
  dcurr <- make_dtm(g_curr, terrain_mode_curr, inputs$external_dtm_curr, CURR, 'curr'); dtm_curr <- dcurr$dtm

  set_stage('terrain_qc', 'Terrain hold-out / ground QC', 36)
  write_log('INFO', paste(PREV, '- terrain QC dimulai.'))
  qprev <- if (terrain_mode_prev == 'CSF_TIN') terrain_holdout_qc(g_prev, dtm_res, train_frac, hold_seed, min_ground, max_ground) else terrain_external_qc(g_prev, dtm_prev, min_ground, max_ground, hold_seed)
  write_log('INFO', paste(PREV, '- terrain QC:', paste(names(qprev), unlist(qprev[1,]), sep='=', collapse=' | ')))
  progress_event('terrain_qc', 'Terrain hold-out / ground QC', 39, paste('Terrain QC', PREV, 'selesai.'))
  write_log('INFO', paste(CURR, '- terrain QC dimulai.'))
  qcurr <- if (terrain_mode_curr == 'CSF_TIN') terrain_holdout_qc(g_curr, dtm_res, train_frac, hold_seed + 1L, min_ground, max_ground) else terrain_external_qc(g_curr, dtm_curr, min_ground, max_ground, hold_seed + 1L)
  write_log('INFO', paste(CURR, '- terrain QC:', paste(names(qcurr), unlist(qcurr[1,]), sep='=', collapse=' | ')))
  progress_event('terrain_qc', 'Terrain hold-out / ground QC', 42, paste('Terrain QC', CURR, 'selesai.'))
  terrain_qc_csv <- file.path(qc_dir, paste0('terrain_qc_', PREV, '_', CURR, '.csv'))
  qout <- dplyr::bind_rows(dplyr::mutate(qprev, period = PREV, terrain_mode = terrain_mode_prev), dplyr::mutate(qcurr, period = CURR, terrain_mode = terrain_mode_curr))
  utils::write.csv(qout, terrain_qc_csv, row.names = FALSE)

  set_stage('normalize', 'Normalisasi tinggi per periode', 44)
  write_log('INFO', paste(PREV, '- normalize_height dimulai.'))
  n_prev <- normalize_height(g_prev, dtm_prev)
  n_prev <- filter_poi(n_prev, Z >= as_num(p$min_normalized_z_m, -0.10))
  write_log('INFO', paste(PREV, '- normalisasi selesai; points:', format(npoints(n_prev), big.mark=',')))
  progress_event('normalize', 'Normalisasi tinggi per periode', 47, paste('Normalisasi', PREV, 'selesai.'))
  write_log('INFO', paste(CURR, '- normalize_height dimulai.'))
  n_curr <- normalize_height(g_curr, dtm_curr)
  n_curr <- filter_poi(n_curr, Z >= as_num(p$min_normalized_z_m, -0.10))
  write_log('INFO', paste(CURR, '- normalisasi selesai; points:', format(npoints(n_curr), big.mark=',')))
  progress_event('normalize', 'Normalisasi tinggi per periode', 50, paste('Normalisasi', CURR, 'selesai.'))

  norm_prev_path <- ''; norm_curr_path <- ''
  if (as_bool(p$save_normalized_laz, TRUE)) {
    norm_prev_path <- file.path(run_dir, paste0(PREV, '_normalized.laz'))
    norm_curr_path <- file.path(run_dir, paste0(CURR, '_normalized.laz'))
    write_log('INFO', paste('Simpan normalized LAZ', PREV, '...')); writeLAS(n_prev, norm_prev_path)
    write_log('INFO', paste('Simpan normalized LAZ', CURR, '...')); writeLAS(n_curr, norm_curr_path)
  }

  chm_prev_path <- ''; chm_curr_path <- ''
  if (as_bool(p$create_nchm, TRUE)) {
    res_chm <- as_num(p$chm_resolution_m, 0.10)
    write_log('INFO', paste('Generate nCHM', PREV, 'untuk visual/QC.'))
    chm_prev <- rasterize_canopy(n_prev, res = res_chm, algorithm = p2r())
    chm_prev_path <- file.path(run_dir, paste0('nCHM_', PREV, '.tif')); terra::writeRaster(chm_prev, chm_prev_path, overwrite=TRUE)
    write_log('INFO', paste('Generate nCHM', CURR, 'untuk visual/QC.'))
    chm_curr <- rasterize_canopy(n_curr, res = res_chm, algorithm = p2r())
    chm_curr_path <- file.path(run_dir, paste0('nCHM_', CURR, '.tif')); terra::writeRaster(chm_curr, chm_curr_path, overwrite=TRUE)
  }

  set_stage('metrics_prev', paste('Ekstraksi metrics ', PREV), 52)
  met_prev <- metrics_all_trees(n_prev, coords, min_veg_h, buffer_m, chunk_size, paste('Metrics', PREV), 'metrics_prev', 52, 66)
  prs_prev <- presence_support(met_prev)
  write_log('INFO', paste(PREV, '- support cutoff n_all=', round(prs_prev$cuts$n_all,2), 'n_veg=', round(prs_prev$cuts$n_veg,2), 'ratio=', round(prs_prev$cuts$ratio,4)))

  set_stage('metrics_curr', paste('Ekstraksi metrics ', CURR), 67)
  met_curr <- metrics_all_trees(n_curr, coords, min_veg_h, buffer_m, chunk_size, paste('Metrics', CURR), 'metrics_curr', 67, 81)
  prs_curr <- presence_support(met_curr)
  write_log('INFO', paste(CURR, '- support cutoff n_all=', round(prs_curr$cuts$n_all,2), 'n_veg=', round(prs_curr$cuts$n_veg,2), 'ratio=', round(prs_curr$cuts$ratio,4)))

  metrics_prev_csv <- file.path(run_dir, paste0('metrics_', PREV, '.csv'))
  metrics_curr_csv <- file.path(run_dir, paste0('metrics_', CURR, '.csv'))
  prev_export <- dplyr::bind_cols(data.frame(tree_id=trees$tree_id), met_prev, prs_prev$flags)
  curr_export <- dplyr::bind_cols(data.frame(tree_id=trees$tree_id), met_curr, prs_curr$flags)
  utils::write.csv(prev_export, metrics_prev_csv, row.names=FALSE)
  utils::write.csv(curr_export, metrics_curr_csv, row.names=FALSE)

  set_stage('delta', 'Delta multi-metrik', 83)
  pair <- data.frame(tree_id = trees$tree_id, stringsAsFactors = FALSE)
  pair <- dplyr::bind_cols(
    pair,
    dplyr::rename_with(met_prev, ~paste0(.x, '_prev')),
    dplyr::rename_with(met_curr, ~paste0(.x, '_curr')),
    dplyr::rename_with(prs_prev$flags, ~paste0(.x, '_prev')),
    dplyr::rename_with(prs_curr$flags, ~paste0(.x, '_curr'))
  )
  pair$d_p95 <- pair$p95_curr - pair$p95_prev
  pair$d_p99 <- pair$p99_curr - pair$p99_prev
  pair$d_t10 <- pair$top10_curr - pair$top10_prev
  pair$d_t20 <- pair$top20_curr - pair$top20_prev
  pair$d_t30 <- pair$top30_curr - pair$top30_prev
  pair$metric_spread <- vapply(seq_len(nrow(pair)), function(i) safe_metric_spread(c(pair$d_p95[i], pair$d_t10[i], pair$d_t20[i], pair$d_t30[i])), numeric(1))
  pair$n_negative <- vapply(seq_len(nrow(pair)), function(i) safe_n_negative(c(pair$d_p95[i], pair$d_t10[i], pair$d_t20[i], pair$d_t30[i])), integer(1))
  spread_cut <- upper_fence(pair$metric_spread)
  pair$metric_disagree <- is.finite(pair$metric_spread) & pair$metric_spread > spread_cut
  write_log('INFO', paste('Metric disagreement upper fence:', ifelse(is.finite(spread_cut), round(spread_cut,4), 'Inf')))

  set_stage('uncertainty', 'Technical uncertainty proxy', 87)
  sigma_prev <- as.numeric(qprev$nmad[1]); sigma_curr <- as.numeric(qcurr$nmad[1])
  T_TERRAIN <- if (is.finite(sigma_prev) && is.finite(sigma_curr)) sqrt(sigma_prev^2 + sigma_curr^2) else NA_real_
  ms <- pair$metric_spread[is.finite(pair$metric_spread)]
  T_METRIC <- if (length(ms)) as.numeric(stats::quantile(ms, 0.95, na.rm=TRUE, names=FALSE)) else NA_real_
  tt <- c(T_TERRAIN, T_METRIC); tt <- tt[is.finite(tt)]
  T_TECH <- if (length(tt)) max(tt) else NA_real_
  write_log('INFO', paste('T_TERRAIN =', ifelse(is.finite(T_TERRAIN), round(T_TERRAIN,4), 'NA'), 'm'))
  write_log('INFO', paste('T_METRIC  =', ifelse(is.finite(T_METRIC), round(T_METRIC,4), 'NA'), 'm'))
  write_log('INFO', paste('T_TECH    =', ifelse(is.finite(T_TECH), round(T_TECH,4), 'NA'), 'm'))
  if (!is.finite(T_TERRAIN)) write_log('WARNING', 'Komponen terrain uncertainty tidak tersedia/kurang stabil; interpretasi residual harus lebih konservatif.')

  set_stage('peer', 'Peer group & residual limits', 90)
  if (nzchar(peer_field) && peer_field %in% names(trees)) {
    pair$peer <- as.character(trees[[peer_field]])
    pair$peer[is.na(pair$peer) | !nzchar(pair$peer)] <- 'PEER_NA'
    peer_source <- paste0('FIELD:', peer_field)
  } else {
    q <- stats::quantile(pair$p95_prev, probs=c(0.25,0.50,0.75), na.rm=TRUE, names=FALSE)
    br <- unique(c(-Inf, q[is.finite(q)], Inf))
    if (length(br) >= 3L) pair$peer <- as.character(cut(pair$p95_prev, breaks=br, include.lowest=TRUE, labels=FALSE)) else pair$peer <- '1'
    peer_source <- 'P95_PREV_QUARTILE'
  }
  write_log('INFO', paste('Peer source:', peer_source, '| groups:', length(unique(pair$peer))))

  eligible <- pair$canopy_support_prev %in% TRUE & pair$canopy_support_curr %in% TRUE & !(pair$metric_disagree %in% TRUE) & is.finite(pair$d_p95)
  peer_limits <- data.frame(peer=character(0), q1=numeric(0), q3=numeric(0), iqr=numeric(0), lower_peer=numeric(0), upper_peer=numeric(0), n_peer=integer(0), lower_residual=numeric(0), stringsAsFactors=FALSE)
  for (g in unique(pair$peer)) {
    x <- pair$d_p95[eligible & pair$peer == g]
    x <- x[is.finite(x)]
    if (!length(x)) next
    q1 <- as.numeric(stats::quantile(x,0.25,na.rm=TRUE,names=FALSE)); q3 <- as.numeric(stats::quantile(x,0.75,na.rm=TRUE,names=FALSE)); iq <- stats::IQR(x,na.rm=TRUE)
    lower_peer <- if (length(x) >= 4L && is.finite(iq)) q1 - 1.5*iq else NA_real_
    upper_peer <- if (length(x) >= 4L && is.finite(iq)) q3 + 1.5*iq else NA_real_
    lower_residual <- if (is.finite(lower_peer) && is.finite(T_TECH)) min(lower_peer, -T_TECH) else NA_real_
    peer_limits <- rbind(peer_limits, data.frame(peer=as.character(g),q1=q1,q3=q3,iqr=iq,lower_peer=lower_peer,upper_peer=upper_peer,n_peer=length(x),lower_residual=lower_residual,stringsAsFactors=FALSE))
  }
  pair <- dplyr::left_join(pair, peer_limits, by='peer')
  peer_limits_csv <- file.path(qc_dir, paste0('peer_limits_', PREV, '_', CURR, '.csv')); utils::write.csv(peer_limits, peer_limits_csv, row.names=FALSE)

  set_stage('decision', 'Residual decision logic', 93)
  status <- rep('REVIEW', nrow(pair))
  cond <- !(pair$data_ok_curr %in% TRUE); status[cond] <- 'TECH_DATA_GAP_CURRENT'
  cond <- status=='REVIEW' & pair$canopy_support_prev %in% TRUE & !(pair$canopy_support_curr %in% TRUE) & pair$data_ok_curr %in% TRUE; status[cond] <- 'CANOPY_LOSS_OR_RECONSTRUCTION'
  cond <- status=='REVIEW' & !(pair$canopy_support_prev %in% TRUE) & !(pair$canopy_support_curr %in% TRUE) & pair$data_ok_prev %in% TRUE & pair$data_ok_curr %in% TRUE; status[cond] <- 'NO_CANOPY_SUPPORT_BOTH'
  cond <- status=='REVIEW' & pair$metric_disagree %in% TRUE; status[cond] <- 'TECH_METRIC_DISAGREEMENT'
  cond <- status=='REVIEW' & pair$canopy_support_prev %in% TRUE & pair$canopy_support_curr %in% TRUE & is.finite(pair$lower_residual) & is.finite(pair$d_p95) & pair$d_p95 < pair$lower_residual & pair$n_negative >= 3L; status[cond] <- 'NEGATIVE_HEIGHT_OUTLIER'
  cond <- status=='REVIEW' & pair$canopy_support_prev %in% TRUE & pair$canopy_support_curr %in% TRUE & is.finite(T_TECH) & is.finite(pair$d_p95) & abs(pair$d_p95) <= T_TECH; status[cond] <- 'STABLE_NO_DETECTABLE_CHANGE'
  cond <- status=='REVIEW' & pair$canopy_support_curr %in% TRUE; status[cond] <- 'PRESENT_NO_HARD_RESIDUAL'
  pair$status <- status
  pair$residual_flag <- pair$status %in% c('TECH_DATA_GAP_CURRENT','CANOPY_LOSS_OR_RECONSTRUCTION','NO_CANOPY_SUPPORT_BOTH','TECH_METRIC_DISAGREEMENT','NEGATIVE_HEIGHT_OUTLIER','REVIEW')
  sc <- sort(table(pair$status), decreasing=TRUE)
  write_log('INFO', paste('Status counts:', paste(names(sc), as.integer(sc), sep='=', collapse=' | ')))

  set_stage('zone', 'Residual point, buffer & zone', 96)
  pair_csv <- file.path(run_dir, paste0('delta_', PREV, '_', CURR, '.csv')); utils::write.csv(pair, pair_csv, row.names=FALSE)
  pair_sf <- trees %>% dplyr::select(tree_id)
  shp_attr <- pair %>% dplyr::transmute(
    tree_id = tree_id,
    p95_prev = p95_prev, p95_curr = p95_curr, d_p95 = d_p95, d_p99 = d_p99,
    d_t10 = d_t10, d_t20 = d_t20, d_t30 = d_t30,
    sprd = metric_spread, nneg = n_negative,
    dat_p = data_ok_prev, dat_c = data_ok_curr,
    can_p = canopy_support_prev, can_c = canopy_support_curr,
    peer = as.character(peer), lowres = lower_residual,
    ttech = T_TECH, status = status, res_flag = residual_flag
  )
  pair_sf <- dplyr::left_join(pair_sf, shp_attr, by='tree_id')
  pair_shp <- file.path(shp_dir, paste0('monitoring_', PREV, '_', CURR, '.shp')); safe_write_sf(pair_sf, pair_shp)

  residual_point <- pair_sf[pair_sf$res_flag %in% TRUE, , drop=FALSE]
  residual_point_path <- ''; residual_buffer_path <- ''; residual_zone_path <- ''; residual_zone_csv <- ''
  zone_count <- 0L
  if (nrow(residual_point) > 0L) {
    residual_point_path <- file.path(shp_dir, paste0('residual_point_', PREV, '_', CURR, '.shp')); safe_write_sf(residual_point, residual_point_path)
    residual_buffer <- st_buffer(residual_point, dist=buffer_m)
    residual_buffer_path <- file.path(shp_dir, paste0('residual_buffer_', PREV, '_', CURR, '.shp')); safe_write_sf(residual_buffer, residual_buffer_path)
    write_log('INFO', 'Dissolve overlap residual buffer menjadi operational zones.')
    zone_geom <- st_union(residual_buffer)
    zone_geom <- suppressWarnings(st_cast(zone_geom, 'POLYGON'))
    residual_zone <- st_sf(ZONE_ID=seq_along(zone_geom), geometry=zone_geom)
    hit <- st_intersects(residual_zone, residual_point)
    residual_zone$N_TREE <- lengths(hit)
    residual_zone$REASON <- vapply(hit, function(ix) { if (!length(ix)) return(''); paste(sort(unique(residual_point$status[ix])), collapse='|') }, character(1))
    residual_zone$AREA_M2 <- as.numeric(st_area(residual_zone))
    residual_zone_path <- file.path(shp_dir, paste0('residual_zone_', PREV, '_', CURR, '.shp')); safe_write_sf(residual_zone, residual_zone_path)
    residual_zone_csv <- file.path(run_dir, paste0('residual_zone_', PREV, '_', CURR, '.csv')); utils::write.csv(st_drop_geometry(residual_zone), residual_zone_csv, row.names=FALSE)
    zone_count <- nrow(residual_zone)
  }
  write_log('INFO', paste('Residual TREE_ID:', nrow(residual_point), '| Residual zones:', zone_count))

  set_stage('export', 'Export summary, QC & report', 98)
  qc_plot_files <- character(0)
  if (as_bool(p$create_qc_plots, TRUE)) {
    try({
      f <- file.path(qc_dir, paste0('hist_delta_p95_', PREV, '_', CURR, '.png'))
      x <- pair$d_p95[is.finite(pair$d_p95)]
      if (length(x)>1L) { png(f,1600,1000,res=150); hist(x,breaks='FD',main=paste('Delta P95',PREV,'to',CURR),xlab='Delta P95 (m)'); abline(v=0,lty=2); if(is.finite(T_TECH)){abline(v=c(-T_TECH,T_TECH),lty=3)}; dev.off(); qc_plot_files <- c(qc_plot_files,f) }
    }, silent=TRUE)
    try({
      f <- file.path(qc_dir, paste0('metric_spread_', PREV, '_', CURR, '.png'))
      x <- pair$metric_spread[is.finite(pair$metric_spread)]
      if (length(x)>1L) { png(f,1600,1000,res=150); hist(x,breaks='FD',main='Internal Metric Spread',xlab='Spread delta (m)'); if(is.finite(spread_cut)) abline(v=spread_cut,lty=2); dev.off(); qc_plot_files <- c(qc_plot_files,f) }
    }, silent=TRUE)
  }

  status_counts <- as.list(as.integer(sc)); names(status_counts) <- names(sc)
  preview_cols <- c('tree_id','p95_prev','p95_curr','d_p95','metric_spread','n_negative','canopy_support_prev','canopy_support_curr','peer','lower_residual','status','residual_flag')
  preview <- head(pair[, preview_cols, drop=FALSE], 25)
  dtm_generated <- c(if (isTRUE(dprev$generated)) dprev$path else '', if (isTRUE(dcurr$generated)) dcurr$path else '')
  outputs <- c(metrics_prev_csv, metrics_curr_csv, pair_csv, pair_shp, terrain_qc_csv, peer_limits_csv, dtm_generated, norm_prev_path, norm_curr_path, chm_prev_path, chm_curr_path, residual_point_path, residual_buffer_path, residual_zone_path, residual_zone_csv, qc_plot_files, log_path)
  outputs <- unique(outputs[nzchar(outputs) & file.exists(outputs)])

  summary <- list(
    app_version = as.character(cfg$app$version %||% '0.6.0'),
    run_dir = run_dir,
    prev_period_code = PREV,
    curr_period_code = CURR,
    tree_count = nrow(trees),
    input_points_prev = input_prev_n,
    input_points_curr = input_curr_n,
    density_prev_m2 = qc_prev$avg_density,
    density_curr_m2 = qc_curr$avg_density,
    terrain_mode_prev = terrain_mode_prev,
    terrain_mode_curr = terrain_mode_curr,
    terrain_nmad_prev_m = sigma_prev,
    terrain_nmad_curr_m = sigma_curr,
    t_terrain_m = T_TERRAIN,
    t_metric_m = T_METRIC,
    t_tech_m = T_TECH,
    metric_spread_cut_m = spread_cut,
    peer_source = peer_source,
    p95_prev_median = if(any(is.finite(pair$p95_prev))) median(pair$p95_prev,na.rm=TRUE) else NA_real_,
    p95_curr_median = if(any(is.finite(pair$p95_curr))) median(pair$p95_curr,na.rm=TRUE) else NA_real_,
    delta_p95_median = if(any(is.finite(pair$d_p95))) median(pair$d_p95,na.rm=TRUE) else NA_real_,
    stable_count = sum(pair$status == 'STABLE_NO_DETECTABLE_CHANGE', na.rm=TRUE),
    residual_count = sum(pair$residual_flag %in% TRUE),
    residual_pct = round(mean(pair$residual_flag %in% TRUE) * 100, 2),
    zone_count = zone_count,
    status_counts = status_counts,
    bbox_overlap_ratio = overlap,
    output_files = outputs,
    preview = preview
  )

  result_json <- file.path(run_dir, 'result_summary.json')
  jsonlite::write_json(summary, result_json, pretty=TRUE, auto_unbox=TRUE, na='null')
  report_path <- file.path(run_dir, 'report.html')
  make_html_report(summary, preview, report_path)
  outputs <- unique(c(outputs, result_json, report_path))
  manifest_path <- file.path(run_dir, 'output_manifest.csv')
  utils::write.csv(data.frame(file=basename(outputs), path=outputs, stringsAsFactors=FALSE), manifest_path, row.names=FALSE)
  summary$output_files <- unique(c(outputs, manifest_path))
  jsonlite::write_json(summary, result_json, pretty=TRUE, auto_unbox=TRUE, na='null')

  set_stage('complete', 'Analisis rolling pair selesai', 100)
  emit('result', status='success', runDir=run_dir, summaryPath=result_json, reportPath=report_path, summary=summary)
  write_log('INFO', 'Analisis selesai tanpa fatal error.')
}

status_code <- 0L
withCallingHandlers(
  tryCatch({
    if (mode == 'validate') {
      validate_config(TRUE)
      set_stage('complete', 'Validasi berhasil', 100)
      emit('validation-result', status='success', message='Semua input utama valid untuk rolling pair analysis.')
    } else {
      run_pipeline()
    }
  }, error = function(e) {
    status_code <<- 10L
    msg <- conditionMessage(e)
    try(cat(sprintf('[%s] [FATAL] [%s] %s\n', format(Sys.time(), '%Y-%m-%d %H:%M:%S'), current_stage, msg), file=log_path, append=TRUE), silent=TRUE)
    emit('fatal', stage=current_stage, message=msg, runDir=run_dir, logPath=log_path)
  }),
  warning = function(w) {
    msg <- conditionMessage(w)
    try(write_log('WARNING', msg), silent=TRUE)
    invokeRestart('muffleWarning')
  }
)
quit(status = status_code)
