import { KeyDetector } from '../detector/engine.js';
import { parseSourceMap, extractSourceMapUrls, parseDataUrlSourceMap, getSourceMapFromContent } from '../detector/sourcemap.js';

const EXCLUDED_SELECTORS = [
  'script', 'style', 'noscript', 'link', 'meta', 'head', 'html', 'body'
];

const EXCLUDED_ATTRIBUTES = [
  'type="password"',
  'type=\'password\'',
  'autocomplete="off"',
  'autocomplete="nope"'
];

export class ContentExtractor {
  constructor() {
    this.detector = new KeyDetector();
    this.observedNodes = new Set();
    this.mutationObserver = null;
    this.networkObserver = null;
  }

  async scanPage() {
    const findings = [];

    // Layer 1: DOM scanning
    const domFindings = await this.scanDOM();
    findings.push(...domFindings);

    // Layer 3: Source map analysis
    const sourcemapFindings = await this.scanSourceMaps();
    findings.push(...sourcemapFindings);

    // Report to service worker
    chrome.runtime.sendMessage(
      { type: 'SCAN_COMPLETE', findings },
      (response) => {
        if (chrome.runtime.lastError) {
          console.error('Failed to send scan results:', chrome.runtime.lastError);
        }
      }
    );

    return findings;
  }

  async scanDOM() {
    const findings = [];
    const allElements = document.querySelectorAll('*');

    for (const element of allElements) {
      // Skip excluded elements
      if (EXCLUDED_SELECTORS.includes(element.tagName.toLowerCase())) {
        continue;
      }

      // Check text content
      if (element.childNodes) {
        for (const node of element.childNodes) {
          if (node.nodeType === Node.TEXT_NODE) {
            const text = node.textContent;
            if (text && text.trim()) {
              const results = this.detector.scanText(text);
              if (results.length > 0) {
                findings.push(...results.map(r => ({
                  ...r,
                  source: 'dom',
                  element: this.getElementInfo(element),
                  textSnippet: this.getSafeTextContext(node.textContent, r.matchIndex)
                })));
              }
            }
          }
        }
      }

      // Check attributes for secrets
      if (element.attributes) {
        for (const attr of element.attributes) {
          const attrName = attr.name.toLowerCase();
          const attrValue = attr.value;

          // Skip password fields and excluded attributes
          if (attrName === 'type' && attrValue === 'password') {
            continue;
          }
          if (EXCLUDED_ATTRIBUTES.some(excl => `${attr.name}="${attrValue}"`.toLowerCase().includes(excl.split('=')[0]))) {
            continue;
          }

          // Check common attribute names that might contain secrets
          const secretAttributeNames = [
            'data-api-key', 'data-secret', 'data-token', 'data-access-key',
            'data-aws-key', 'data-azure-key', 'data-gcp-key',
            'api-key', 'secret', 'token', 'access-key',
            'data-username', 'data-password', 'data-url'
          ];

          if (secretAttributeNames.some(name => attrName.includes(name))) {
            const results = this.detector.scanText(attrValue);
            if (results.length > 0) {
              findings.push(...results.map(r => ({
                ...r,
                source: 'dom-attribute',
                element: this.getElementInfo(element),
                attributeName: attr.name,
                attributeValue: r.matchedValue
              })));
            }
          }
        }
      }
    }

    return findings;
  }

  getElementInfo(element) {
    const info = {
      tagName: element.tagName,
      id: element.id || null,
      className: element.className || null,
      text: element.textContent?.substring(0, 100) || null,
      outerHTML: element.outerHTML?.substring(0, 500) || null
    };

    // Add custom attributes that might be relevant
    const relevantAttrs = ['data-api-key', 'data-secret', 'data-token', 'href', 'src', 'action'];
    for (const attr of relevantAttrs) {
      const value = element.getAttribute(attr);
      if (value) {
        info[`data_${attr}`] = value;
      }
    }

    return info;
  }

