import http from 'http';
import fs from 'fs';
import path from 'path';

const EXTENSION_DIR = path.resolve(import.meta.dirname, '..');
const DIST_DIR = path.join(EXTENSION_DIR, 'dist');
const PORT = 8080;

function startServer() {
  const server = http.createServer((req, res) => {
    let filePath = path.join(DIST_DIR, req.url === '/' ? 'index.html' : req.url);
    const ext = path.extname(filePath).toLowerCase();
    const contentTypes = {
      '.html': 'text/html',
      '.js': 'application/javascript',
      '.css': 'text/css',
      '.json': 'application/json',
      '.png': 'image/png',
      '.svg': 'image/svg+xml',
    };
    const contentType = contentTypes[ext] || 'application/octet-stream';

    fs.readFile(filePath, (err, data) => {
      if (err) {
        res.writeHead(404);
        res.end('Not found');
        return;
      }
      res.writeHead(200, { 'Content-Type': contentType });
      res.end(data);
    });
  });

  server.listen(PORT, () => {
    console.log(`Dev server running at http://localhost:${PORT}`);
    console.log(`Extension directory: ${DIST_DIR}`);
    console.log('Press Ctrl+C to stop');
  });

  return server;
}

function copyExtensionFiles() {
  if (!fs.existsSync(DIST_DIR)) {
    fs.mkdirSync(DIST_DIR, { recursive: true });
  }

  const filesToCopy = [
    'manifest.json',
    'src/popup/popup.html',
    'src/popup/popup.js',
    'src/popup/options.html',
    'src/popup/options.js',
    'src/background/sw.js',
    'src/content/extractor.js',
    'src/detector/engine.js',
    'src/detector/patterns.js',
    'src/detector/entropy.js',
    'src/detector/sourcemap.js',
  ];

  for (const file of filesToCopy) {
    const srcPath = path.join(EXTENSION_DIR, file);
    const destPath = path.join(DIST_DIR, file);
    const destDir = path.dirname(destPath);

    if (fs.existsSync(srcPath)) {
      if (!fs.existsSync(destDir)) {
        fs.mkdirSync(destDir, { recursive: true });
      }
      fs.copyFileSync(srcPath, destPath);
      console.log(`Copied: ${file}`);
    } else {
      console.warn(`Warning: ${file} not found, skipping`);
    }
  }

  console.log('\nExtension files copied to dist/');
}

copyExtensionFiles();
const server = startServer();

process.on('SIGINT', () => {
  console.log('\nStopping dev server...');
  server.close();
  process.exit(0);
});
