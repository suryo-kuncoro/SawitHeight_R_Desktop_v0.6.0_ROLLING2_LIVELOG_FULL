const $ = (id) => document.getElementById(id);
const state = {
  running: false,
  currentRunDir: '',
  reportPath: '',
  summary: null,
  environmentReady: false,
  missingPackages: [],
  lastHeartbeat: null,
  lastOutputAt: null
};

const stageOrder = [
  'validation','load','qc','registration','ground','terrain_qc','normalize',
  'metrics_prev','metrics_curr','delta','uncertainty','peer','decision','zone','export','complete'
];
const pageTitles = {
  'data-page': 'Data & Pair',
  'parameter-page': 'Terrain & QC',
  'process-page': 'Proses & Live Log',
  'result-page': 'Hasil & Residual'
};

function showAlert(message, type = 'info', timeout = 0) {
  const box = document.createElement('div');
  box.className = `alert ${type}`;
  const text = document.createElement('span');
  text.textContent = message;
  const close = document.createElement('button');
  close.className = 'ghost'; close.textContent = '×'; close.addEventListener('click', () => box.remove());
  box.append(text, close); $('alert-area').prepend(box);
  if (timeout) setTimeout(() => box.remove(), timeout);
}

function appendLog(message, level = 'info', timestamp = '') {
  if (!message) return;
  const stamp = timestamp ? timestamp.replace('T', ' ').slice(0, 19) : new Date().toLocaleTimeString('id-ID');
  const prefix = level === 'error' ? '[ERROR]' : level === 'warning' ? '[WARN ]' : level === 'success' ? '[ OK  ]' : '[INFO ]';
  const output = $('log-output');
  if (output.textContent === 'Belum ada proses.' || output.textContent === 'Memulai backend R...') output.textContent = '';
  output.textContent += `${output.textContent ? '\n' : ''}${stamp} ${prefix} ${message}`;
  state.lastOutputAt = Date.now();
  if ($('auto-scroll-log').checked) output.scrollTop = output.scrollHeight;
}

function switchPage(pageId) {
  document.querySelectorAll('.page').forEach((p) => p.classList.toggle('active', p.id === pageId));
  document.querySelectorAll('.nav-btn').forEach((b) => b.classList.toggle('active', b.dataset.page === pageId));
  $('page-title').textContent = pageTitles[pageId] || '';
}

function setRunning(running) {
  state.running = running;
  $('run-btn').disabled = running;
  $('validate-btn').disabled = running;
  $('check-env-btn').disabled = running;
  $('install-packages-btn').disabled = running || !state.missingPackages.length;
  $('cancel-btn').disabled = !running;
  const live = $('live-process-state');
  live.textContent = running ? 'RUNNING' : 'IDLE';
  live.className = running ? 'alive' : '';
}

function setProgress(progress, label = '', stage = '') {
  const value = Math.max(0, Math.min(100, Number(progress) || 0));
  $('progress-fill').style.width = `${value}%`;
  $('progress-number').textContent = `${Math.round(value)}%`;
  if (label) $('stage-label').textContent = label;
  if (stage) updateStages(stage);
}

function updateStages(currentStage) {
  const currentIndex = stageOrder.indexOf(currentStage);
  document.querySelectorAll('#stage-list [data-stage]').forEach((el) => {
    const idx = stageOrder.indexOf(el.dataset.stage);
    el.classList.toggle('active', idx === currentIndex);
    el.classList.toggle('done', currentIndex > idx || currentStage === 'complete');
  });
}

function setRuntimeStatus(status, detail) {
  const pill = $('runtime-status');
  pill.className = `status-pill ${status}`;
  pill.textContent = status === 'ready' ? 'Siap' : status === 'missing' ? 'Package belum lengkap' : status === 'error' ? 'Error' : 'Belum diperiksa';
  $('runtime-version').textContent = detail || '';
}

