import fs from 'fs';
import path from 'path';

const EXTENSION_DIR = path.resolve(import.meta.dirname, '..');
const SOURCE_DIRS = [
  'src/background',
  'src/content',
  'src/detector',
  'src/popup',
];

function checkSyntax(filePath) {
  const code = fs.readFileSync(filePath, 'utf8');
  const errors = [];

  const importRegex = /import\s+.*\s+from\s+['"].*['"]/g;
  const exportRegex = /export\s+(default\s+)?(function|class|const|let|var|const|{|\(|\[)/g;

  let match;
  while ((match = importRegex.exec(code)) !== null) {
    const importPath = match[0].match(/from\s+['"](.*)['"]/);
    if (importPath && !importPath[1].startsWith('.')) {
      errors.push(`External import not allowed: ${importPath[1]}`);
    }
  }

  while ((match = exportRegex.exec(code)) !== null) {
    if (match[0].includes('default')) {
      errors.push('Default exports not allowed, use named exports');
    }
  }

  return { valid: errors.length === 0, errors };
}

function lintFiles() {
  let totalFiles = 0;
  let validFiles = 0;
  let invalidFiles = 0;
  const errors = [];

  for (const dir of SOURCE_DIRS) {
    const dirPath = path.join(EXTENSION_DIR, dir);
    if (!fs.existsSync(dirPath)) {
      console.warn(`Warning: Directory ${dir} not found`);
      continue;
    }

    const files = fs.readdirSync(dirPath).filter(f => f.endsWith('.js'));
    for (const file of files) {
      totalFiles++;
      const filePath = path.join(dirPath, file);
      const result = checkSyntax(filePath);

      if (result.valid) {
        validFiles++;
        console.log(`✓ ${path.relative(EXTENSION_DIR, filePath)}`);
      } else {
        invalidFiles++;
        console.error(`✗ ${path.relative(EXTENSION_DIR, filePath)}`);
        errors.push({ file: filePath, errors: result.errors });
      }
    }
  }

  console.log(`\nLint complete: ${validFiles}/${totalFiles} files valid`);

  if (errors.length > 0) {
    console.error('\nErrors found:');
    for (const error of errors) {
      console.error(`  ${error.file}:`);
      for (const msg of error.errors) {
        console.error(`    - ${msg}`);
      }
    }
    process.exit(1);
  }
}

lintFiles();
