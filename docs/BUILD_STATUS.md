# Build Status — v0.6.0

Static checks completed in the generation environment:
- JavaScript syntax (`node --check`).
- Project file assertions.
- Renderer ID references vs HTML.
- R delimiter balance (static only).

Not executed here:
- Real R/lidR pipeline.
- Windows Electron packaging.
- Production LAS benchmark.

GitHub Actions performs packaging verification before artifact upload.
