import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const EXTENSION_DIR = path.resolve(import.meta.dirname, '..');
const TEST_DIR = path.join(EXTENSION_DIR, 'test');

async function runTests() {
  console.log('Running tests...\n');

  if (!fs.existsSync(TEST_DIR)) {
    console.log('No test directory found. Create test/ directory with test files.');
    console.log('Example: test/unit/testEngine.js');
    return;
  }

  const testFiles = findTestFiles(TEST_DIR);

  if (testFiles.length === 0) {
    console.log('No test files found.');
    console.log('Create test files in test/ directory.');
    return;
  }

  console.log(`Found ${testFiles.length} test file(s):\n`);

  let passed = 0;
  let failed = 0;

  for (const testFile of testFiles) {
    try {
      const testModule = await import(testFile);
      const tests = findTestFunctions(testModule);

      if (tests.length === 0) {
        console.log(`  ⚠ ${path.relative(EXTENSION_DIR, testFile)} - No test functions found`);
        continue;
      }

      for (const testName of tests) {
        try {
          const result = await testModule[testName]();
          if (result === true || result === undefined) {
            console.log(`  ✓ ${path.relative(EXTENSION_DIR, testFile)}: ${testName}`);
            passed++;
          } else {
            console.error(`  ✗ ${path.relative(EXTENSION_DIR, testFile)}: ${testName}`);
            failed++;
          }
        } catch (err) {
          console.error(`  ✗ ${path.relative(EXTENSION_DIR, testFile)}: ${testName}`);
          console.error(`    Error: ${err.message}`);
          failed++;
        }
      }
    } catch (err) {
      console.error(`  ✗ ${path.relative(EXTENSION_DIR, testFile)} - Failed to load`);
      console.error(`    ${err.message}`);
      failed++;
    }
  }

  console.log(`\nResults: ${passed} passed, ${failed} failed`);

  if (failed > 0) {
    process.exit(1);
  }
}

function findTestFiles(dir) {
  let files = [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files = files.concat(findTestFiles(fullPath));
    } else if (entry.name.match(/test.*\.js$/i) || entry.name.match(/.*\.test\.js$/i)) {
      files.push(fullPath);
    }
  }

  return files;
}

function findTestFunctions(module) {
  const testFunctions = [];
  for (const key of Object.keys(module)) {
    if (key.startsWith('test') || key.startsWith('it') || key.startsWith('describe')) {
      if (typeof module[key] === 'function') {
        testFunctions.push(key);
      }
    }
  }
  return testFunctions;
}

runTests();
