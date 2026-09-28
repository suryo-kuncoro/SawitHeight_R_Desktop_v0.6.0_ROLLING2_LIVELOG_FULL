const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const resources = path.join(root, 'dist', 'win-unpacked', 'resources');
const requiredScripts = ['pipeline.R','check_environment.R','install_packages.R'];
function existsNonEmpty(file) { try { return fs.statSync(file).isFile() && fs.statSync(file).size > 0; } catch { return false; } }
let failed = false;
for (const name of requiredScripts) {
  const primary = path.join(resources, 'r', name);
  const fallback = path.join(resources, 'app.asar.unpacked', 'r', name);
  const okPrimary = existsNonEmpty(primary), okFallback = existsNonEmpty(fallback);
  console.log(`${name}: resources/r=${okPrimary ? 'OK' : 'MISSING'} | app.asar.unpacked/r=${okFallback ? 'OK' : 'MISSING'}`);
  if (!okPrimary && !okFallback) failed = true;
}
const tutorial = path.join(resources, 'docs', 'reference_tutorial.html');
console.log(`Tutorial: ${existsNonEmpty(tutorial) ? 'OK' : 'MISSING'}`);
if (!existsNonEmpty(tutorial)) failed = true;
const vendorR = path.join(resources, 'vendor', 'R', 'bin', 'Rscript.exe');
if (fs.existsSync(path.join(root, 'vendor', 'R'))) {
  console.log(`Bundled Rscript: ${existsNonEmpty(vendorR) ? 'OK' : 'MISSING'}`);
  if (!existsNonEmpty(vendorR)) failed = true;
} else console.log('Bundled R: not requested for this build.');
if (failed) { console.error('Packaged resources verification FAILED.'); process.exit(1); }
console.log('Packaged resources verification PASSED.');
