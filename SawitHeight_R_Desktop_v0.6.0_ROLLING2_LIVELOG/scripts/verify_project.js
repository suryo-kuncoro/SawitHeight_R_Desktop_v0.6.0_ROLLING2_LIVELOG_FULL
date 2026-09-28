const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const required = [
  'package.json','src/main.js','src/preload.js','src/renderer/index.html','src/renderer/styles.css','src/renderer/app.js',
  'r/pipeline.R','r/check_environment.R','r/install_packages.R','assets/icon.ico',
  '.github/workflows/build-windows.yml','docs/SOURCE_MAPPING.md','docs/reference_tutorial.html','docs/V0.6.0_ROLLING2_LIVELOG.md','docs/TEST_PLAN.md'
];
let failed = false;
for (const item of required) {
  const full = path.join(root, item);
  if (!fs.existsSync(full) || fs.statSync(full).size === 0) { console.error(`MISSING: ${item}`); failed = true; }
  else console.log(`OK: ${item}`);
}
const assertions = [
  ['package.json', '0.6.0'],
  ['package.json', '--publish never'],
  ['src/renderer/index.html', 'ROLLING 2-PERIOD'],
  ['src/renderer/index.html', 'LIVE PROCESS LOG'],
  ['src/renderer/index.html', 'T_TECH'],
  ['src/renderer/index.html', 'terrain-mode-prev'],
  ['src/renderer/index.html', 'terrain-mode-curr'],
  ['src/main.js', "type: 'heartbeat'"],
  ['src/main.js', 'idle_seconds'],
  ['src/preload.js', 'openTutorial'],
  ['r/pipeline.R', 'Classification != 18L'],
  ['r/pipeline.R', 'terrain_holdout_qc'],
  ['r/pipeline.R', 'presence_support'],
  ['r/pipeline.R', 'metric_spread'],
  ['r/pipeline.R', 'T_TECH'],
  ['r/pipeline.R', 'STABLE_NO_DETECTABLE_CHANGE'],
  ['r/pipeline.R', 'NEGATIVE_HEIGHT_OUTLIER'],
  ['r/pipeline.R', 'residual_zone_'],
  ['r/pipeline.R', 'metrics_all_trees'],
  ['docs/reference_tutorial.html', 'Rolling 2-Period'],
  ['docs/reference_tutorial.html', 'Residual Confidence v0.6.0']
];
for (const [file, token] of assertions) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  if (!text.includes(token)) { console.error(`ASSERT FAILED: ${file} tidak memuat ${token}`); failed = true; }
  else console.log(`ASSERT OK: ${file} -> ${token}`);
}
process.exit(failed ? 1 : 0);
