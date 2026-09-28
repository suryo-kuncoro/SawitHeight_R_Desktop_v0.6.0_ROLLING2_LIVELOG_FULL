const { app, BrowserWindow, dialog, ipcMain, shell, Menu } = require('electron');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');

const APP_NAME = 'SawitHeight R';
let mainWindow = null;
let activeProcess = null;
let activeRun = null;
let heartbeatTimer = null;

function getResourcePath(...parts) {
  if (app.isPackaged) return path.join(process.resourcesPath, ...parts);
  return path.join(__dirname, '..', ...parts);
}

function getAppFile(...parts) {
  if (app.isPackaged) return path.join(app.getAppPath(), ...parts);
  return path.join(__dirname, '..', ...parts);
}

function getSettingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function readSettings() {
  try { return JSON.parse(fs.readFileSync(getSettingsPath(), 'utf8')); }
  catch { return {}; }
}

function writeSettings(settings) {
  fs.mkdirSync(path.dirname(getSettingsPath()), { recursive: true });
  fs.writeFileSync(getSettingsPath(), JSON.stringify(settings, null, 2), 'utf8');
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1510,
    height: 950,
    minWidth: 1160,
    minHeight: 740,
    show: false,
    backgroundColor: '#0b0f11',
    title: APP_NAME,
    icon: getAppFile('assets', 'icon.ico'),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: !app.isPackaged
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWindow.once('ready-to-show', () => { mainWindow.show(); mainWindow.focus(); });
}

function emitToRenderer(event) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('analysis:event', event);
}

function normalizeExistingFile(filePath) {
  if (!filePath || typeof filePath !== 'string') return '';
  const resolved = path.resolve(filePath);
  return fs.existsSync(resolved) ? resolved : '';
}

