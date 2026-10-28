import { KeyDetector } from '../detector/engine.js';
import { getSettings, setScanStatus, getScanStatus, clearScanData } from '../shared/storage.js';
import { MESSAGE_TYPES, validateMessage } from '../shared/messages.js';

let detector = null;

const initializeDetector = () => {
  if (!detector) {
    detector = new KeyDetector();
  }
  return detector;
};

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleRuntimeMessage(message, sender, sendResponse);
  return true;
});

async function handleRuntimeMessage(message, sender, sendResponse) {
  try {
    switch (message.type) {
      case MESSAGE_TYPES.SCAN_PAGE:
        return await handleScanPage(message.payload, sender);

      case MESSAGE_TYPES.SCAN_LAYERS:
        return await handleLayeredScan(message.payload, sender);

      case MESSAGE_TYPES.OLLAMA_CHECK:
        return await handleOllamaCheck(message.payload, sender);

      case MESSAGE_TYPES.GET_PATTERNS:
        return {
          patterns: await getPatterns()
        };

      case MESSAGE_TYPES.GET_STATUS:
        return {
          status: 'ready',
          version: chrome.runtime.getManifest().version
        };

      case MESSAGE_TYPES.UPDATE_SETTINGS:
        return await updateSettings(message.payload);

      case MESSAGE_TYPES.GET_SETTINGS:
        return await getCurrentSettings();

      case MESSAGE_TYPES.CLEAR_RESULTS:
        return await clearResults(message.payload.tabId);

      default:
        return {
          error: `Unknown message type: ${message.type}`
        };
    }
  } catch (error) {
    console.error('Runtime message error:', error);
    return {
      error: error.message || 'Unknown error occurred'
    };
  }
}

async function handleScanPage(payload, sender) {
  const { tabId, url, options } = payload;

  try {
    const detectorInstance = initializeDetector();

    updatePopupProgress(tabId, 'Fetching page content...', 10);

    const pageContent = await fetchPageContent(url);

    updatePopupProgress(tabId, 'Analyzing source code...', 30);

    const patterns = await detectorInstance.getPatterns();
    const selectedPatterns = options?.patterns || Object.keys(patterns);

    const scanOptions = {
      patterns: selectedPatterns,
      includeSourceMap: options?.includeSourceMap || false,
      includeEntropy: options?.includeEntropy || false
    };

    updatePopupProgress(tabId, `Scanning with ${selectedPatterns.length} patterns...`, 50);

    const results = await detectorInstance.scan(pageContent, scanOptions);

    updatePopupProgress(tabId, 'Generating report...', 80);

    const report = await generateReport(results, url);

    updatePopupProgress(tabId, 'Complete!', 100);

    setTimeout(() => hidePopupProgress(tabId), 500);

    return {
      results: report,
      url: url,
      timestamp: new Date().toISOString()
    };

  } catch (error) {
    console.error('Scan error:', error);
    hidePopupProgress(tabId);
    return {
      error: error.message || 'Failed to scan page',
      results: []
    };
  }
}

async function handleLayeredScan(payload, sender) {
  const { tabId, layers, settings } = payload;

  try {
    await setScanStatus({ status: 'scanning', progress: 0, layers: layers });

    const allResults = [];
    let completedLayers = 0;
    const totalLayers = layers.length;

    for (const layer of layers) {
      updatePopupProgress(tabId, `Scanning Layer ${layer}...`, (completedLayers / totalLayers) * 100);

      let layerResults = [];

      switch (layer) {
        case 1:
          layerResults = await performLayer1Scan(tabId);
          break;
        case 2:
          layerResults = await performLayer2Scan(tabId);
          break;
        case 3:
          layerResults = await performLayer3Scan(tabId);
          break;
        default:
          console.warn(`Unknown layer: ${layer}`);
      }

      allResults.push(...layerResults);
      completedLayers++;

      await setScanStatus({
        status: 'scanning',
        progress: (completedLayers / totalLayers) * 100,
        currentLayer: layer,
        results: allResults
      });
    }

    const finalReport = await generateReport(allResults, sender?.tab?.url || 'unknown');

    await setScanStatus({
      status: 'complete',
      progress: 100,
      results: finalReport
    });

    return {
      results: finalReport,
      layersScanned: layers,
      timestamp: new Date().toISOString()
    };

  } catch (error) {
    console.error('Layered scan error:', error);
    await setScanStatus({ status: 'error', error: error.message });
    return {
      error: error.message || 'Failed to perform layered scan',
      results: []
    };
  }
}

async function performLayer1Scan(tabId) {
  try {
    const content = await chrome.tabs.sendMessage(tabId, {
      type: 'EXTRACT_PAGE_CONTENT',
      payload: {}
    });

    if (!content || !content.html) {
      return [];
    }

    const detectorInstance = initializeDetector();
    const patterns = await detectorInstance.getPatterns();

    const results = await detectorInstance.scan(content.html, {
      patterns: Object.keys(patterns),
      includeSourceMap: false,
      includeEntropy: false
    });

    return results.map(r => ({
      ...r,
      layer: 1,
      extractionMethod: 'content-script'
    }));

  } catch (error) {
    console.error('Layer 1 scan error:', error);
    return [];
  }
}