function formatDuration(totalSeconds) {
  const s = Math.max(0, Number(totalSeconds) || 0);
  const hh = String(Math.floor(s / 3600)).padStart(2, '0');
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, '0');
  const ss = String(Math.floor(s % 60)).padStart(2, '0');
  return `${hh}:${mm}:${ss}`;
}

function updateHeartbeat(event) {
  state.lastHeartbeat = event;
  $('elapsed-time').textContent = formatDuration(event.elapsed_seconds);
  const idle = Number(event.idle_seconds || 0);
  $('last-activity').textContent = idle < 2 ? 'baru saja' : `${idle} dtk`;
  const live = $('live-process-state');
  if (!state.running) { live.textContent = 'IDLE'; live.className = ''; return; }
  if (idle >= 120) { live.textContent = 'RUNNING · IDLE LAMA'; live.className = 'warn'; }
  else { live.textContent = 'RUNNING'; live.className = 'alive'; }
}

function numeric(id) { return Number($(id).value); }
function checked(id) { return $(id).checked; }

function collectConfig() {
  return {
    inputs: {
      prev_point_cloud: $('prev-point-cloud').value.trim(),
      curr_point_cloud: $('curr-point-cloud').value.trim(),
      tree_points: $('tree-points').value.trim(),
      external_dtm_prev: $('external-dtm-prev').value.trim(),
      external_dtm_curr: $('external-dtm-curr').value.trim(),
      master_point_cloud: $('master-point-cloud').value.trim(),
      output_root: $('output-root').value.trim()
    },
    parameters: {
      prev_period_code: $('prev-period-code').value.trim().toUpperCase(),
      curr_period_code: $('curr-period-code').value.trim().toUpperCase(),
      tree_id_field: $('tree-id-field').value.trim(),
      peer_field: $('peer-field').value.trim(),
      use_master_reference: checked('use-master-reference'),
      master_period_code: $('master-period-code').value.trim().toUpperCase(),
      registration_qc_confirmed: checked('registration-qc-confirmed'),
      terrain_mode_prev: $('terrain-mode-prev').value,
      terrain_mode_curr: $('terrain-mode-curr').value,
      fallback_epsg: numeric('fallback-epsg'),
      remove_duplicates: checked('remove-duplicates'),
      run_noise_filter: checked('run-noise-filter'),
      sor_k: numeric('sor-k'),
      sor_m: numeric('sor-m'),
      csf_cloth_resolution: numeric('csf-cloth-resolution'),
      csf_class_threshold: numeric('csf-class-threshold'),
      csf_rigidness: numeric('csf-rigidness'),
      dtm_resolution_m: numeric('dtm-resolution'),
      holdout_train_frac: numeric('holdout-train-frac'),
      holdout_seed: numeric('holdout-seed'),
      holdout_min_ground: numeric('holdout-min-ground'),
      holdout_max_ground: numeric('holdout-max-ground'),
      buffer_radius_m: numeric('buffer-radius'),
      min_veg_h_m: numeric('min-veg-h'),
      min_normalized_z_m: numeric('min-normalized-z'),
      metrics_chunk_size: numeric('metrics-chunk-size'),
      create_nchm: checked('create-nchm'),
      create_qc_plots: checked('create-qc-plots'),
      save_normalized_laz: checked('save-normalized-laz'),
      chm_resolution_m: numeric('chm-resolution'),
      threads: numeric('threads')
    }
  };
}

