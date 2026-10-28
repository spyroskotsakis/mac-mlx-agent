import { KeyDetector } from '../detector/engine.js';

document.addEventListener('DOMContentLoaded', async () => {
  const scanCurrentTab = document.getElementById('scanCurrentTab');
  const scanUrlInput = document.getElementById('scanUrlInput');
  const scanUrlButton = document.getElementById('scanUrlButton');
  const currentUrlElement = document.getElementById('currentUrl');
  const currentUrlContainer = document.getElementById('currentUrlContainer');
  const progressContainer = document.getElementById('progressContainer');
  const progressFill = document.getElementById('progressFill');
  const progressText = document.getElementById('progressText');
  const resultsContainer = document.getElementById('resultsContainer');
  const resultsList = document.getElementById('resultsList');
  const criticalCount = document.getElementById('criticalCount');
  const highCount = document.getElementById('highCount');
  const mediumCount = document.getElementById('mediumCount');
  const errorElement = document.getElementById('error');
  const patternList = document.getElementById('patternList');
  const exportResultsBtn = document.getElementById('exportResults');
  const exportFormat = document.getElementById('exportFormat');

  let currentTabId = null;
  let isScanning = false;
  let detector = null;

  const updateUI = (url) => {
    currentUrlElement.textContent = url;
  };

  const showProgress = (text, percentage = 0) => {
    progressContainer.style.display = 'block';
    progressText.textContent = text;
    progressFill.style.width = `${percentage}%`;

    if (percentage >= 100) {
      setTimeout(hideProgress, 500);
    }
  };

  const hideProgress = () => {
    progressContainer.style.display = 'none';
    progressFill.style.width = '0%';
  };

  const showResults = (results) => {
    resultsContainer.style.display = 'block';
    resultsList.innerHTML = '';

    if (results.length === 0) {
      resultsList.innerHTML = '<div class="no-results">No API keys or secrets detected. Your code is clean! ✓</div>';
      criticalCount.textContent = '0';
      highCount.textContent = '0';
      mediumCount.textContent = '0';
      return;
    }

    results.forEach((finding, index) => {
      const findingDiv = document.createElement('div');
      findingDiv.className = `finding ${finding.severity}`;
      findingDiv.style.opacity = '0';
      findingDiv.style.transform = 'translateX(20px)';
      findingDiv.style.animation = `fadeIn 0.3s ease forwards ${index * 0.1}s`;

      const severityLabels = {
        critical: 'Critical',
        high: 'High',
        medium: 'Medium',
        low: 'Low'
      };

      findingDiv.innerHTML = `
        <div class="finding-header">
          <span class="severity-badge ${finding.severity}">${severityLabels[finding.severity] || finding.severity}</span>
        </div>
        <div class="category">${finding.category}</div>
        <div class="finding-details">
          <p><strong>Pattern:</strong> ${finding.patternId}</p>
          <p><strong>Location:</strong> ${finding.location}</p>
          <p><strong>Context:</strong> "${finding.context.substring(0, 100)}${finding.context.length > 100 ? '...' : ''}"</p>
        </div>
      `;

      resultsList.appendChild(findingDiv);
    });

    const critical = results.filter(r => r.severity === 'critical').length;
    const high = results.filter(r => r.severity === 'high').length;
    const medium = results.filter(r => r.severity === 'medium').length;

    criticalCount.textContent = critical;
    highCount.textContent = high;
    mediumCount.textContent = medium;
  };

  const showError = (message) => {
    errorElement.textContent = message;
    errorElement.style.display = 'block';
    setTimeout(() => {
      errorElement.style.display = 'none';
    }, 5000);
  };

  const clearResults = () => {
    resultsContainer.style.display = 'none';
    resultsList.innerHTML = '';
    errorElement.style.display = 'none';
  };

  const updatePatternList = (patterns) => {
    patternList.innerHTML = '';

    Object.entries(patterns).forEach(([id, pattern]) => {
      const patternItem = document.createElement('div');
      patternItem.className = 'pattern-item';

      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.id = `pattern-${id}`;
      checkbox.value = id;
      checkbox.checked = true;

      const label = document.createElement('label');
      label.htmlFor = `pattern-${id}`;
      label.textContent = pattern.name || id;

      patternItem.appendChild(checkbox);
      patternItem.appendChild(label);
      patternList.appendChild(patternItem);
    });
  };

  const getSelectedPatterns = () => {
    const checkboxes = patternList.querySelectorAll('input[type="checkbox"]:checked');
    return Array.from(checkboxes).map(cb => cb.value);
  };

  const scanPage = async (url = null) => {
    if (isScanning) return;

    isScanning = true;
    scanCurrentTab.disabled = true;
    scanUrlButton.disabled = true;
    scanUrlInput.disabled = true;
    clearResults();
    hideProgress();
    progressContainer.style.display = 'block';

    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

      if (!tab.url) {
        throw new Error('Cannot scan this page type');
      }

      const targetUrl = url || tab.url;
      updateUI(targetUrl);

      const patterns = getSelectedPatterns();
      const options = {
        patterns: patterns.length > 0 ? patterns : undefined,
        includeSourceMap: true,
        includeEntropy: true
      };

      showProgress('Initializing detection engine...', 10);

      const scanResponse = await chrome.runtime.sendMessage({
        type: 'SCAN_PAGE',
        payload: {
          tabId: tab.id,
          url: targetUrl,
          options: options
        }
      });

      if (scanResponse?.error) {
        throw new Error(scanResponse.error);
      }

      const results = scanResponse?.results || [];

      showProgress('Processing results...', 80);

      await new Promise(resolve => setTimeout(resolve, 300));

      showProgress('Complete!', 100);

      await new Promise(resolve => setTimeout(resolve, 400));

      hideProgress();
      showResults(results);

    } catch (error) {
      console.error('Scan error:', error);
      showError(error.message || 'Failed to scan page');
      hideProgress();
    } finally {
      isScanning = false;
      scanCurrentTab.disabled = false;
      scanUrlButton.disabled = false;
      scanUrlInput.disabled = false;
    }
  };

  const exportResultsHandler = (format) => {
    const resultsElement = document.getElementById('resultsList');
    const resultsText = resultsElement.innerText;

    if (!resultsText || resultsText.includes('No API keys')) {
      showError('No results to export');
      return;
    }

    const exportData = {
      timestamp: new Date().toISOString(),
      url: currentUrlElement.textContent,
      results: []
    };

    const findings = resultsElement.querySelectorAll('.finding');
    findings.forEach(finding => {
      const severity = finding.querySelector('.severity-badge')?.textContent?.trim();
      const category = finding.querySelector('.category')?.textContent?.trim();
      const details = finding.querySelector('.finding-details')?.innerText;

      if (severity && category && details) {
        exportData.results.push({ severity, category, details });
      }
    });

    let content, filename, mimeType;

    switch (format) {
      case 'json':
        content = JSON.stringify(exportData, null, 2);
        filename = `keysourcecheck-${Date.now()}.json`;
        mimeType = 'application/json';
        break;

      case 'markdown':
        content = `# Security Scan Report\n\n**URL:** ${exportData.url}\n**Timestamp:** ${exportData.timestamp}\n\n## Findings\n\n${exportData.results.map(r => `- **${r.severity}**: ${r.category}\n  ${r.details}`).join('\n')}\n`;
        filename = `keysourcecheck-${Date.now()}.md`;
        mimeType = 'text/markdown';
        break;

      case 'csv':
        const csvHeader = 'Severity,Category,Details\n';
        const csvRows = exportData.results.map(r => `"${r.severity}","${r.category}","${r.details.replace(/"/g, '""')}"`).join('\n');
        content = csvHeader + csvRows;
        filename = `keysourcecheck-${Date.now()}.csv`;
        mimeType = 'text/csv';
        break;

      default:
        showError('Invalid export format');
        return;
    }

    const blob = new Blob([content], { type: mimeType });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const loadSettings = async () => {
    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

      if (tab?.url) {
        updateUI(tab.url);
      }

      const patternsResponse = await chrome.runtime.sendMessage({
        type: 'GET_PATTERNS'
      });

      if (patternsResponse?.patterns) {
        updatePatternList(patternsResponse.patterns);
      }

      const detectorOptions = await chrome.storage.sync.get({
        includeSourceMap: true,
        includeEntropy: true,
        enabledPatterns: []
      });

      const checkboxes = patternList.querySelectorAll('input[type="checkbox"]');
      checkboxes.forEach(checkbox => {
        if (detectorOptions.enabledPatterns && detectorOptions.enabledPatterns.length > 0) {
          checkbox.checked = detectorOptions.enabledPatterns.includes(checkbox.value);
        }
      });

    } catch (error) {
      console.error('Error loading settings:', error);
    }
  };

  scanCurrentTab.addEventListener('click', () => {
    scanPage();
  });

  scanUrlButton.addEventListener('click', () => {
    const url = scanUrlInput.value.trim();
    if (url) {
      scanPage(url);
    } else {
      showError('Please enter a URL');
    }
  });

  scanUrlInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') {
      const url = scanUrlInput.value.trim();
      if (url) {
        scanPage(url);
      }
    }
  });

  scanUrlInput.addEventListener('input', () => {
    if (scanUrlInput.value.trim()) {
      currentUrlContainer.style.display = 'none';
    }
  });

  patternList.addEventListener('change', async (e) => {
    if (e.target.tagName === 'INPUT' && e.target.type === 'checkbox') {
      const checkboxes = patternList.querySelectorAll('input[type="checkbox"]');
      const enabledPatterns = Array.from(checkboxes).filter(cb => cb.checked).map(cb => cb.value);

      try {
        await chrome.storage.sync.set({
          enabledPatterns: enabledPatterns
        });
      } catch (error) {
        console.error('Error saving settings:', error);
      }
    }
  });

  exportResultsBtn.addEventListener('click', () => {
    const format = exportFormat.value;
    exportResultsHandler(format);
  });

  const addStyles = () => {
    const style = document.createElement('style');
    style.textContent = `
      @keyframes fadeIn {
        from {
          opacity: 0;
          transform: translateX(20px);
        }
        to {
          opacity: 1;
          transform: translateX(0);
        }
      }
    `;
    document.head.appendChild(style);
  };

  addStyles();

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'UPDATE_PROGRESS') {
      const { text, percentage } = message.payload;
      showProgress(text, percentage);
    }

    if (message.type === 'HIDE_PROGRESS') {
      hideProgress();
    }

    return true;
  });
});