function findRscriptCandidates() {
  const candidates = [];
  const bundled = getResourcePath('vendor', 'R', 'bin', 'Rscript.exe');
  if (fs.existsSync(bundled)) candidates.push(bundled);

  if (process.env.R_HOME) {
    candidates.push(path.join(process.env.R_HOME, 'bin', 'Rscript.exe'));
    candidates.push(path.join(process.env.R_HOME, 'bin', 'x64', 'Rscript.exe'));
  }

  const settings = readSettings();
  if (settings.rscriptPath) candidates.push(settings.rscriptPath);

  const roots = [
    process.env.ProgramFiles ? path.join(process.env.ProgramFiles, 'R') : null,
    process.env['ProgramFiles(x86)'] ? path.join(process.env['ProgramFiles(x86)'], 'R') : null,
    process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'Programs', 'R') : null
  ].filter(Boolean);

  for (const root of roots) {
    try {
      const dirs = fs.readdirSync(root, { withFileTypes: true })
        .filter((d) => d.isDirectory() && /^R-/i.test(d.name))
        .map((d) => d.name)
        .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
      for (const dir of dirs) {
        candidates.push(path.join(root, dir, 'bin', 'Rscript.exe'));
        candidates.push(path.join(root, dir, 'bin', 'x64', 'Rscript.exe'));
      }
    } catch { /* optional */ }
  }

  try {
    const result = spawnSync('where', ['Rscript.exe'], { encoding: 'utf8', windowsHide: true });
    if (result.status === 0 && result.stdout) candidates.push(...result.stdout.split(/\r?\n/).filter(Boolean));
  } catch { /* optional */ }

  const seen = new Set();
  return candidates.map(normalizeExistingFile).filter((candidate) => {
    const key = candidate.toLowerCase();
    if (!candidate || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function getRscriptPath(requestedPath = '') {
  const requested = normalizeExistingFile(requestedPath);
  if (requested) return requested;
  return findRscriptCandidates()[0] || '';
}

function validPeriod(value) {
  return /^[A-Z0-9]{1,3}$/.test(String(value || '').trim().toUpperCase());
}

function basicConfigValidation(config) {
  const errors = [];
  if (!config || typeof config !== 'object') return ['Konfigurasi tidak valid.'];
  const i = config.inputs || {};
  const p = config.parameters || {};

  for (const [key, label] of [['prev_point_cloud', 'Point cloud periode sebelumnya'], ['curr_point_cloud', 'Point cloud periode saat ini']]) {
    if (!i[key] || !fs.existsSync(i[key])) errors.push(`${label} tidak ditemukan.`);
    else if (!/\.(las|laz)$/i.test(i[key])) errors.push(`${label} harus .las atau .laz.`);
  }

  if (!i.tree_points || !fs.existsSync(i.tree_points)) errors.push('File titik pokok tidak ditemukan.');
  else if (!/\.(shp|gpkg|geojson|json)$/i.test(i.tree_points)) errors.push('Titik pokok harus SHP, GPKG, atau GeoJSON.');

  if (!String(p.tree_id_field || '').trim()) errors.push('Field TREE_ID wajib diisi dan harus permanen/unik.');
  if (!validPeriod(p.prev_period_code)) errors.push('Kode periode sebelumnya wajib 1-3 karakter, contoh P4.');
  if (!validPeriod(p.curr_period_code)) errors.push('Kode periode saat ini wajib 1-3 karakter, contoh P5.');
  if (String(p.prev_period_code || '').trim().toUpperCase() === String(p.curr_period_code || '').trim().toUpperCase()) errors.push('Dua kode periode harus berbeda.');
  if (!p.registration_qc_confirmed) errors.push('Konfirmasi Spatial Registration QC wajib dicentang sebelum analisis residual.');

  for (const side of ['prev', 'curr']) {
    const mode = String(p[`terrain_mode_${side}`] || 'CSF_TIN').toUpperCase();
    if (!['CSF_TIN', 'EXTERNAL_DTM'].includes(mode)) errors.push(`Terrain ${side} harus CSF_TIN atau EXTERNAL_DTM.`);
    if (mode === 'EXTERNAL_DTM') {
      const f = i[`external_dtm_${side}`];
      if (!f || !fs.existsSync(f)) errors.push(`External DTM ${side} dipilih tetapi file tidak ditemukan.`);
      else if (!/\.(tif|tiff)$/i.test(f)) errors.push(`External DTM ${side} harus GeoTIFF.`);
    }
  }

  if (p.use_master_reference) {
    if (!validPeriod(p.master_period_code)) errors.push('Kode master period wajib 1-3 karakter bila master reference diaktifkan.');
    if (i.master_point_cloud && !fs.existsSync(i.master_point_cloud)) errors.push('Master LAS/LAZ tidak ditemukan.');
    if (i.master_point_cloud && !/\.(las|laz)$/i.test(i.master_point_cloud)) errors.push('Master reference harus .las atau .laz.');
  }

  if (!i.output_root) errors.push('Folder output belum dipilih.');

  const positive = [
    ['sor_k', 'SOR k'], ['sor_m', 'SOR m'],
    ['csf_cloth_resolution', 'CSF cloth resolution'], ['csf_class_threshold', 'CSF class threshold'],
    ['dtm_resolution_m', 'Resolusi DTM'], ['buffer_radius_m', 'Radius buffer'],
    ['min_veg_h_m', 'Minimum vegetasi'], ['chm_resolution_m', 'Resolusi nCHM'],
    ['threads', 'Thread CPU'], ['metrics_chunk_size', 'Chunk metrics']
  ];
  for (const [key, label] of positive) {
    if (!Number.isFinite(Number(p[key])) || Number(p[key]) <= 0) errors.push(`${label} harus lebih besar dari 0.`);
  }

  if (!Number.isFinite(Number(p.min_normalized_z_m))) errors.push('Minimum normalized Z harus berupa angka.');
  const rigidness = Number(p.csf_rigidness);
  if (![1, 2, 3].includes(rigidness)) errors.push('CSF rigidness hanya boleh 1, 2, atau 3.');
  const epsg = Number(p.fallback_epsg || 0);
  if (epsg && (!Number.isInteger(epsg) || epsg <= 0)) errors.push('EPSG fallback harus bilangan bulat positif.');
  const frac = Number(p.holdout_train_frac);
  if (!Number.isFinite(frac) || frac <= 0 || frac >= 1) errors.push('Hold-out train fraction harus >0 dan <1.');
  const minGround = Number(p.holdout_min_ground);
  if (!Number.isInteger(minGround) || minGround < 20) errors.push('Minimum ground hold-out minimal 20 titik.');
  const maxGround = Number(p.holdout_max_ground || 0);
  if (!Number.isFinite(maxGround) || maxGround < 0) errors.push('Max ground hold-out harus 0 atau angka positif.');

  return errors;
}

function createRunConfig(config) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const prev = String(config?.parameters?.prev_period_code || 'PRE').trim().toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 3) || 'PRE';
  const curr = String(config?.parameters?.curr_period_code || 'CUR').trim().toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 3) || 'CUR';
  const outputRoot = path.resolve(config.inputs.output_root);
  fs.mkdirSync(outputRoot, { recursive: true });
  const runDir = path.join(outputRoot, `run_${prev}_${curr}_${timestamp}`);
  fs.mkdirSync(runDir, { recursive: true });
  const completeConfig = {
    ...config,
    app: { name: APP_NAME, version: app.getVersion(), created_at: new Date().toISOString(), run_dir: runDir }
  };
  const configPath = path.join(runDir, 'run_config.json');
  fs.writeFileSync(configPath, JSON.stringify(completeConfig, null, 2), 'utf8');
  return { runDir, configPath };
}