async function performLayer2Scan(tabId) {
  try {
    const networkLogs = await chrome.tabs.sendMessage(tabId, {
      type: 'GET_NETWORK_LOGS',
      payload: {}
    });

    if (!networkLogs || !networkLogs.requests) {
      return [];
    }

    const detectorInstance = initializeDetector();
    const patterns = await detectorInstance.getPatterns();

    const allResults = [];

    for (const request of networkLogs.requests) {
      const results = await detectorInstance.scan(request.body || request.url, {
        patterns: Object.keys(patterns),
        includeSourceMap: false,
        includeEntropy: false
      });

      allResults.push(
        ...results.map(r => ({
          ...r,
          layer: 2,
          extractionMethod: 'network-monitor',
          requestUrl: request.url,
          requestMethod: request.method
        }))
      );
    }

    return allResults;

  } catch (error) {
    console.error('Layer 2 scan error:', error);
    return [];
  }
}

async function performLayer3Scan(tabId) {
  try {
    const sourceMaps = await chrome.tabs.sendMessage(tabId, {
      type: 'EXTRACT_SOURCE_MAPS',
      payload: {}
    });

    if (!sourceMaps || !sourceMaps.maps) {
      return [];
    }

    const detectorInstance = initializeDetector();
    const patterns = await detectorInstance.getPatterns();

    const allResults = [];

    for (const sourceMap of sourceMaps.maps) {
      const results = await detectorInstance.scan(sourceMap.content, {
        patterns: Object.keys(patterns),
        includeSourceMap: true,
        includeEntropy: false
      });

      allResults.push(
        ...results.map(r => ({
          ...r,
          layer: 3,
          extractionMethod: 'source-map',
          sourceMapUrl: sourceMap.url
        }))
      );
    }

    return allResults;

  } catch (error) {
    console.error('Layer 3 scan error:', error);
    return [];
  }
}

async function handleOllamaCheck(payload, sender) {
  const { tabId, context, model, url } = payload;

  try {
    updatePopupProgress(tabId, 'Sending to Ollama for analysis...', 50);

    const ollamaConfig = await getOllamaConfig();
    const ollamaUrl = url || ollamaConfig.ollamaUrl;
    const ollamaModel = model || ollamaConfig.ollamaModel;

    const response = await fetch(`${ollamaUrl}/api/generate`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: ollamaModel,
        prompt: `Analyze the following code context for potential secrets, keys, or credentials. Return a JSON object with findings array containing objects with: category, severity, location, context, and confidence (0-1). If no secrets found, return {"findings": []}.

Context:
${context}`,
        stream: false
      })
    });

    if (!response.ok) {
      throw new Error(`Ollama API error: ${response.status}`);
    }

    const data = await response.json();
    const analysis = JSON.parse(data.response);

    updatePopupProgress(tabId, 'Analysis complete!', 100);

    return {
      analysis: analysis,
      model: ollamaModel,
      timestamp: new Date().toISOString()
    };

  } catch (error) {
    console.error('Ollama check error:', error);
    hidePopupProgress(tabId);
    return {
      error: error.message || 'Failed to connect to Ollama',
      analysis: { findings: [] }
    };
  }
}

async function updateSettings(payload) {
  try {
    await saveSettings(payload.settings);
    return { success: true };
  } catch (error) {
    console.error('Settings update error:', error);
    return { error: error.message };
  }
}

async function getCurrentSettings() {
  try {
    const settings = await getSettings();
    return { settings };
  } catch (error) {
    console.error('Settings retrieval error:', error);
    return { error: error.message };
  }
}

async function clearResults(tabId) {
  try {
    await clearScanData();
    return { success: true };
  } catch (error) {
    console.error('Clear results error:', error);
    return { error: error.message };
  }
}

async function fetchPageContent(targetUrl) {
  try {
    const response = await fetch(targetUrl);

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const text = await response.text();
    return text;

  } catch (error) {
    console.error('Fetch error:', error);
    throw new Error('Failed to fetch page content');
  }
}

async function generateReport(results, url) {
  const report = [];

  for (const finding of results) {
    const locationInfo = extractLocationInfo(finding);

    report.push({
      id: crypto.randomUUID(),
      category: finding.category,
      patternId: finding.patternId,
      severity: finding.severity,
      location: locationInfo.full,
      context: finding.context,
      confidence: finding.confidence || 'medium',
      timestamp: new Date().toISOString(),
      url: url,
      layer: finding.layer || 1,
      extractionMethod: finding.extractionMethod || 'direct'
    });
  }

  return report.sort((a, b) => severityOrder(b.severity) - severityOrder(a.severity));
}

function extractLocationInfo(finding) {
  const line = finding.line || 'unknown';
  const column = finding.column || 'unknown';

  return {
    line: line,
    column: column,
    full: `Line ${line}, Column ${column}`
  };
}

function severityOrder(severity) {
  const orders = {
    critical: 4,
    high: 3,
    medium: 2,
    low: 1
  };
  return orders[severity] || 0;
}

function updatePopupProgress(tabId, text, percentage) {
  chrome.tabs.sendMessage(tabId, {
    type: 'UPDATE_PROGRESS',
    payload: {
      tabId: tabId,
      text: text,
      percentage: percentage
    }
  }).catch(() => {});
}

function hidePopupProgress(tabId) {
  chrome.tabs.sendMessage(tabId, {
    type: 'HIDE_PROGRESS',
    payload: {
      tabId: tabId
    }
  }).catch(() => {});
}

async function getPatterns() {
  const detectorInstance = initializeDetector();
  return await detectorInstance.getPatterns();
}

async function saveSettings(settings) {
  await chrome.storage.local.set({ keysource_settings: settings });
}

async function getOllamaConfig() {
  const result = await chrome.storage.local.get('keysource_ollama_config');
  return {
    ollamaUrl: 'http://localhost:11434',
    ollamaModel: 'llama3.2',
    ...result.keysource_ollama_config
  };
}
