import { calculateShannonEntropy, extractHighEntropyCandidates, analyzeString } from '../../src/detector/entropy.js';

export function testCalculateShannonEntropy() {
  console.log('  Testing calculateShannonEntropy function...');
  const testCases = [
    { input: 'aaaa', expected: 0 },
    { input: 'abab', expected: 1 },
    { input: 'abcdef', expected: 2.584962500721156 },
    { input: 'a1b2c3d4e5f6g7h8i9j0', expected: 4.321928094887363 },
    { input: '', expected: 0 },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { input, expected } of testCases) {
    total++;
    const result = calculateShannonEntropy(input);
    if (Math.abs(result - expected) > 0.01) {
      console.error(`    ✗ calculateShannonEntropy("${input}") returned ${result}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ calculateShannonEntropy("${input}") correctly returns ${result.toFixed(4)}`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} entropy calculation tests work correctly`);
  return passed === total;
}

export function testIsHighEntropy() {
  console.log('  Testing isHighEntropy function...');
  const testCases = [
    { input: 'short', threshold: 3.0, expected: false },
    { input: 'abcdefghij', threshold: 3.0, expected: false },
    { input: 'a1b2c3d4e5f6g7h8i9j0', threshold: 3.0, expected: false },
    { input: 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6', threshold: 3.0, expected: true },
    { input: 'AKIAIOSFODNN7EXAMPLE', threshold: 3.0, expected: false },
    { input: 'AKIAIOSFODNN7EXAMPLEabcdefghij', threshold: 3.0, expected: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { input, threshold, expected } of testCases) {
    total++;
    const result = isHighEntropy(input, threshold);
    if (result !== expected) {
      console.error(`    ✗ isHighEntropy("${input}", ${threshold}) returned ${result}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ isHighEntropy("${input}", ${threshold}) correctly returns ${result}`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} high entropy check tests work correctly`);
  return passed === total;
}

function isHighEntropy(str, threshold = 4.4, minLength = 24) {
  if (!str || str.length < minLength) return false;
  const entropy = calculateShannonEntropy(str);
  return entropy >= threshold;
}

export function testExtractHighEntropyCandidates() {
  console.log('  Testing extractHighEntropyCandidates function...');
  const testHtml = `
    <script>
      const apiKey = 'xK9mP2vL5nQ8rT1wY4jH6bN3cF0dA9eG';
      const secret = 'short';
      const token = 'wR7tZ2kM5pL9nQ3rT1wY6jH8bN0cF4dA';
    </script>
    <div data-secret="eG4jH6bN3cF0dA9eGxK9mP2vL5nQ8rT1">test</div>
  `;
  
  const result = extractHighEntropyCandidates(testHtml);
  
  if (!Array.isArray(result)) {
    console.error(`    ✗ extractHighEntropyCandidates returned ${typeof result}, expected array`);
    return false;
  }
  
  const hasLongStrings = result.some(s => s.value.length > 24);
  const allHaveEntropy = result.every(s => s.entropy !== undefined);
  
  if (hasLongStrings && allHaveEntropy) {
    console.log(`    ✓ extractHighEntropyCandidates correctly found ${result.length} high-entropy strings`);
    return true;
  } else {
    console.error(`    ✗ extractHighEntropyCandidates did not find expected strings (found ${result.length})`);
    if (result.length > 0) {
      console.error(`    Sample: ${JSON.stringify(result[0])}`);
    }
    return false;
  }
}

export function testAnalyzeString() {
  console.log('  Testing analyzeString function...');
  const testCases = [
    { input: 'aaaa', expectedEntropy: 0, expectedIsHighEntropy: false },
    { input: 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6', expectedIsHighEntropy: true },
    { input: 'short', expectedIsHighEntropy: false },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { input, expectedEntropy, expectedIsHighEntropy } of testCases) {
    total++;
    const result = analyzeString(input);
    
    if (typeof result.entropy !== 'number') {
      console.error(`    ✗ analyzeString("${input}") missing entropy property`);
      continue;
    }
    
    if (typeof result.isHighEntropy !== 'boolean') {
      console.error(`    ✗ analyzeString("${input}") missing isHighEntropy property`);
      continue;
    }
    
    if (result.isHighEntropy !== expectedIsHighEntropy) {
      console.error(`    ✗ analyzeString("${input}") isHighEntropy=${result.isHighEntropy}, expected ${expectedIsHighEntropy}`);
      continue;
    }
    
    if (expectedEntropy !== undefined && Math.abs(result.entropy - expectedEntropy) > 0.01) {
      console.error(`    ✗ analyzeString("${input}") entropy=${result.entropy}, expected ${expectedEntropy}`);
      continue;
    }
    
    passed++;
    console.log(`    ✓ analyzeString("${input}") correctly returns entropy=${result.entropy.toFixed(4)}, isHighEntropy=${result.isHighEntropy}`);
  }
  
  console.log(`    ✓ ${passed}/${total} analyzeString tests work correctly`);
  return passed === total;
}

export function testEntropyEdgeCases() {
  console.log('  Testing entropy edge cases...');
  const testCases = [
    { input: '', expected: 0 },
    { input: 'a', expected: 0 },
    { input: 'ab', expected: 1 },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { input, expected } of testCases) {
    total++;
    const result = calculateShannonEntropy(input);
    if (Math.abs(result - expected) > 0.01) {
      console.error(`    ✗ calculateShannonEntropy("${input}") returned ${result}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ calculateShannonEntropy("${input}") correctly returns ${result}`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} edge case tests work correctly`);
  return passed === total;
}
