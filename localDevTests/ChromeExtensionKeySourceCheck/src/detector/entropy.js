export function calculateShannonEntropy(str) {
  if (!str || str.length === 0) return 0;

  const freq = {};
  for (const char of str) {
    freq[char] = (freq[char] || 0) + 1;
  }

  let entropy = 0;
  const len = str.length;
  for (const char in freq) {
    const p = freq[char] / len;
    entropy -= p * Math.log2(p);
  }

  return entropy;
}

export function isHighEntropy(str, threshold = 4.4, minLength = 24) {
  if (!str || str.length < minLength) return false;
  const entropy = calculateShannonEntropy(str);
  return entropy >= threshold;
}

export function extractHighEntropyCandidates(text) {
  const candidates = [];
  
  // Match base64-like strings (A-Za-z0-9+/=)
  const base64Regex = /[A-Za-z0-9+\/=]{24,}/g;
  // Match hex-like strings (0-9A-Fa-f)
  const hexRegex = /[0-9A-Fa-f]{32,}/g;
  // Match alphanumeric strings
  const alphaNumRegex = /[A-Za-z0-9]{24,}/g;

  const patterns = [base64Regex, hexRegex, alphaNumRegex];
  
  for (const pattern of patterns) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      const value = match[0];
      const entropy = calculateShannonEntropy(value);
      if (isHighEntropy(value)) {
        candidates.push({
          value,
          start: match.index,
          end: match.index + value.length,
          type: getPatternType(value),
          entropy
        });
      }
    }
  }

  return candidates;
}

function getPatternType(str) {
  if (/^[A-Za-z0-9+\/=]+$/.test(str)) return 'base64';
  if (/^[0-9A-Fa-f]+$/.test(str)) return 'hex';
  if (/^[A-Za-z0-9]+$/.test(str)) return 'alphanumeric';
  return 'unknown';
}

export function analyzeString(str) {
  const entropy = calculateShannonEntropy(str);
  const isHighEntropy = entropy >= 4.4 && str.length >= 24;
  
  return {
    entropy,
    length: str.length,
    isHighEntropy,
    characterCount: str.length,
    uniqueCharacters: new Set(str).size
  };
}