function applyConfig(config) {
  if (!config) return;
  const i = config.inputs || {};
  const p = config.parameters || {};
  const map = {
    'prev-point-cloud': i.prev_point_cloud,
    'curr-point-cloud': i.curr_point_cloud,
    'tree-points': i.tree_points,
    'external-dtm-prev': i.external_dtm_prev,
    'external-dtm-curr': i.external_dtm_curr,
    'master-point-cloud': i.master_point_cloud,
    'output-root': i.output_root,
    'prev-period-code': p.prev_period_code,
    'curr-period-code': p.curr_period_code,
    'tree-id-field': p.tree_id_field,
    'peer-field': p.peer_field,
    'master-period-code': p.master_period_code,
    'terrain-mode-prev': p.terrain_mode_prev || 'CSF_TIN',
    'terrain-mode-curr': p.terrain_mode_curr || 'CSF_TIN',
    'fallback-epsg': p.fallback_epsg,
    'sor-k': p.sor_k,
    'sor-m': p.sor_m,
    'csf-cloth-resolution': p.csf_cloth_resolution,
    'csf-class-threshold': p.csf_class_threshold,
    'csf-rigidness': p.csf_rigidness,
    'dtm-resolution': p.dtm_resolution_m,
    'holdout-train-frac': p.holdout_train_frac,
    'holdout-seed': p.holdout_seed,
    'holdout-min-ground': p.holdout_min_ground,
    'holdout-max-ground': p.holdout_max_ground,
    'buffer-radius': p.buffer_radius_m,
    'min-veg-h': p.min_veg_h_m,
    'min-normalized-z': p.min_normalized_z_m,
    'metrics-chunk-size': p.metrics_chunk_size,
    'chm-resolution': p.chm_resolution_m,
    'threads': p.threads
  };
  for (const [id, value] of Object.entries(map)) if (value !== undefined && value !== null) $(id).value = value;

  const checks = {
    'use-master-reference': p.use_master_reference,
    'registration-qc-confirmed': p.registration_qc_confirmed,
    'remove-duplicates': p.remove_duplicates,
    'run-noise-filter': p.run_noise_filter,
    'create-nchm': p.create_nchm,
    'create-qc-plots': p.create_qc_plots,
    'save-normalized-laz': p.save_normalized_laz
  };
  for (const [id, value] of Object.entries(checks)) if (value !== undefined) $(id).checked = Boolean(value);
  syncConditionalFields();
}

function syncConditionalFields() {
  const master = checked('use-master-reference');
  $('master-period-card').classList.toggle('hidden', !master);
  $('master-point-card').classList.toggle('hidden', !master);
  $('external-dtm-prev-card').classList.toggle('hidden', $('terrain-mode-prev').value !== 'EXTERNAL_DTM');
  $('external-dtm-curr-card').classList.toggle('hidden', $('terrain-mode-curr').value !== 'EXTERNAL_DTM');
}

async function checkEnvironment() {
  setRunning(true);
  setRuntimeStatus('neutral', 'Memeriksa R dan package...');
  switchPage('process-page');
  appendLog('Memeriksa environment R...');
  try {
    const result = await window.sawitHeight.checkEnvironment($('rscript-path').value.trim());
    $('rscript-path').value = result.rscriptPath;
  } catch (error) {
    setRuntimeStatus('error', error.message);
    showAlert(error.message, 'error');
    appendLog(error.message, 'error');
    setRunning(false);
  }
}

async function validateInputs() {
  setRunning(true);
  switchPage('process-page');
  setProgress(2, 'Validasi input', 'validation');
  appendLog('Validasi input rolling pair dimulai...');
  try {
    const response = await window.sawitHeight.validateAnalysis({ config: collectConfig(), rscriptPath: $('rscript-path').value.trim() });
    if (!response.ok) throw new Error((response.errors || ['Validasi gagal.']).join('\n'));
    showAlert('Validasi berhasil. Pair siap diproses.', 'success');
    appendLog('Validasi berhasil.', 'success');
    setProgress(100, 'Validasi berhasil', 'complete');
  } catch (error) {
    showAlert(error.message, 'error');
    appendLog(error.message, 'error');
  } finally {
    setRunning(false);
  }
}

