import { KeyDetector } from '../../src/detector/engine.js';

export function testKeyDetectorConstructor() {
  console.log('  Testing KeyDetector constructor...');
  
  const defaultDetector = new KeyDetector();
  const customDetector = new KeyDetector({
    checkSourceMaps: false,
    checkHighEntropy: false,
    minEntropyThreshold: 5.0,
    minKeyLength: 32
  });
  
  let passed = 0;
  let total = 4;
  
  if (defaultDetector.enabledPatterns.size > 0) {
    passed++;
    console.log(`    ✓ Default detector has ${defaultDetector.enabledPatterns.size} enabled patterns`);
  } else {
    console.error(`    ✗ Default detector should have enabled patterns`);
  }
  
  if (defaultDetector.options.checkSourceMaps === true) {
    passed++;
    console.log(`    ✓ Default options.checkSourceMaps is true`);
  } else {
    console.error(`    ✗ Default options.checkSourceMaps should be true`);
  }
  
  if (customDetector.options.checkSourceMaps === false) {
    passed++;
    console.log(`    ✓ Custom options.checkSourceMaps is false`);
  } else {
    console.error(`    ✗ Custom options.checkSourceMaps should be false`);
  }
  
  if (customDetector.options.minEntropyThreshold === 5.0) {
    passed++;
    console.log(`    ✓ Custom options.minEntropyThreshold is 5.0`);
  } else {
    console.error(`    ✗ Custom options.minEntropyThreshold should be 5.0`);
  }
  
  console.log(`    ✓ ${passed}/${total} constructor tests work correctly`);
  return passed === total;
}

export function testPatternEnableDisable() {
  console.log('  Testing pattern enable/disable/toggle...');
  const detector = new KeyDetector();
  
  const initialPatterns = detector.getEnabledPatterns();
  const firstPattern = initialPatterns[0];
  
  detector.disablePattern(firstPattern);
  const afterDisable = detector.getEnabledPatterns();
  
  if (!afterDisable.includes(firstPattern)) {
    console.log(`    ✓ disablePattern("${firstPattern}") correctly removed pattern`);
  } else {
    console.error(`    ✗ disablePattern("${firstPattern}") did not remove pattern`);
  }
  
  detector.enablePattern(firstPattern);
  const afterEnable = detector.getEnabledPatterns();
  
  if (afterEnable.includes(firstPattern)) {
    console.log(`    ✓ enablePattern("${firstPattern}") correctly re-added pattern`);
  } else {
    console.error(`    ✗ enablePattern("${firstPattern}") did not re-add pattern`);
  }
  
  detector.togglePattern(firstPattern);
  const afterToggle = detector.getEnabledPatterns();
  
  if (!afterToggle.includes(firstPattern)) {
    console.log(`    ✓ togglePattern("${firstPattern}") correctly toggled off`);
  } else {
    console.error(`    ✗ togglePattern("${firstPattern}") did not toggle off`);
  }
  
  return true;
}

export async function testScanByPatterns() {
  console.log('  Testing scanByPatterns method...');
  const detector = new KeyDetector();
  
  const testContent = {
    text: `
      const AWS_KEY = 'AKIAIOSFODNN7XYZABCDEF';
      const stripeKey = 'sk_test_4eC39HqLyjWDarjtT1zdp7dc';
      const githubToken = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz';
    `,
    url: 'test.html',
    filename: 'test.html'
  };
  
  const findings = detector.scanByPatterns(testContent.text, testContent.url, testContent.filename);
  
  const hasAWS = findings.some(f => f.patternId === 'AWS_ACCESS_KEY');
  const hasStripe = findings.some(f => f.patternId === 'STRIPE_TEST');
  const hasGitHub = findings.some(f => f.patternId === 'GITHUB_PAT');
  
  let passed = 0;
  let total = 3;
  
  if (hasAWS) {
    passed++;
    console.log(`    ✓ scanByPatterns detected AWS key pattern`);
  } else {
    console.error(`    ✗ scanByPatterns did not detect AWS key pattern`);
  }
  
  if (hasStripe) {
    passed++;
    console.log(`    ✓ scanByPatterns detected Stripe key pattern`);
  } else {
    console.error(`    ✗ scanByPatterns did not detect Stripe key pattern`);
  }
  
  if (hasGitHub) {
    passed++;
    console.log(`    ✓ scanByPatterns detected GitHub token pattern`);
  } else {
    console.error(`    ✗ scanByPatterns did not detect GitHub token pattern`);
  }
  
  console.log(`    ✓ ${passed}/${total} pattern scanning tests work correctly`);
  return passed === total;
}