function parseEventLine(line) {
  const marker = 'APP_EVENT:';
  const idx = line.indexOf(marker);
  if (idx < 0) return null;
  try { return JSON.parse(line.slice(idx + marker.length).trim()); }
  catch { return { type: 'log', level: 'warning', message: `Event R tidak dapat diparse: ${line}` }; }
}

function getBackendScriptPath(scriptName) {
  const candidates = app.isPackaged
    ? [path.join(process.resourcesPath, 'r', scriptName), path.join(process.resourcesPath, 'app.asar.unpacked', 'r', scriptName)]
    : [path.join(__dirname, '..', 'r', scriptName)];
  for (const candidate of candidates) if (fs.existsSync(candidate)) return candidate;
  return { missing: true, candidates };
}

function clearHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = null;
}

function runRProcess({ rscriptPath, scriptName, args = [], modeName }) {
  return new Promise((resolve, reject) => {
    if (activeProcess) return reject(new Error('Masih ada proses R yang berjalan.'));
    const resolvedScript = getBackendScriptPath(scriptName);
    if (typeof resolvedScript !== 'string') return reject(new Error(`Script backend tidak ditemukan. Lokasi: ${resolvedScript.candidates.join(' | ')}`));

    const child = spawn(rscriptPath, [resolvedScript, ...args], {
      windowsHide: true,
      shell: false,
      env: { ...process.env, R_DEFAULT_PACKAGES: process.env.R_DEFAULT_PACKAGES || 'datasets,utils,grDevices,graphics,stats,methods' }
    });

    const startedAt = Date.now();
    let lastOutputAt = startedAt;
    let lastStructuredError = '';
    const rawStderr = [];

    activeProcess = child;
    activeRun = { modeName, pid: child.pid, startedAt };
    emitToRenderer({ type: 'process', status: 'started', mode: modeName, pid: child.pid, startedAt: new Date(startedAt).toISOString() });

    clearHeartbeat();
    heartbeatTimer = setInterval(() => {
      if (!activeProcess || activeProcess.pid !== child.pid) return;
      const now = Date.now();
      emitToRenderer({
        type: 'heartbeat',
        pid: child.pid,
        elapsed_seconds: Math.floor((now - startedAt) / 1000),
        idle_seconds: Math.floor((now - lastOutputAt) / 1000),
        timestamp: new Date(now).toISOString()
      });
    }, 2000);

    const stdoutLines = readline.createInterface({ input: child.stdout });
    const stderrLines = readline.createInterface({ input: child.stderr });

    stdoutLines.on('line', (line) => {
      lastOutputAt = Date.now();
      const event = parseEventLine(line);
      if (event?.type === 'fatal' && event.message) lastStructuredError = event.message;
      if (event) emitToRenderer(event);
      else if (line.trim()) emitToRenderer({ type: 'log', level: 'info', message: line, source: 'stdout' });
    });

    stderrLines.on('line', (line) => {
      lastOutputAt = Date.now();
      rawStderr.push(line);
      if (line.trim()) emitToRenderer({ type: 'log', level: 'error', message: line, source: 'stderr' });
    });

    child.on('error', (error) => {
      clearHeartbeat();
      activeProcess = null;
      activeRun = null;
      emitToRenderer({ type: 'process', status: 'error', mode: modeName, message: error.message });
      reject(error);
    });

    child.on('close', (code, signal) => {
      clearHeartbeat();
      activeProcess = null;
      activeRun = null;
      emitToRenderer({
        type: 'process',
        status: code === 0 ? 'completed' : 'failed',
        mode: modeName,
        code,
        signal,
        elapsed_seconds: Math.floor((Date.now() - startedAt) / 1000),
        stderr: rawStderr.slice(-30).join('\n')
      });
      if (code === 0) resolve({ code, signal });
      else reject(new Error(lastStructuredError || rawStderr.slice(-10).join('\n') || `Rscript berhenti dengan kode ${code}.`));
    });
  });
}

