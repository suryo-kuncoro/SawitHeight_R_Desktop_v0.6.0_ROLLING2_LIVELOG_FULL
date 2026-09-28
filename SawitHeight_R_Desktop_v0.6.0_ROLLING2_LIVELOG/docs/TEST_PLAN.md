# Test Plan — v0.6.0

## 1. Smoke test
Use two small LAS/LAZ subsets with the same CRS and 20–100 TREE_ID. Confirm live log, heartbeat, cancel, output folder, and report.

## 2. Terrain paths
Test all combinations:
- PREV CSF_TIN + CURR CSF_TIN
- PREV EXTERNAL_DTM + CURR CSF_TIN
- PREV CSF_TIN + CURR EXTERNAL_DTM
- PREV EXTERNAL_DTM + CURR EXTERNAL_DTM

## 3. Registration guard
Confirm analysis is blocked when Spatial Registration QC confirmation is not checked.

## 4. Presence support
Create cases for data gap, canopy loss, both no-support, and healthy support. Verify status logic.

## 5. Stable delta
Use nearly identical point clouds; verify good-support trees with |ΔP95| <= T_TECH become `STABLE_NO_DETECTABLE_CHANGE` and are not residual.

## 6. Negative residual
Create/identify a strong negative P95 case with at least 3/4 core deltas negative and below peer + T_TECH limit. Verify `NEGATIVE_HEIGHT_OUTLIER`.

## 7. Residual geometry
Verify individual point/buffer SHP and dissolved residual-zone SHP. Check `ZONE_ID`, `N_TREE`, `REASON`, `AREA_M2`.

## 8. Large run / live log
Run thousands of TREE_ID. Confirm chunk progress lines continue to appear and heartbeat remains active during long CSF/DTM operations.

## 9. Output audit
Open SHP/TIF/LAZ in ArcGIS Pro or QGIS; verify CRS, attributes, row counts, and TREE_ID pairing.
