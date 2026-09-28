# Architecture — SawitHeight R v0.6.0

## Desktop shell
Electron renderer → preload IPC bridge → main process → `Rscript.exe` child process.

## Rolling pair engine
`P(t-1) LAS/LAZ + P(t) LAS/LAZ + TREE_ID` → QC → per-period ground/DTM → terrain QC → normalization → chunked direct point-cloud metrics → presence support → multi-metric delta → T_TECH → peer residual logic → residual point/buffer/dissolved zone.

## Live log
`pipeline.R` emits `APP_EVENT:` JSON for structured progress/logs. Non-structured stdout/stderr are also forwarded. Main process emits heartbeat every ~2 seconds with elapsed and idle duration.

## Security
Renderer has no Node integration; filesystem/process actions are exposed only through preload IPC methods.