  getSafeTextContext(text, matchIndex) {
    if (!text || matchIndex === undefined) return '';
    const start = Math.max(0, matchIndex - 50);
    const end = Math.min(text.length, matchIndex + 50);
    let snippet = text.substring(start, end);
    // Escape HTML entities for safe display
    return snippet.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  async scanSourceMaps() {
    const findings = [];

    // Find all scripts with sourceMappingURL
    const scripts = document.querySelectorAll('script[src]');
    for (const script of scripts) {
      const src = script.src;
      if (!src || src.startsWith('data:')) continue;

      try {
        const response = await fetch(src, { mode: 'cors' });
        const content = await response.text();

        // Check for source map URLs
        const sourceMapInfo = getSourceMapFromContent(content);

        for (const url of sourceMapInfo.externalUrls) {
          const sourcemapFindings = await this.fetchAndAnalyzeSourceMap(url);
          findings.push(...sourcemapFindings);
        }

        // Check for inline source maps
        if (sourceMapInfo.hasInlineMap) {
          const inlineMap = this.extractInlineSourceMap(content);
          if (inlineMap) {
            const parsed = parseSourceMap(inlineMap);
            const mapFindings = this.analyzeSourceMapContent(parsed);
            findings.push(...mapFindings);
          }
        }
      } catch (e) {
        console.warn(`Failed to fetch script: ${src}`, e);
      }
    }

    return findings;
  }

  async fetchAndAnalyzeSourceMap(url) {
    const findings = [];

    try {
      let mapContent;

      if (url.startsWith('data:')) {
        const parsed = parseDataUrlSourceMap(url);
        if (parsed) {
          const parsedMap = parseSourceMap(parsed);
          return this.analyzeSourceMapContent(parsedMap);
        }
        return findings;
      }

      const response = await fetch(url, { mode: 'cors' });
      mapContent = await response.text();
      const parsedMap = parseSourceMap(mapContent);
      return this.analyzeSourceMapContent(parsedMap);
    } catch (e) {
      console.warn(`Failed to fetch source map: ${url}`, e);
      return findings;
    }
  }

  extractInlineSourceMap(content) {
    const dataUrlMatch = content.match(/data:application\/json;base64,([A-Za-z0-9+/=]+)/);
    if (dataUrlMatch) {
      try {
        return atob(dataUrlMatch[1]);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  analyzeSourceMapContent(parsedMap) {
    const findings = [];

    if (!parsedMap.sourcesContent) return findings;

    for (let i = 0; i < parsedMap.sourcesContent.length; i++) {
      const sourceContent = parsedMap.sourcesContent[i];
      if (sourceContent) {
        const results = this.detector.scanText(sourceContent);
        if (results.length > 0) {
          findings.push(...results.map(r => ({
            ...r,
            source: 'source-map',
            sourceFile: parsedMap.sources[i],
            sourceMapUrl: parsedMap.file
          })));
        }
      }
    }

    return findings;
  }

  startNetworkMonitoring() {
    this.networkObserver = new this.MonitorNetwork();
    this.networkObserver.start();
  }

  stopNetworkMonitoring() {
    if (this.networkObserver) {
      this.networkObserver.stop();
    }
  }

  MonitorNetwork = class {
    constructor() {
      this.originalFetch = window.fetch;
      this.originalXHROpen = XMLHttpRequest.prototype.open;
      this.originalXHRSend = XMLHttpRequest.prototype.send;
      this.originalWebSocket = window.WebSocket;
      this.isMonitoring = false;
    }

    start() {
      if (this.isMonitoring) return;
      this.isMonitoring = true;

      // Monitor fetch requests
      window.fetch = async (...args) => {
        const [resource, options] = args;
        const url = typeof resource === 'string' ? resource : resource.url;
        const method = options?.method || 'GET';
        const body = options?.body;

        if (url && this.shouldMonitorUrl(url)) {
          const findings = await this.analyzeRequest(url, method, body);
          if (findings.length > 0) {
            chrome.runtime.sendMessage(
              { type: 'NETWORK_FINDING', findings, url, method },
              (response) => {
                if (chrome.runtime.lastError) {
                  console.error('Failed to send network findings:', chrome.runtime.lastError);
                }
              }
            );
          }
        }

        return this.originalFetch.apply(window, args);
      };

      // Monitor XMLHttpRequest
      XMLHttpRequest.prototype.open = function (...args) {
        this._monitoredUrl = args[1];
        this._monitoredMethod = args[0];
        return this.originalXHROpen.apply(this, args);
      };

      XMLHttpRequest.prototype.send = async function (...args) {
        const body = args[0];
        const url = this._monitoredUrl;
        const method = this._monitoredMethod;

        if (url && this.shouldMonitorUrl(url)) {
          const findings = await this.analyzeRequest(url, method, body);
          if (findings.length > 0) {
            chrome.runtime.sendMessage(
              { type: 'NETWORK_FINDING', findings, url, method },
              (response) => {
                if (chrome.runtime.lastError) {
                  console.error('Failed to send network findings:', chrome.runtime.lastError);
                }
              }
            );
          }
        }

        return this.originalXHRSend.apply(this, args);
      };

      // Monitor WebSocket connections
      window.WebSocket = function (...args) {
        const url = args[0];
        if (url && this.shouldMonitorUrl(url)) {
          chrome.runtime.sendMessage(
            { type: 'WEBSOCKET_OPENED', url },
            (response) => {
              if (chrome.runtime.lastError) {
                console.error('Failed to send WebSocket info:', chrome.runtime.lastError);
              }
            }
          );
        }
        return new this.originalWebSocket(...args);
      }.bind({ originalWebSocket: this.originalWebSocket, shouldMonitorUrl: ContentExtractor.prototype.shouldMonitorUrl });

      // Fix WebSocket binding
      window.WebSocket = class extends this.originalWebSocket {
        constructor(...args) {
          const url = args[0];
          if (url && ContentExtractor.prototype.shouldMonitorUrl(url)) {
            chrome.runtime.sendMessage(
              { type: 'WEBSOCKET_OPENED', url },
              (response) => {
                if (chrome.runtime.lastError) {
                  console.error('Failed to send WebSocket info:', chrome.runtime.lastError);
                }
              }
            );
          }
          super(...args);
        }
      };
    }

    stop() {
      this.isMonitoring = false;
      window.fetch = this.originalFetch;
      XMLHttpRequest.prototype.open = this.originalXHROpen;
      XMLHttpRequest.prototype.send = this.originalXHRSend;
      window.WebSocket = this.originalWebSocket;
    }

    shouldMonitorUrl(url) {
      if (!url) return false;
      const excludedDomains = [
        'chrome-extension.com',
        'chrome.google.com'
      ];
      try {
        const urlObj = new URL(url);
        return !excludedDomains.some(domain => urlObj.hostname.includes(domain));
      } catch (e) {
        return true;
      }
    }

    async analyzeRequest(url, method, body) {
      const findings = [];

      // Analyze URL
      const urlFindings = this.detector.scanText(url);
      if (urlFindings.length > 0) {
        findings.push(...urlFindings.map(r => ({ ...r, requestType: 'url' })));
      }

      // Analyze request body
      if (body) {
        let bodyText = body;
        if (body instanceof FormData) {
          for (const [key, value] of body.entries()) {
            if (typeof value === 'string') {
              const results = this.detector.scanText(value);
              if (results.length > 0) {
                findings.push(...results.map(r => ({ ...r, requestType: 'form-data', formKey: key })));
              }
            }
          }
        } else if (typeof body === 'string') {
          try {
            const parsed = JSON.parse(body);
            const results = this.detector.scanText(JSON.stringify(parsed));
            if (results.length > 0) {
              findings.push(...results.map(r => ({ ...r, requestType: 'json-body' })));
            }
          } catch (e) {
            const results = this.detector.scanText(body);
            if (results.length > 0) {
              findings.push(...results.map(r => ({ ...r, requestType: 'body' })));
            }
          }
        }
      }

      return findings;
    }
  };

  startMutationObserver() {
    this.mutationObserver = new MutationObserver((mutations) => {
      let hasSecrets = false;

      for (const mutation of mutations) {
        if (mutation.type === 'childList') {
          for (const node of mutation.addedNodes) {
            if (node.nodeType === Node.ELEMENT_NODE) {
              const findings = this.scanElementForSecrets(node);
              if (findings.length > 0) {
                hasSecrets = true;
                chrome.runtime.sendMessage(
                  { type: 'DYNAMIC_FINDING', findings },
                  (response) => {
                    if (chrome.runtime.lastError) {
                      console.error('Failed to send dynamic findings:', chrome.runtime.lastError);
                    }
                  }
                );
              }
            }
          }
        }
      }

      if (hasSecrets) {
        // Re-scan the entire page after dynamic changes
        setTimeout(() => this.scanPage(), 1000);
      }
    });

    this.mutationObserver.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });
  }

  scanElementForSecrets(element) {
    const findings = [];

    if (element.nodeType === Node.TEXT_NODE) {
      const text = element.textContent;
      if (text && text.trim()) {
        const results = this.detector.scanText(text);
        findings.push(...results.map(r => ({
          ...r,
          source: 'dynamic-text'
        })));
      }
    }

    if (element.nodeType === Node.ELEMENT_NODE) {
      // Check text content
      if (element.childNodes) {
        for (const node of element.childNodes) {
          if (node.nodeType === Node.TEXT_NODE) {
            const text = node.textContent;
            if (text && text.trim()) {
              const results = this.detector.scanText(text);
              findings.push(...results.map(r => ({
                ...r,
                source: 'dynamic-text',
                element: this.getElementInfo(element)
              })));
            }
          }
        }
      }

      // Check attributes
      if (element.attributes) {
        for (const attr of element.attributes) {
          const results = this.detector.scanText(attr.value);
          if (results.length > 0) {
            findings.push(...results.map(r => ({
              ...r,
              source: 'dynamic-attribute',
              attributeName: attr.name,
              element: this.getElementInfo(element)
            })));
          }
        }
      }
    }

    return findings;
  }

  stop() {
    if (this.mutationObserver) {
      this.mutationObserver.disconnect();
    }
    this.stopNetworkMonitoring();
  }
}

// Initialize content script
const extractor = new ContentExtractor();

// Listen for messages from service worker
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'START_SCAN') {
    extractor.scanPage().then(() => {
      sendResponse({ status: 'scan_complete' });
    }).catch((error) => {
      sendResponse({ status: 'error', error: error.message });
    });
    return true; // Keep message channel open for async response
  }

  if (message.type === 'START_NETWORK_MONITORING') {
    extractor.startNetworkMonitoring();
    sendResponse({ status: 'network_monitoring_started' });
    return true;
  }

  if (message.type === 'STOP_NETWORK_MONITORING') {
    extractor.stopNetworkMonitoring();
    sendResponse({ status: 'network_monitoring_stopped' });
    return true;
  }

  if (message.type === 'START_MUTATION_OBSERVER') {
    extractor.startMutationObserver();
    sendResponse({ status: 'mutation_observer_started' });
    return true;
  }

  if (message.type === 'STOP_MUTATION_OBSERVER') {
    extractor.stop();
    sendResponse({ status: 'all_monitoring_stopped' });
    return true;
  }

  return false;
});

// Auto-scan on page load
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => {
    setTimeout(() => extractor.scanPage(), 1000);
  });
} else {
  setTimeout(() => extractor.scanPage(), 1000);
}
