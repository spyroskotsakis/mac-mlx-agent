const patterns = [
  { id: 'cloud_provider', name: 'Cloud Provider Keys', severity: 'critical', category: 'Cloud Providers' },
  { id: 'llm_api', name: 'LLM API Keys', severity: 'critical', category: 'LLM APIs' },
  { id: 'git_ci', name: 'Git & CI Tokens', severity: 'high', category: 'Git & CI' },
  { id: 'payment', name: 'Payment Provider Keys', severity: 'critical', category: 'Payments' },
  { id: 'database', name: 'Database Connection Strings', severity: 'high', category: 'Databases' },
  { id: 'private_key', name: 'Private Keys', severity: 'critical', category: 'Private Keys' },
  { id: 'jwt', name: 'JWT Tokens', severity: 'medium', category: 'Authentication' },
  { id: 'generic_secret', name: 'Generic Secrets', severity: 'low', category: 'Generic' }
];

const defaultSettings = {
  enabledPatterns: patterns.map(p => p.id),
  checkSourceMaps: true,
  checkHighEntropy: true,
  entropyThreshold: 4.4,
  minKeyLength: 24
};

let currentSettings = { ...defaultSettings };

function renderPatterns() {
  const patternList = document.getElementById('patternList');
  patternList.innerHTML = '';

  const categories = [...new Set(patterns.map(p => p.category))];

  categories.forEach(category => {
    const categoryGroup = document.createElement('div');
    categoryGroup.className = 'category-group';

    const categoryTitle = document.createElement('div');
    categoryTitle.className = 'category-title';
    categoryTitle.textContent = category;
    categoryGroup.appendChild(categoryTitle);

    const patternsList = document.createElement('div');
    patternsList.className = 'patterns-list';

    patterns
      .filter(p => p.category === category)
      .forEach(pattern => {
        const patternItem = document.createElement('div');
        patternItem.className = 'pattern-item';

        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.id = pattern.id;
        checkbox.checked = currentSettings.enabledPatterns.includes(pattern.id);

        const label = document.createElement('label');
        label.htmlFor = pattern.id;
        label.textContent = pattern.name;

        const severityBadge = document.createElement('span');
        severityBadge.className = `pattern-severity ${pattern.severity}`;
        severityBadge.textContent = pattern.severity;

        patternItem.appendChild(checkbox);
        patternItem.appendChild(label);
        patternItem.appendChild(severityBadge);

        patternsList.appendChild(patternItem);

        checkbox.addEventListener('change', () => {
          if (checkbox.checked) {
            if (!currentSettings.enabledPatterns.includes(pattern.id)) {
              currentSettings.enabledPatterns.push(pattern.id);
            }
          } else {
            currentSettings.enabledPatterns = currentSettings.enabledPatterns.filter(
              id => id !== pattern.id
            );
          }
        });
      });

    categoryGroup.appendChild(patternsList);
    patternList.appendChild(categoryGroup);
  });
}

function loadSettings() {
  chrome.storage.sync.get(defaultSettings, (settings) => {
    currentSettings = { ...defaultSettings, ...settings };

    document.getElementById('checkSourceMaps').checked = currentSettings.checkSourceMaps;
    document.getElementById('checkHighEntropy').checked = currentSettings.checkHighEntropy;
    document.getElementById('entropyThreshold').value = currentSettings.entropyThreshold;
    document.getElementById('minKeyLength').value = currentSettings.minKeyLength;

    renderPatterns();
  });
}

function saveSettings() {
  currentSettings.checkSourceMaps = document.getElementById('checkSourceMaps').checked;
  currentSettings.checkHighEntropy = document.getElementById('checkHighEntropy').checked;
  currentSettings.entropyThreshold = parseFloat(document.getElementById('entropyThreshold').value);
  currentSettings.minKeyLength = parseInt(document.getElementById('minKeyLength').value);

  chrome.storage.sync.set(currentSettings, () => {
    showMessage('Settings saved successfully!', 'success');
  });
}

function resetSettings() {
  currentSettings = { ...defaultSettings };
  document.getElementById('checkSourceMaps').checked = currentSettings.checkSourceMaps;
  document.getElementById('checkHighEntropy').checked = currentSettings.checkHighEntropy;
  document.getElementById('entropyThreshold').value = currentSettings.entropyThreshold;
  document.getElementById('minKeyLength').value = currentSettings.minKeyLength;
  renderPatterns();
  showMessage('Settings reset to defaults', 'success');
}

function showMessage(text, type) {
  const message = document.getElementById('message');
  message.textContent = text;
  message.className = `message ${type} show`;

  setTimeout(() => {
    message.className = 'message';
  }, 3000);
}

document.addEventListener('DOMContentLoaded', () => {
  loadSettings();

  document.getElementById('saveSettings').addEventListener('click', saveSettings);
  document.getElementById('resetSettings').addEventListener('click', resetSettings);

  document.getElementById('entropyThreshold').addEventListener('change', (e) => {
    let value = parseFloat(e.target.value);
    if (value < 4.0) value = 4.0;
    if (value > 5.0) value = 5.0;
    e.target.value = value;
  });

  document.getElementById('minKeyLength').addEventListener('change', (e) => {
    let value = parseInt(e.target.value);
    if (value < 8) value = 8;
    if (value > 128) value = 128;
    e.target.value = value;
  });
});
