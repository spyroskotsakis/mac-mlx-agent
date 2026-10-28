import fs from 'fs';
import path from 'path';

const EXTENSION_DIR = path.resolve(import.meta.dirname, '..');
const BUILD_DIR = path.join(EXTENSION_DIR, 'build');

function cleanBuildDir() {
  if (fs.existsSync(BUILD_DIR)) {
    fs.rmSync(BUILD_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(BUILD_DIR, { recursive: true });
  console.log('Cleaned build directory');
}

function copyExtensionFiles() {
  const filesToCopy = [
    'manifest.json',
    'src/popup/popup.html',
    'src/popup/popup.js',
    'src/popup/popup.css',
    'src/options/options.html',
    'src/options/options.js',
    'src/options/options.css',
    'src/background/sw.js',
    'src/content/extractor.js',
    'src/detector/engine.js',
    'src/detector/patterns.js',
    'src/detector/entropy.js',
    'src/detector/sourcemap.js',
    'src/shared/storage.js',
    'src/shared/messages.js',
  ];

  for (const file of filesToCopy) {
    const srcPath = path.join(EXTENSION_DIR, file);
    const destPath = path.join(BUILD_DIR, file);
    const destDir = path.dirname(destPath);

    if (fs.existsSync(srcPath)) {
      if (!fs.existsSync(destDir)) {
        fs.mkdirSync(destDir, { recursive: true });
      }
      fs.copyFileSync(srcPath, destPath);
      console.log(`Built: ${file}`);
    } else {
      console.warn(`Warning: ${file} not found, skipping`);
    }
  }

  // Copy icons
  const iconsDir = path.join(EXTENSION_DIR, 'icons');
  if (fs.existsSync(iconsDir)) {
    const buildIconsDir = path.join(BUILD_DIR, 'icons');
    if (!fs.existsSync(buildIconsDir)) {
      fs.mkdirSync(buildIconsDir, { recursive: true });
    }
    const iconFiles = fs.readdirSync(iconsDir).filter(f => /\.(png|svg|ico)$/i.test(f));
    for (const iconFile of iconFiles) {
      const srcPath = path.join(iconsDir, iconFile);
      const destPath = path.join(buildIconsDir, iconFile);
      fs.copyFileSync(srcPath, destPath);
      console.log(`Built: icons/${iconFile}`);
    }
  }

  console.log(`\nExtension built to: ${BUILD_DIR}`);
  console.log('Load this directory in Chrome: chrome://extensions -> Load unpacked');
}

cleanBuildDir();
copyExtensionFiles();
