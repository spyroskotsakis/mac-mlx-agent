// Background service worker for KeySourceCheck extension
const scanQueue = new Map();
const activeScans = new Set();
const scanResults = new Map();

// Initialize storage and settings
chrome.runtime.onInstalled.addListener(() => {
  // Set default settings
  chrome.storage.local.get(['settings'], (result) => {
    if (!result.settings) {
      chrome.storage.local.set({
        settings: {
          enabled: false,
          ollamaEnabled: true,
          ollamaUrl: 'http://localhost:11434',
          ollamaModel: 'qwen3-coder:480b-cloud',
          maxConcurrent: 3,
          rateLimitMs: 400
        }
      });
    }
  });
});

// Handle messages from content script
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'extractedContent') {
    handleExtractedContent(message.data, sender);
  } else if (message.type === 'scanResult') {
    handleScanResult(message.data, sender);
  }
});

// Handle extracted content from content script
async function handleExtractedContent(data, sender) {
  const tabId = sender.tab.id;
  const origin = new URL(sender.url).origin;
  
  // Store the extracted content for scanning
  const scanId = `tab-${tabId}-${Date.now()}`
  chrome.storage.local.set({
    [`scan-${scanId}`]: {
      ...data,
      timestamp: Date.now(),
      status: 'pending'
    }
  });
}

// Handle scan results from content script
async function handleScanResult(data, sender) {
  const tabId = sender.tab.id;
  const origin = new URL(sender.url).origin;
  
  // Store scan results
  const scanId = `tab-${tabId}-${Date.now()}`
  chrome.storage.local.set({
    [`scan-${scanId}`]: {
      ...data,
      timestamp: Date.now()
    }
  });
}

// Handle tab updates
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete' && tab.url) {
    handlePageLoad(tab);
  }
});

// Handle navigation events
chrome.webNavigation.onCommitted.addListener((details) => {
  handlePageLoad(details);
});

// Handle page load
async function handlePageLoad(tab) {
  // Check if extension is enabled
  chrome.storage.local.get(['settings'], (result) => {
    const settings = result.settings || {};
    if (!settings.enabled) return;
    
    // Start scanning for this page
    startScanForTab(tab.id);
  });
}

// Start scanning for a specific tab
async function startScanForTab(tabId) {
  // Get tab URL
  const tab = await chrome.tabs.get(tabId);
  
  // Send message to content script to extract content
  chrome.tabs.sendMessage(tabId, {type: 'extractContent'});
}

// Handle settings change
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'updateSettings') {
    chrome.storage.local.set({settings: message.settings});
    sendResponse({success: true});
    return true;
  }
});

// Handle settings request
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'getSettings') {
    chrome.storage.local.get(['settings'], (result) => {
      sendResponse({settings: result.settings || {}});
    });
    return true;
  }
});

// Handle scan request from popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'startScan') {
    startScanForTab(sender.tab.id);
    sendResponse({success: true});
    return true;
  }
});

// Handle settings update
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'updateSettings') {
    chrome.storage.local.set({settings: message.settings});
    sendResponse({success: true});
    return true;
  }
});

// Handle scan results request
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'getScanResults') {
    chrome.storage.local.get(null, (items) => {
      const scanResults = {};
      Object.keys(items).forEach(key => {
        if (key.startsWith('scan')) {
          scanResults[key] = items[key];
        }
      });
      sendResponse({scanResults: scanResults});
    });
    return true;
  }
});

// Handle badge update
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'updateBadge') {
    const {tabId, count, severity} = message;
    chrome.browserAction.setBadgeText({text: count.toString(), tabId: tabId});
    chrome.browserAction.setBadgeBackgroundColor({color: severityColor(severity), tabId: tabId});
    return true;
  }
});

// Get color for severity level
function severityColor(severity) {
  switch (severity) {
    case 'critical':
      return '#FF0000';
    case 'high':
      return '#FF5733';
    case 'medium':
      return '#FF8C00';
    case 'low':
      return '#00FF00';
    default:
      return '#0000FF';
  }
}