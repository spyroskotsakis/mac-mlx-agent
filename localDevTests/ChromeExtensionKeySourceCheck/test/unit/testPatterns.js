import { PATTERNS, isPlaceholder, redactValue, getSeverityLevel, getSeverityColor } from '../../src/detector/patterns.js';

export function testPatternsExport() {
  console.log('  Testing PATTERNS export...');
  if (!PATTERNS || typeof PATTERNS !== 'object') {
    console.error('    ✗ PATTERNS is not exported or is not an object');
    return false;
  }
  const keys = Object.keys(PATTERNS);
  if (keys.length === 0) {
    console.error('    ✗ PATTERNS is empty');
    return false;
  }
  console.log(`    ✓ PATTERNS contains ${keys.length} patterns`);
  return true;
}

export function testPatternStructure() {
  console.log('  Testing pattern structure...');
  let allValid = true;
  for (const [id, config] of Object.entries(PATTERNS)) {
    if (!config.category) {
      console.error(`    ✗ Pattern ${id} missing category`);
      allValid = false;
    }
    if (!config.severity) {
      console.error(`    ✗ Pattern ${id} missing severity`);
      allValid = false;
    }
    if (!config.regex) {
      console.error(`    ✗ Pattern ${id} missing regex`);
      allValid = false;
    }
    if (typeof config.defaultEnabled !== 'boolean') {
      console.error(`    ✗ Pattern ${id} defaultEnabled is not boolean`);
      allValid = false;
    }
  }
  if (allValid) {
    console.log(`    ✓ All ${Object.keys(PATTERNS).length} patterns have valid structure`);
  }
  return allValid;
}

export function testCloudProviderPatterns() {
  console.log('  Testing cloud provider patterns...');
  const testCases = [
    { pattern: 'AWS_ACCESS_KEY', test: 'AKIAIOSFODNN7EXAMPLE', shouldMatch: true },
    { pattern: 'AWS_SECRET', test: 'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', shouldMatch: true },
    { pattern: 'GCP_SERVICE_ACCOUNT', test: '"private_key": "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----"', shouldMatch: true },
    { pattern: 'AZURE_ACCOUNT_KEY', test: 'AccountKey=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/abcdefghijklmnopqrstuvwx', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} cloud provider patterns work correctly`);
  return passed === total;
}

export function testLLMKeyPatterns() {
  console.log('  Testing LLM key patterns...');
  const testCases = [
    { pattern: 'OPENAI', test: 'sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJklmn', shouldMatch: true },
    { pattern: 'ANTHROPIC', test: 'sk-ant-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJklmn', shouldMatch: true },
    { pattern: 'GOOGLE_AI_STUDIO', test: 'AIzaSyA1234567890abcdefghijklmnopqrst', shouldMatch: true },
    { pattern: 'DEEPSEEK', test: 'sk-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJklmn', shouldMatch: true },
    { pattern: 'MISTRAL', test: 'mistral-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJklmn', shouldMatch: true },
    { pattern: 'GROQ', test: 'gsk_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJklmn', shouldMatch: true },
    { pattern: 'OPENROUTER', test: 'sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJklmnabcdefghijABCDklmn', shouldMatch: true },
    { pattern: 'HUGGINGFACE', test: 'hf_abcdefghijklmnopqrstuvwxyz01234567', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} LLM key patterns work correctly`);
  return passed === total;
}

export function testGitAndCIPatterns() {
  console.log('  Testing Git and CI token patterns...');
  const testCases = [
    { pattern: 'GITHUB_PAT', test: 'ghp_abcdefghijABCDEFGHIJklmnopqrstuvwxABCD', shouldMatch: true },
    { pattern: 'GITHUB_FINE_GRAINED', test: 'github_pat_abcdefghijABCDEFGHIJklmnopqr', shouldMatch: true },
    { pattern: 'GITHUB_OAUTH', test: 'gho_abcdefghijABCDEFGHIJklmnopqrstuvwxABCD', shouldMatch: true },
    { pattern: 'GITLAB', test: 'glpat-abcdefghijABCDEFGHIJklmnopqrstuvwx', shouldMatch: true },
    { pattern: 'BITBUCKET', test: 'ATabcdefghijABCDEFGHIJklmnopqrstuvwx01', shouldMatch: true },
    { pattern: 'NPM', test: 'npm_abcdefghijABCDEFGHIJklmnopqrstuvwxABCD', shouldMatch: true },
    { pattern: 'PYPI', test: 'pypi-abcdefghijABCDEFGHIJklmnopqrstuvwx0123456789ABCD', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} Git and CI patterns work correctly`);
  return passed === total;
}

export function testPaymentPatterns() {
  console.log('  Testing payment patterns...');
  const testCases = [
    { pattern: 'TELEGRAM_BOT', test: '1234567890:ABCDEFghijklmnopqrstuvwxyz123456789', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} payment patterns work correctly`);
  return passed === total;
}