async function startAnalysis() {
  state.summary = null;
  state.reportPath = '';
  $('log-output').textContent = 'Memulai backend R...';
  $('elapsed-time').textContent = '00:00:00';
  $('last-activity').textContent = '-';
  switchPage('process-page');
  setProgress(1, 'Menyiapkan rolling pair', 'validation');
  setRunning(true);
  try {
    const response = await window.sawitHeight.startAnalysis({ config: collectConfig(), rscriptPath: $('rscript-path').value.trim() });
    if (!response.ok) throw new Error((response.errors || ['Gagal memulai analisis.']).join('\n'));
    state.currentRunDir = response.runDir;
    $('run-dir-line').textContent = response.runDir;
    appendLog(`Folder run: ${response.runDir}`);
  } catch (error) {
    showAlert(error.message, 'error'); appendLog(error.message, 'error'); setRunning(false);
  }
}

function renderResults(summary, reportPath) {
  state.summary = summary;
  state.currentRunDir = summary.run_dir || state.currentRunDir;
  state.reportPath = reportPath || '';
  $('empty-result').classList.add('hidden');
  $('result-content').classList.remove('hidden');

  const metrics = [
    ['Pair', `${summary.prev_period_code || '-'} → ${summary.curr_period_code || '-'}`],
    ['TREE_ID', Number(summary.tree_count || 0).toLocaleString('id-ID')],
    ['Median P95 Prev', summary.p95_prev_median == null ? '-' : `${Number(summary.p95_prev_median).toFixed(2)} m`],
    ['Median P95 Curr', summary.p95_curr_median == null ? '-' : `${Number(summary.p95_curr_median).toFixed(2)} m`],
    ['Median ΔP95', summary.delta_p95_median == null ? '-' : `${Number(summary.delta_p95_median).toFixed(3)} m`],
    ['T_TERRAIN', summary.t_terrain_m == null ? '-' : `${Number(summary.t_terrain_m).toFixed(3)} m`],
    ['T_METRIC', summary.t_metric_m == null ? '-' : `${Number(summary.t_metric_m).toFixed(3)} m`],
    ['T_TECH', summary.t_tech_m == null ? '-' : `${Number(summary.t_tech_m).toFixed(3)} m`],
    ['Residual', Number(summary.residual_count || 0).toLocaleString('id-ID')],
    ['Residual %', summary.residual_pct == null ? '-' : `${Number(summary.residual_pct).toFixed(2)}%`],
    ['Stable', Number(summary.stable_count || 0).toLocaleString('id-ID')],
    ['Residual Zones', Number(summary.zone_count || 0).toLocaleString('id-ID')],
    ['NMAD Terrain Prev', summary.terrain_nmad_prev_m == null ? '-' : `${Number(summary.terrain_nmad_prev_m).toFixed(3)} m`],
    ['NMAD Terrain Curr', summary.terrain_nmad_curr_m == null ? '-' : `${Number(summary.terrain_nmad_curr_m).toFixed(3)} m`],
    ['Density Prev', summary.density_prev_m2 == null ? '-' : `${Number(summary.density_prev_m2).toFixed(1)} pt/m²`],
    ['Density Curr', summary.density_curr_m2 == null ? '-' : `${Number(summary.density_curr_m2).toFixed(1)} pt/m²`]
  ];
  $('metric-grid').innerHTML = '';
  metrics.forEach(([label, value]) => {
    const card = document.createElement('div'); card.className = 'metric-card';
    const s = document.createElement('span'); s.textContent = label;
    const strong = document.createElement('strong'); strong.textContent = value;
    card.append(s, strong); $('metric-grid').append(card);
  });

  $('status-grid').innerHTML = '';
  const counts = summary.status_counts || {};
  Object.entries(counts).sort((a,b) => b[1] - a[1]).forEach(([status, count]) => {
    const item = document.createElement('div'); item.className = 'status-item';
    const s = document.createElement('span'); s.textContent = status;
    const strong = document.createElement('strong'); strong.textContent = Number(count).toLocaleString('id-ID');
    item.append(s, strong); $('status-grid').append(item);
  });

  const preview = Array.isArray(summary.preview) ? summary.preview : [];
  const table = $('preview-table'); table.innerHTML = '';
  if (preview.length) {
    const headers = Object.keys(preview[0]);
    const thead = document.createElement('thead'); const trh = document.createElement('tr');
    headers.forEach((h) => { const th = document.createElement('th'); th.textContent = h; trh.append(th); });
    thead.append(trh); table.append(thead);
    const tbody = document.createElement('tbody');
    preview.forEach((row) => {
      const tr = document.createElement('tr');
      headers.forEach((h) => { const td = document.createElement('td'); td.textContent = row[h] ?? ''; tr.append(td); });
      tbody.append(tr);
    });
    table.append(tbody);
  }

  $('output-list').innerHTML = '';
  (summary.output_files || []).forEach((filePath) => {
    const item = document.createElement('div'); item.className = 'output-item';
    const info = document.createElement('div');
    const name = document.createElement('b'); name.textContent = String(filePath).split(/[\\/]/).pop();
    const pathEl = document.createElement('small'); pathEl.textContent = filePath;
    info.append(name, pathEl);
    const btn = document.createElement('button'); btn.className = 'ghost'; btn.textContent = 'Tampilkan';
    btn.addEventListener('click', () => window.sawitHeight.showItem(filePath));
    item.append(info, btn); $('output-list').append(item);
  });
}

