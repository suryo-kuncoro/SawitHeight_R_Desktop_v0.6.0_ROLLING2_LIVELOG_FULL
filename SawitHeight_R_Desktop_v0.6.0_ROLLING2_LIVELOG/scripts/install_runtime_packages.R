args <- commandArgs(trailingOnly = TRUE)
lib <- if (length(args)) normalizePath(args[[1]], winslash = '/', mustWork = FALSE) else file.path(R.home(), 'library')
dir.create(lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(lib, .libPaths()))
repos <- c(RLIDAR = 'https://r-lidar.r-universe.dev', CRAN = 'https://cloud.r-project.org')
options(repos = repos)
packages <- c('jsonlite', 'lidR', 'terra', 'sf', 'dplyr', 'RCSF')
missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  message('Installing missing bundled packages: ', paste(missing, collapse = ', '))
  install.packages(missing, lib = lib, repos = repos, dependencies = c('Depends','Imports','LinkingTo'), type = 'binary')
}
still_missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(still_missing)) stop('Bundled R belum lengkap: ', paste(still_missing, collapse = ', '), '. R=', getRversion())
cat('Bundled R packages ready in:', lib, '\n')
for (pkg in packages) cat(pkg, as.character(packageVersion(pkg)), '\n')