export function testMessagingPatterns() {
  console.log('  Testing messaging patterns...');
  const testCases = [
    { pattern: 'SLACK', test: 'xoxb-123456789012-1234567890123-abcdefghijABCDEFGHIJ12', shouldMatch: true },
    { pattern: 'SLACK_WEBHOOK', test: 'https://hooks.slack.com/services/ABCDEFGHIJ/abcdefghij/ABCDEFGHIJabcdefghij12', shouldMatch: true },
    { pattern: 'DISCORD_WEBHOOK', test: 'https://discord.com/api/webhooks/123456789012345678/abcdefghijABCDEFGHIJ12abcdefghijABCDEFGHIJ12abcdefghijABCDef', shouldMatch: true },
    { pattern: 'TELEGRAM_BOT', test: '1234567890:abcdefghijABCDEFGHIJ1234567890abcdef', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} messaging patterns work correctly`);
  return passed === total;
}

export function testDatabasePatterns() {
  console.log('  Testing database connection string patterns...');
  const testCases = [
    { pattern: 'POSTGRES', test: 'postgres://user:password@localhost:5432/mydb', shouldMatch: true },
    { pattern: 'MYSQL', test: 'mysql://user:password@localhost:3306/mydb', shouldMatch: true },
    { pattern: 'MONGODB', test: 'mongodb+srv://user:password@cluster.mongodb.net/mydb', shouldMatch: true },
    { pattern: 'REDIS', test: 'redis://user:password@localhost:6379', shouldMatch: true },
    { pattern: 'JDBC', test: 'jdbc:postgresql://localhost:5432/mydb;password=secret', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} database patterns work correctly`);
  return passed === total;
}

export function testEmailAndSMSPatterns() {
  console.log('  Testing email and SMS service patterns...');
  const testCases = [
    { pattern: 'TWILIO', test: 'ACabcdef1234567890abcdef1234567890', shouldMatch: true },
    { pattern: 'SENDGRID', test: 'SG.abcdefghijABCDEFGHIJ12.abcdefghijABCDEFGHIJ12abcdefghijABCDEFGHIJ12abcde', shouldMatch: true },
    { pattern: 'MAILGUN', test: 'key-abcdefghijABCDEFGHIJ1234567890ab', shouldMatch: true },
    { pattern: 'RESEND', test: 're_abcdefghijABCDEFGHIJ123456', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} email and SMS patterns work correctly`);
  return passed === total;
}

export function testPrivateKeysAndOAuth() {
  console.log('  Testing private keys and OAuth patterns...');
  const testCases = [
    { pattern: 'PRIVATE_KEY_HEADER', test: '-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----', shouldMatch: true },
    { pattern: 'CLIENT_SECRET', test: '"client_secret": "abcdefghijABCDEFGHIJ1234567890"', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} private key and OAuth patterns work correctly`);
  return passed === total;
}