function handleBackendEvent(event) {
  if (!event || typeof event !== 'object') return;
  if (event.type === 'log') appendLog(event.message || '', event.level || 'info', event.timestamp || '');
  if (event.type === 'progress') {
    setProgress(event.progress, event.label, event.stage);
    if (event.detail) appendLog(event.detail, 'info', event.timestamp || '');
  }
  if (event.type === 'heartbeat') updateHeartbeat(event);
  if (event.type === 'run-created') {
    state.currentRunDir = event.runDir;
    $('run-dir-line').textContent = event.runDir;
  }
  if (event.type === 'environment') {
    state.missingPackages = (event.packages || []).filter((p) => !p.installed).map((p) => p.name);
    state.environmentReady = !state.missingPackages.length;
    const packageText = state.missingPackages.length ? `Hilang: ${state.missingPackages.join(', ')}` : 'Semua package tersedia';
    setRuntimeStatus(state.environmentReady ? 'ready' : 'missing', `${event.r_version} · ${packageText}`);
    $('install-packages-btn').disabled = state.running || !state.missingPackages.length;
    appendLog(`${event.r_version}; ${packageText}`, state.environmentReady ? 'success' : 'warning');
  }
  if (event.type === 'package-install') {
    appendLog(event.message || '', event.level || 'info');
    if (event.progress != null) setProgress(event.progress, 'Instalasi package R', 'validation');
  }
  if (event.type === 'validation-result' && ['valid','success'].includes(event.status)) appendLog(event.message || 'Validasi berhasil.', 'success');
  if (event.type === 'fatal') {
    appendLog(event.message || 'Fatal error.', 'error');
    showAlert(`Gagal pada tahap ${event.stage || '-'}: ${event.message}`, 'error');
    setRunning(false);
  }
  if (event.type === 'result') {
    renderResults(event.summary, event.reportPath);
    showAlert('Analisis rolling pair selesai. Residual confidence dan output GIS telah disimpan.', 'success');
    setRunning(false);
    switchPage('result-page');
  }
  if (event.type === 'process') {
    if (event.status === 'started') {
      setRunning(true);
      appendLog(`Rscript process dimulai (PID ${event.pid}).`, 'success');
    }
    if (['completed','failed','cancelled','error'].includes(event.status)) {
      setRunning(false);
      if (event.elapsed_seconds != null) $('elapsed-time').textContent = formatDuration(event.elapsed_seconds);
      if (event.status === 'completed') appendLog('Rscript process selesai.', 'success');
      if (event.status === 'cancelled') showAlert('Proses dibatalkan. Folder run mungkin berisi output parsial.', 'warning');
      if (event.status === 'failed' && !state.summary) appendLog(`Rscript berhenti dengan kode ${event.code}.`, 'error');
    }
  }
}

