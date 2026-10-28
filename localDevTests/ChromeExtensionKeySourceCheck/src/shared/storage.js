const STORAGE_KEYS = {
  PATTERNS: 'keysource_patterns',
  SETTINGS: 'keysource_settings',
  SCAN_HISTORY: 'keysource_scan_history',
  OLLAMA_CONFIG: 'keysource_ollama_config',
  SCAN_STATUS: 'keysource_scan_status',
};

const DEFAULT_SETTINGS = {
  enableLayer1: true,
  enableLayer2: true,
  enableLayer3: true,
  enableLayer4: false,
  ollamaUrl: 'http://localhost:11434',
  ollamaModel: 'llama3.2',
  scanDepth: 'standard',
  excludeDomains: [],
  alertOnFind: true,
  logLevel: 'info',
};

async function getPatterns() {
  const result = await chrome.storage.local.get(STORAGE_KEYS.PATTERNS);
  return result[STORAGE_KEYS.PATTERNS] || {};
}

async function savePatterns(patterns) {
  await chrome.storage.local.set({ [STORAGE_KEYS.PATTERNS]: patterns });
}

async function getSettings() {
  const result = await chrome.storage.local.get(STORAGE_KEYS.SETTINGS);
  return { ...DEFAULT_SETTINGS, ...result[STORAGE_KEYS.SETTINGS] };
}

async function saveSettings(settings) {
  await chrome.storage.local.set({ [STORAGE_KEYS.SETTINGS]: settings });
}

async function getScanHistory() {
  const result = await chrome.storage.local.get(STORAGE_KEYS.SCAN_HISTORY);
  return result[STORAGE_KEYS.SCAN_HISTORY] || [];
}

async function saveScanHistory(history) {
  await chrome.storage.local.set({ [STORAGE_KEYS.SCAN_HISTORY]: history });
}

async function getOllamaConfig() {
  const result = await chrome.storage.local.get(STORAGE_KEYS.OLLAMA_CONFIG);
  return { ...DEFAULT_SETTINGS, ...result[STORAGE_KEYS.OLLAMA_CONFIG] };
}

async function saveOllamaConfig(config) {
  await chrome.storage.local.set({ [STORAGE_KEYS.OLLAMA_CONFIG]: config });
}

async function setScanStatus(status) {
  await chrome.storage.local.set({ [STORAGE_KEYS.SCAN_STATUS]: status });
}

async function getScanStatus() {
  const result = await chrome.storage.local.get(STORAGE_KEYS.SCAN_STATUS);
  return result[STORAGE_KEYS.SCAN_STATUS] || { status: 'idle', progress: 0 };
}

async function clearScanData() {
  await chrome.storage.local.remove([
    STORAGE_KEYS.SCAN_STATUS,
    STORAGE_KEYS.SCAN_HISTORY,
  ]);
}

export {
  STORAGE_KEYS,
  DEFAULT_SETTINGS,
  getPatterns,
  savePatterns,
  getSettings,
  saveSettings,
  getScanHistory,
  saveScanHistory,
  getOllamaConfig,
  saveOllamaConfig,
  setScanStatus,
  getScanStatus,
  clearScanData,
};
