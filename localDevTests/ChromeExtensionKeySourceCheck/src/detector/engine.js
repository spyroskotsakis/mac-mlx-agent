import { PATTERNS, isPlaceholder, redactValue, getSeverityLevel, getSeverityColor } from './patterns.js';
import { calculateShannonEntropy, extractHighEntropyCandidates } from './entropy.js';
import { parseSourceMap, getSourceMapFromContent } from './sourcemap.js';

export class KeyDetector {
  constructor(options = {}) {
    this.enabledPatterns = new Set(
      Object.entries(PATTERNS)
        .filter(([_, config]) => config.defaultEnabled)
        .map(([key]) => key)
    );
    this.options = {
      checkSourceMaps: options.checkSourceMaps ?? true,
      checkHighEntropy: options.checkHighEntropy ?? true,
      minEntropyThreshold: options.minEntropyThreshold ?? 4.4,
      minKeyLength: options.minKeyLength ?? 24,
      ...options
    };
  }

  enablePattern(patternId) {
    this.enabledPatterns.add(patternId);
  }

  disablePattern(patternId) {
    this.enabledPatterns.delete(patternId);
  }

  togglePattern(patternId) {
    if (this.enabledPatterns.has(patternId)) {
      this.disablePattern(patternId);
    } else {
      this.enablePattern(patternId);
    }
  }

  getEnabledPatterns() {
    return Array.from(this.enabledPatterns);
  }

  getPatterns() {
    return PATTERNS;
  }

  async scan(content, options = {}) {
    const findings = [];
    const text = typeof content === 'string' ? content : content.text;
    const url = content.url || 'unknown';
    const filename = content.filename || 'source';

    // Pattern-based detection
    findings.push(...this.scanByPatterns(text, url, filename));

    // High entropy detection
    if (this.options.checkHighEntropy) {
      findings.push(...this.scanHighEntropy(text, url, filename));
    }

    // Source map detection
    if (this.options.checkSourceMaps) {
      const sourceMapInfo = getSourceMapFromContent(text);
      if (sourceMapInfo.hasInlineMap || sourceMapInfo.externalUrls.length > 0) {
        findings.push({
          type: 'source_map',
          category: 'Source maps detected',
          severity: 'MEDIUM',
          url,
          filename,
          message: 'Source maps found - may contain exposed secrets',
          details: sourceMapInfo
        });
      }
    }

    return this.deduplicateFindings(findings);
  }

  scanText(text) {
    const findings = [];
    const url = 'content-script';
    const filename = 'inline';

    for (const [patternId, config] of Object.entries(PATTERNS)) {
      if (!this.enabledPatterns.has(patternId)) continue;

      const regex = new RegExp(config.regex.source, 'g');
      let match;

      while ((match = regex.exec(text)) !== null) {
        const value = match[0];

        if (isPlaceholder(value)) continue;

        const entropy = calculateShannonEntropy(value);
        const isHighEntropy = entropy >= 4.4 && value.length >= 24;

        findings.push({
          type: 'pattern_match',
          patternId,
          category: config.category,
          severity: config.severity,
          url,
          filename,
          matchIndex: match.index,
          matchedValue: value,
          value: redactValue(value),
          entropy,
          isHighEntropy,
          match: value,
          regex: config.regex.source
        });
      }
    }

    if (this.options.checkHighEntropy) {
      const candidates = extractHighEntropyCandidates(text);

      for (const candidate of candidates) {
        const isKnownPattern = Object.entries(PATTERNS).some(([_, config]) => {
          try {
            const regex = new RegExp(config.regex.source, 'g');
            return regex.test(candidate.value);
          } catch {
            return false;
          }
        });

        if (isKnownPattern) continue;

        findings.push({
          type: 'high_entropy',
          category: 'High entropy string',
          severity: 'MEDIUM',
          url,
          filename,
          matchIndex: candidate.start,
          matchedValue: candidate.value,
          value: redactValue(candidate.value),
          entropy: calculateShannonEntropy(candidate.value),
          length: candidate.value.length,
          patternType: candidate.type
        });
      }
    }

    return this.deduplicateFindings(findings);
  }

  scanByPatterns(text, url, filename) {
    const findings = [];

    for (const [patternId, config] of Object.entries(PATTERNS)) {
      if (!this.enabledPatterns.has(patternId)) continue;

      const regex = new RegExp(config.regex.source, 'g');
      let match;

      while ((match = regex.exec(text)) !== null) {
        const value = match[0];
        const start = match.index;
        const end = start + value.length;

        // Skip placeholders
        if (isPlaceholder(value)) continue;

        // Calculate entropy for the matched value
        const entropy = calculateShannonEntropy(value);
        const isHighEntropy = entropy >= 4.4 && value.length >= 24;

        findings.push({
          type: 'pattern_match',
          patternId,
          category: config.category,
          severity: config.severity,
          url,
          filename,
          start,
          end,
          value: redactValue(value),
          originalValue: value,
          entropy,
          isHighEntropy,
          match: value,
          regex: config.regex.source
        });
      }
    }

    return findings;
  }

  scanHighEntropy(text, url, filename) {
    const findings = [];
    const candidates = extractHighEntropyCandidates(text);

    for (const candidate of candidates) {
      // Skip if it matches known patterns
      const isKnownPattern = Object.entries(PATTERNS).some(([_, config]) => {
        try {
          const regex = new RegExp(config.regex.source, 'g');
          return regex.test(candidate.value);
        } catch {
          return false;
        }
      });

      if (isKnownPattern) continue;

      findings.push({
        type: 'high_entropy',
        category: 'High entropy string',
        severity: 'MEDIUM',
        url,
        filename,
        start: candidate.start,
        end: candidate.end,
        value: redactValue(candidate.value),
        originalValue: candidate.value,
        entropy: calculateShannonEntropy(candidate.value),
        length: candidate.value.length,
        patternType: candidate.type
      });
    }

    return findings;
  }

  deduplicateFindings(findings) {
    const seen = new Set();
    const unique = [];

    for (const finding of findings) {
      const key = `${finding.url}:${finding.start}:${finding.end}:${finding.type}`;
      if (!seen.has(key)) {
        seen.add(key);
        unique.push(finding);
      }
    }

    return unique.sort((a, b) => {
      const severityOrder = { CRITICAL: 4, HIGH: 3, MEDIUM: 2, LOW: 1, INFO: 0 };
      return severityOrder[b.severity] - severityOrder[a.severity];
    });
  }

  getPatternConfig(patternId) {
    return PATTERNS[patternId];
  }

  getPatternList() {
    return Object.entries(PATTERNS).map(([id, config]) => ({
      id,
      ...config,
      enabled: this.enabledPatterns.has(id)
    }));
  }

  async scanFile(file, url = 'file') {
    const text = await file.text();
    return this.scan({ text, url, filename: file.name || 'file' });
  }

  async scanUrl(url, options = {}) {
    try {
      const response = await fetch(url, {
        headers: {
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.5'
        }
      });

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }

      const text = await response.text();
      return this.scan({ text, url, filename: new URL(url).pathname });
    } catch (error) {
      console.error('Failed to scan URL:', error);
      return [];
    }
  }
}

export default KeyDetector;