async function initialize() {
  document.querySelectorAll('.nav-btn').forEach((btn) => btn.addEventListener('click', () => switchPage(btn.dataset.page)));
  ['use-master-reference','terrain-mode-prev','terrain-mode-curr'].forEach((id) => $(id).addEventListener('change', syncConditionalFields));

  $('clear-log-btn').addEventListener('click', () => { $('log-output').textContent = 'Tampilan log dibersihkan. File analysis.log di folder run tetap utuh.'; });
  $('copy-log-btn').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText($('log-output').textContent); showAlert('Live log disalin.', 'success', 1800); }
    catch { showAlert('Gagal menyalin log.', 'error', 1800); }
  });

  document.querySelectorAll('[data-picker]').forEach((btn) => btn.addEventListener('click', async () => {
    const target = btn.dataset.picker;
    const actions = {
      'prev-point-cloud': window.sawitHeight.selectPointCloud,
      'curr-point-cloud': window.sawitHeight.selectPointCloud,
      'master-point-cloud': window.sawitHeight.selectPointCloud,
      'tree-points': window.sawitHeight.selectTreePoints,
      'external-dtm-prev': window.sawitHeight.selectDtm,
      'external-dtm-curr': window.sawitHeight.selectDtm,
      'output-root': window.sawitHeight.selectOutputFolder,
      'rscript-path': window.sawitHeight.selectRscript
    };
    const value = await actions[target]();
    if (value) $(target).value = value;
  }));

  $('check-env-btn').addEventListener('click', checkEnvironment);
  $('install-packages-btn').addEventListener('click', async () => {
    setRunning(true); switchPage('process-page'); setProgress(0, 'Instalasi package R', 'validation');
    try {
      await window.sawitHeight.installPackages($('rscript-path').value.trim());
      showAlert('Instalasi package selesai. Environment akan diperiksa ulang.', 'success');
      await checkEnvironment();
    } catch (error) {
      showAlert(error.message, 'error'); appendLog(error.message, 'error'); setRunning(false);
    }
  });
  $('tutorial-btn').addEventListener('click', async () => { try { await window.sawitHeight.openTutorial(); } catch (error) { showAlert(error.message, 'error'); } });
  $('validate-btn').addEventListener('click', validateInputs);
  $('run-btn').addEventListener('click', startAnalysis);
  $('cancel-btn').addEventListener('click', () => window.sawitHeight.cancelAnalysis());
  $('open-output-btn').addEventListener('click', () => window.sawitHeight.openPath(state.currentRunDir));
  $('open-report-btn').addEventListener('click', () => window.sawitHeight.openPath(state.reportPath));

  window.sawitHeight.onAnalysisEvent(handleBackendEvent);
  const appState = await window.sawitHeight.getState();
  $('app-version').textContent = `v${appState.version}`;
  if (appState.settings?.lastConfig) applyConfig(appState.settings.lastConfig);
  if (appState.settings?.rscriptPath) $('rscript-path').value = appState.settings.rscriptPath;
  if (!$('threads').value || Number($('threads').value) < 1) $('threads').value = Math.max(1, Math.min(8, navigator.hardwareConcurrency || 4));

  const detection = await window.sawitHeight.detectEnvironment($('rscript-path').value.trim());
  if (detection.found) {
    $('rscript-path').value = detection.rscriptPath;
    setRuntimeStatus('neutral', detection.bundled ? 'Bundled R ditemukan; belum diperiksa.' : 'Rscript ditemukan; belum diperiksa.');
  } else setRuntimeStatus('error', 'Rscript.exe tidak ditemukan. Pilih secara manual.');
  syncConditionalFields();
}

initialize().catch((error) => showAlert(error.message, 'error'));