async function selectFile(filters) {
  const result = await dialog.showOpenDialog(mainWindow, { properties: ['openFile'], filters });
  return result.canceled ? '' : result.filePaths[0];
}

ipcMain.handle('dialog:pointCloud', () => selectFile([{ name: 'Point Cloud', extensions: ['las', 'laz'] }]));
ipcMain.handle('dialog:treePoints', () => selectFile([{ name: 'Titik spasial', extensions: ['shp', 'gpkg', 'geojson', 'json'] }]));
ipcMain.handle('dialog:dtm', () => selectFile([{ name: 'GeoTIFF DTM', extensions: ['tif', 'tiff'] }]));
ipcMain.handle('dialog:rscript', () => selectFile([{ name: 'Rscript', extensions: ['exe'] }, { name: 'Semua file', extensions: ['*'] }]));
ipcMain.handle('dialog:outputFolder', async () => {
  const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory', 'createDirectory'] });
  return result.canceled ? '' : result.filePaths[0];
});

ipcMain.handle('app:getState', () => ({ version: app.getVersion(), settings: readSettings(), rscriptCandidates: findRscriptCandidates(), packaged: app.isPackaged, activeRun }));
ipcMain.handle('app:saveSettings', (_event, settings) => { writeSettings(settings || {}); return { ok: true }; });
ipcMain.handle('environment:detect', (_event, requestedPath) => {
  const rscriptPath = getRscriptPath(requestedPath);
  return { found: Boolean(rscriptPath), rscriptPath, candidates: findRscriptCandidates(), bundled: rscriptPath ? rscriptPath.includes(path.join('vendor', 'R')) : false };
});
ipcMain.handle('environment:check', async (_event, requestedPath) => {
  const rscriptPath = getRscriptPath(requestedPath);
  if (!rscriptPath) throw new Error('Rscript.exe tidak ditemukan. Pilih lokasi Rscript secara manual.');
  writeSettings({ ...readSettings(), rscriptPath });
  await runRProcess({ rscriptPath, scriptName: 'check_environment.R', args: [], modeName: 'environment-check' });
  return { ok: true, rscriptPath };
});
ipcMain.handle('environment:installPackages', async (_event, requestedPath) => {
  const rscriptPath = getRscriptPath(requestedPath);
  if (!rscriptPath) throw new Error('Rscript.exe tidak ditemukan.');
  await runRProcess({ rscriptPath, scriptName: 'install_packages.R', args: [], modeName: 'package-install' });
  return { ok: true };
});