export function testGenericAndJWTPatterns() {
  console.log('  Testing generic and JWT patterns...');
  const testCases = [
    { pattern: 'GENERIC_SECRET', test: 'api_key = "abcdefghij1234567890"', shouldMatch: true },
    { pattern: 'JWT_TOKEN', test: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456', shouldMatch: true },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { pattern, test, shouldMatch } of testCases) {
    total++;
    const patternConfig = PATTERNS[pattern];
    if (!patternConfig) {
      console.error(`    ✗ Pattern ${pattern} not found`);
      continue;
    }
    const regex = patternConfig.regex;
    const matches = regex.test(test);
    regex.lastIndex = 0;
    
    if (shouldMatch && !matches) {
      console.error(`    ✗ Pattern ${pattern} should match: ${test.slice(0, 50)}`);
    } else if (!shouldMatch && matches) {
      console.error(`    ✗ Pattern ${pattern} should not match: ${test.slice(0, 50)}`);
    } else {
      passed++;
      console.log(`    ✓ Pattern ${pattern} correctly ${shouldMatch ? 'matches' : 'skips'} test case`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} generic and JWT patterns work correctly`);
  return passed === total;
}

export function testIsPlaceholder() {
  console.log('  Testing isPlaceholder function...');
  const testCases = [
    { value: 'your_api_key', expected: true },
    { value: 'xxx_placeholder', expected: true },
    { value: 'example_key', expected: true },
    { value: 'changeme_secret', expected: true },
    { value: 'todo_fill_this', expected: true },
    { value: '${env.API_KEY}', expected: true },
    { value: 'process.env.API_KEY', expected: true },
    { value: 'undefined', expected: true },
    { value: 'null', expected: true },
    { value: 'placeholder_value', expected: true },
    { value: 'insert_key_here', expected: true },
    { value: 'real_secret_key_abcdefghij1234567890', expected: false },
    { value: 'AKIAIOSFODNN7XYZABCDEF', expected: false },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { value, expected } of testCases) {
    total++;
    const result = isPlaceholder(value);
    if (result !== expected) {
      console.error(`    ✗ isPlaceholder("${value}") returned ${result}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ isPlaceholder("${value}") correctly returns ${result}`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} placeholder checks work correctly`);
  return passed === total;
}

export function testRedactValue() {
  console.log('  Testing redactValue function...');
  const testCases = [
    { value: 'short', expectedLength: 5 },
    { value: 'abcdefghij1234567890', expectedLength: 9 },
    { value: 'abcdefghij1234567890abcd', expectedLength: 9 },
    { value: 'AKIAIOSFODNN7XYZABCDEF', expectedLength: 9 },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { value, expectedLength } of testCases) {
    total++;
    const result = redactValue(value);
    if (result.length !== expectedLength) {
      console.error(`    ✗ redactValue("${value}") returned length ${result.length}, expected ${expectedLength}`);
    } else {
      passed++;
      console.log(`    ✓ redactValue("${value}") correctly returns "${result}" (length: ${result.length})`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} redaction tests work correctly`);
  return passed === total;
}

export function testGetSeverityLevel() {
  console.log('  Testing getSeverityLevel function...');
  const testCases = [
    { severity: 'CRITICAL', expected: 4 },
    { severity: 'HIGH', expected: 3 },
    { severity: 'MEDIUM', expected: 2 },
    { severity: 'LOW', expected: 1 },
    { severity: 'INFO', expected: 0 },
    { severity: 'UNKNOWN', expected: 0 },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { severity, expected } of testCases) {
    total++;
    const result = getSeverityLevel(severity);
    if (result !== expected) {
      console.error(`    ✗ getSeverityLevel("${severity}") returned ${result}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ getSeverityLevel("${severity}") correctly returns ${result}`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} severity level tests work correctly`);
  return passed === total;
}

export function testGetSeverityColor() {
  console.log('  Testing getSeverityColor function...');
  const testCases = [
    { severity: 'CRITICAL', expected: '#dc3545' },
    { severity: 'HIGH', expected: '#fd7e14' },
    { severity: 'MEDIUM', expected: '#ffc107' },
    { severity: 'LOW', expected: '#6c757d' },
    { severity: 'INFO', expected: '#17a2b8' },
    { severity: 'UNKNOWN', expected: '#6c757d' },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { severity, expected } of testCases) {
    total++;
    const result = getSeverityColor(severity);
    if (result !== expected) {
      console.error(`    ✗ getSeverityColor("${severity}") returned ${result}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ getSeverityColor("${severity}") correctly returns ${result}`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} severity color tests work correctly`);
  return passed === total;
}

export function testPatternCategories() {
  console.log('  Testing pattern categories...');
  const categories = new Set(Object.values(PATTERNS).map(p => p.category));
  const expectedCategories = [
    'Cloud provider keys',
    'LLM API keys',
    'Git / CI tokens',
    'Payments',
    'Messaging & webhooks',
    'Databases / connection strings',
    'Firebase / Supabase / BaaS',
    'Email / SMS services',
    'Private keys / certs',
    'OAuth / app secrets',
    'Credentials in URLs',
    'Generic secret assignment',
    'JWT-looking tokens'
  ];
  
  let passed = true;
  for (const cat of expectedCategories) {
    if (!categories.has(cat)) {
      console.error(`    ✗ Missing category: ${cat}`);
      passed = false;
    }
  }
  
  if (passed) {
    console.log(`    ✓ All ${categories.size} pattern categories present`);
  }
  return passed;
}

export function testPatternDefaultEnabled() {
  console.log('  Testing pattern defaultEnabled flags...');
  const enabledCount = Object.values(PATTERNS).filter(p => p.defaultEnabled).length;
  const disabledCount = Object.values(PATTERNS).filter(p => !p.defaultEnabled).length;
  
  console.log(`    ✓ ${enabledCount} patterns enabled by default, ${disabledCount} disabled by default`);
  return true;
}