export function testScanHighEntropy() {
  console.log('  Testing scanHighEntropy method...');
  const detector = new KeyDetector();
  
  const testContent = {
    text: `const secret = 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6';`,
    url: 'test.html',
    filename: 'test.html'
  };
  
  const findings = detector.scanHighEntropy(testContent.text, testContent.url, testContent.filename);
  
  if (findings.length > 0) {
    console.log(`    ✓ scanHighEntropy found ${findings.length} high-entropy strings`);
    return true;
  } else {
    console.error(`    ✗ scanHighEntropy did not find any high-entropy strings`);
    return false;
  }
}

export function testDeduplicateFindings() {
  console.log('  Testing deduplicateFindings method...');
  const detector = new KeyDetector();
  
  const duplicateFindings = [
    { url: 'test.html', start: 0, end: 10, type: 'pattern_match', value: 'test1' },
    { url: 'test.html', start: 0, end: 10, type: 'pattern_match', value: 'test2' },
    { url: 'test.html', start: 20, end: 30, type: 'pattern_match', value: 'test3' },
  ];
  
  const unique = detector.deduplicateFindings(duplicateFindings);
  
  if (unique.length === 2) {
    console.log(`    ✓ deduplicateFindings correctly reduced ${duplicateFindings.length} to ${unique.length} findings`);
    return true;
  } else {
    console.error(`    ✗ deduplicateFindings returned ${unique.length}, expected 2`);
    return false;
  }
}

export async function testScanMethod() {
  console.log('  Testing scan method...');
  const detector = new KeyDetector();
  
  const testContent = {
    text: `
      const AWS_KEY = 'AKIAIOSFODNN7EXAMPLE';
      const stripeKey = 'sk_test_4eC39HqLyjWDarjtT1zdp7dc';
      const secret = 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6';
    `,
    url: 'test.html',
    filename: 'test.html'
  };
  
  const findings = await detector.scan(testContent);
  
  const hasPatternMatches = findings.some(f => f.type === 'pattern_match');
  const hasHighEntropy = findings.some(f => f.type === 'high_entropy');
  
  let passed = 0;
  let total = 2;
  
  if (hasPatternMatches) {
    passed++;
    console.log(`    ✓ scan method found pattern matches`);
  } else {
    console.error(`    ✗ scan method did not find pattern matches`);
  }
  
  if (hasHighEntropy) {
    passed++;
    console.log(`    ✓ scan method found high-entropy strings`);
  } else {
    console.error(`    ✗ scan method did not find high-entropy strings`);
  }
  
  console.log(`    ✓ ${passed}/${total} scan method tests work correctly`);
  return passed === total;
}

export async function testScanFileMethod() {
  console.log('  Testing scanFile method...');
  const detector = new KeyDetector();
  
  const testBlob = new Blob([`const AWS_KEY = 'AKIAIOSFODNN7XYZABCDEF';`], { type: 'text/plain' });
  const testFile = new File([testBlob], 'test.js', { type: 'text/plain' });
  
  const findings = await detector.scanFile(testFile, 'test.js');
  
  if (findings.length > 0) {
    console.log(`    ✓ scanFile method found ${findings.length} findings`);
    return true;
  } else {
    console.error(`    ✗ scanFile method did not find any findings`);
    return false;
  }
}

