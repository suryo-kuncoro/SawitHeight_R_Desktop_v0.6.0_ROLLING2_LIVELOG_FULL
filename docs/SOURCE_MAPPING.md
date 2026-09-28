# Source Mapping v0.6.0

Sumber metode: `docs/reference_tutorial.html` — Tutorial MAS POPO Rolling 2-Period & Residual Confidence v0.6.0.

| Tutorial | Implementasi aplikasi |
|---|---|
| 00B Rolling 2-period | PREV + CURR LAS/LAZ input, master metadata opsional |
| 01 Load dua periode | `r/pipeline.R` stage `load` |
| 02 QC point cloud | duplicate removal, SOR class 18 filtering, density |
| 03 Spatial registration QC | confirmation gate + metadata; no automatic ICP |
| 04 Ground & DTM per period | independent `terrain_mode_prev/curr` |
| 05 Terrain hold-out QC | holdout NMAD / external DTM ground residual |
| 06 Normalisasi | normalize_height independently per period |
| 07 P95 & presence support | chunked clip_circle + P95/P99/top metrics + support fences |
| 08 Technical uncertainty | metric spread, T_TERRAIN, T_METRIC, T_TECH |
| 09 Residual logic | peer limits + conservative status decision |
| 10 Residual zones | residual point, buffer, dissolved zone |
| 11 Rolling archive | metrics per period + pair delta outputs |
| 12 Checklist | validation gate and report/QC outputs |
