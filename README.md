# SawitHeight R Desktop v0.6.0 — MAS POPO Rolling 2-Period

Aplikasi desktop Windows untuk monitoring tinggi relatif dan residual zone pokok sawit TBM dari **dua dense point cloud SfM-MVS terakhir**.

## Metode v0.6.0

- Rolling pair: `P(t-1) + P(t)`; histori LAS lama tidak diproses ulang.
- TREE_ID permanen + fixed buffer radius 2 m.
- P95 normalized point cloud sebagai tinggi utama.
- P99 dan mean Top 10/20/30% sebagai diagnostik multi-metrik.
- Terrain dapat berbeda per periode: `CSF_TIN` atau `EXTERNAL_DTM`.
- Terrain QC: hold-out ground untuk CSF-TIN; ground-vs-DTM residual untuk external DTM.
- Presence support: `n_all`, `n_veg`, `veg_ratio` dengan lower fence data-driven.
- `T_TERRAIN`, `T_METRIC`, `T_TECH` sebagai technical uncertainty proxy.
- Peer group dari field blok/batch opsional; fallback kuartil P95 periode sebelumnya.
- Residual konservatif: data gap, canopy loss/reconstruction, no canopy support, metric disagreement, negative height outlier, atau REVIEW.
- `STABLE_NO_DETECTABLE_CHANGE` **bukan residual**.
- Residual point, buffer individual 2 m, dan dissolved residual zone.
- nCHM opsional hanya untuk visual / spatial QC.

## Live process log

Halaman **Proses & Live Log** menampilkan:

1. Log backend R secara real-time (structured log + stdout/stderr).
2. Progress tahap dan progress chunk TREE_ID.
3. PID proses R.
4. Elapsed time.
5. `Last output` / idle seconds.
6. Heartbeat Electron setiap ±2 detik walaupun R sedang berada di fungsi berat.
7. Warning visual bila backend masih hidup tetapi lama tidak menghasilkan output.

`analysis.log` tetap ditulis ke folder run sehingga log tidak hilang walaupun tampilan UI dibersihkan.

## Input utama

- LAS/LAZ periode sebelumnya.
- LAS/LAZ periode saat ini.
- Titik TREE_ID permanen (SHP/GPKG/GeoJSON).
- External DTM per periode (opsional, jika mode EXTERNAL_DTM).
- Master LAS/LAZ opsional sebagai metadata/audit frame; aplikasi **tidak** melakukan ICP otomatis.

## Output utama

Contoh pair `P4 → P5`:

- `metrics_P4.csv`
- `metrics_P5.csv`
- `delta_P4_P5.csv`
- `shapefile/monitoring_P4_P5.shp`
- `shapefile/residual_point_P4_P5.shp`
- `shapefile/residual_buffer_P4_P5.shp`
- `shapefile/residual_zone_P4_P5.shp`
- `residual_zone_P4_P5.csv`
- `P4_DTM_prev.tif` / external DTM reference
- `P5_DTM_curr.tif` / external DTM reference
- `P4_normalized.laz`, `P5_normalized.laz` (opsional)
- `nCHM_P4.tif`, `nCHM_P5.tif` (opsional)
- `qc/terrain_qc_P4_P5.csv`
- `qc/peer_limits_P4_P5.csv`
- QC plots
- `analysis.log`
- `result_summary.json`
- `report.html`
- `output_manifest.csv`

## Build Windows

GitHub Actions tetap mendukung dua mode:

- `bundle_r = false`: menggunakan R di PC.
- `bundle_r = true`: portable self-contained dengan runtime R dan package internal.

Jalankan:

`Actions → Build Windows EXE → Run workflow → bundle_r = true`

Output:

- `SawitHeight-R-Portable-0.6.0.exe`
- `SawitHeight-R-Setup-0.6.0.exe`

## Catatan R 4.2.2

Tutorial v0.6.0 tetap dibundel ke aplikasi dan memuat prosedur legacy R 4.2.2. Untuk distribusi operasional, build self-contained lebih konsisten karena tidak bergantung pada library R lama di PC pengguna.