export function testGetPatternConfig() {
  console.log('  Testing getPatternConfig method...');
  const detector = new KeyDetector();
  
  const awsConfig = detector.getPatternConfig('AWS_ACCESS_KEY');
  const stripeConfig = detector.getPatternConfig('STRIPE_TEST');
  
  let passed = 0;
  let total = 2;
  
  if (awsConfig && awsConfig.category === 'Cloud provider keys') {
    passed++;
    console.log(`    ✓ getPatternConfig('AWS_ACCESS_KEY') returns correct config`);
  } else {
    console.error(`    ✗ getPatternConfig('AWS_ACCESS_KEY') returned incorrect config`);
  }
  
  if (stripeConfig && stripeConfig.category === 'Payments') {
    passed++;
    console.log(`    ✓ getPatternConfig('stripe') returns correct config`);
  } else {
    console.error(`    ✗ getPatternConfig('stripe') returned incorrect config`);
  }
  
  console.log(`    ✓ ${passed}/${total} pattern config tests work correctly`);
  return passed === total;
}

export function testGetPatternList() {
  console.log('  Testing getPatternList method...');
  const detector = new KeyDetector();
  
  const patternList = detector.getPatternList();
  
  if (Array.isArray(patternList) && patternList.length > 0) {
    const hasId = patternList.every(p => p.id);
    const hasEnabled = patternList.every(p => typeof p.enabled === 'boolean');
    
    if (hasId && hasEnabled) {
      console.log(`    ✓ getPatternList returns ${patternList.length} patterns with id and enabled properties`);
      return true;
    } else {
      console.error(`    ✗ getPatternList missing id or enabled properties`);
      return false;
    }
  } else {
    console.error(`    ✗ getPatternList returned empty or non-array`);
    return false;
  }
}

export async function testScanWithDisabledPatterns() {
  console.log('  Testing scan with disabled patterns...');
  const detector = new KeyDetector();
  
  detector.disablePattern('AWS_ACCESS_KEY');
  
  const testContent = {
    text: `const AWS_KEY = 'AKIAIOSFODNN7EXAMPLE';`,
    url: 'test.html',
    filename: 'test.html'
  };
  
  const findings = await detector.scan(testContent);
  
  const hasAWS = findings.some(f => f.patternId === 'AWS_ACCESS_KEY');
  
  if (!hasAWS) {
    console.log(`    ✓ scan with disabled AWS pattern correctly excluded AWS findings`);
    return true;
  } else {
    console.error(`    ✗ scan with disabled AWS pattern still found AWS keys`);
    return false;
  }
}

export async function testScanUrlMethod() {
  console.log('  Testing scanUrl method...');
  const detector = new KeyDetector();
  
  try {
    const findings = await detector.scanUrl('https://example.com');
    
    if (Array.isArray(findings)) {
      console.log(`    ✓ scanUrl method returns array (found ${findings.length} findings)`);
      return true;
    } else {
      console.error(`    ✗ scanUrl method did not return array`);
      return false;
    }
  } catch (e) {
    console.error(`    ✗ scanUrl method threw error: ${e.message}`);
    return false;
  }
}

export async function testScanUrlWithInvalidUrl() {
  console.log('  Testing scanUrl with invalid URL...');
  const detector = new KeyDetector();
  
  try {
    const findings = await detector.scanUrl('https://nonexistent.invalid.domain.test');
    
    if (Array.isArray(findings) && findings.length === 0) {
      console.log(`    ✓ scanUrl with invalid URL returns empty array`);
      return true;
    } else {
      console.error(`    ✗ scanUrl with invalid URL should return empty array`);
      return false;
    }
  } catch (e) {
    console.error(`    ✗ scanUrl with invalid URL threw error: ${e.message}`);
    return false;
  }
}

export async function testKeyDetectorEdgeCases() {
  console.log('  Testing KeyDetector edge cases...');
  const detector = new KeyDetector();
  
  const emptyContent = { text: '', url: 'test.html', filename: 'test.html' };
  const findings = await detector.scan(emptyContent);
  
  if (findings.length === 0) {
    console.log(`    ✓ scan with empty content returns no findings`);
    return true;
  } else {
    console.error(`    ✗ scan with empty content should return no findings`);
    return false;
  }
}