ipcMain.handle('analysis:validate', async (_event, payload) => {
  const config = payload?.config;
  const errors = basicConfigValidation(config);
  if (errors.length) return { ok: false, errors };
  const rscriptPath = getRscriptPath(payload?.rscriptPath);
  if (!rscriptPath) return { ok: false, errors: ['Rscript.exe tidak ditemukan.'] };
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sawitheight-validate-'));
  const tempConfig = { ...config, app: { name: APP_NAME, version: app.getVersion(), run_dir: tempDir } };
  const configPath = path.join(tempDir, 'validate_config.json');
  fs.writeFileSync(configPath, JSON.stringify(tempConfig, null, 2), 'utf8');
  try {
    await runRProcess({ rscriptPath, scriptName: 'pipeline.R', args: ['validate', configPath], modeName: 'validation' });
    return { ok: true, rscriptPath };
  } catch (error) {
    return { ok: false, errors: [error.message] };
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

ipcMain.handle('analysis:start', async (_event, payload) => {
  const config = payload?.config;
  const errors = basicConfigValidation(config);
  if (errors.length) return { ok: false, errors };
  if (activeProcess) return { ok: false, errors: ['Masih ada proses yang berjalan.'] };
  const rscriptPath = getRscriptPath(payload?.rscriptPath);
  if (!rscriptPath) return { ok: false, errors: ['Rscript.exe tidak ditemukan.'] };

  writeSettings({ ...readSettings(), rscriptPath, lastConfig: config });
  const run = createRunConfig(config);
  emitToRenderer({ type: 'run-created', runDir: run.runDir, configPath: run.configPath });
  runRProcess({ rscriptPath, scriptName: 'pipeline.R', args: ['run', run.configPath], modeName: 'analysis' })
    .catch((error) => emitToRenderer({ type: 'fatal', message: error.message, runDir: run.runDir }));
  return { ok: true, runDir: run.runDir, configPath: run.configPath };
});

ipcMain.handle('analysis:cancel', async () => {
  if (!activeProcess) return { ok: false, message: 'Tidak ada proses aktif.' };
  const pid = activeProcess.pid;
  clearHeartbeat();
  if (process.platform === 'win32') spawnSync('taskkill', ['/pid', String(pid), '/T', '/F'], { windowsHide: true });
  else activeProcess.kill('SIGTERM');
  emitToRenderer({ type: 'process', status: 'cancelled', pid });
  return { ok: true };
});

ipcMain.handle('shell:openPath', async (_event, targetPath) => {
  if (!targetPath || !fs.existsSync(targetPath)) return 'Path tidak ditemukan.';
  return shell.openPath(targetPath);
});
ipcMain.handle('shell:showItem', (_event, targetPath) => {
  if (targetPath && fs.existsSync(targetPath)) shell.showItemInFolder(targetPath);
  return { ok: true };
});
ipcMain.handle('help:openTutorial', async () => {
  const tutorial = app.isPackaged ? getResourcePath('docs', 'reference_tutorial.html') : path.join(__dirname, '..', 'docs', 'reference_tutorial.html');
  if (!fs.existsSync(tutorial)) throw new Error('File tutorial tidak ditemukan.');
  return shell.openPath(tutorial);
});

app.setName(APP_NAME);
app.setAppUserModelId('com.pmnp.sawitheight');
app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on('before-quit', (event) => {
  if (!activeProcess) return;
  event.preventDefault();
  const pid = activeProcess.pid;
  clearHeartbeat();
  if (process.platform === 'win32') spawnSync('taskkill', ['/pid', String(pid), '/T', '/F'], { windowsHide: true });
  else activeProcess.kill('SIGTERM');
  activeProcess = null;
  app.exit(0);
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
