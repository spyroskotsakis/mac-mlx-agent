import { getSourceMapFromContent, extractSourceMapReferences, analyzeSourceMap } from '../../src/detector/sourcemap.js';

export function testGetSourceMapFromContent() {
  console.log('  Testing getSourceMapFromContent function...');
  const testCases = [
    {
      input: '//# sourceMappingURL=bundle.js.map\n' + JSON.stringify({
        version: 3,
        file: "test.js",
        sources: ["test.ts"],
        names: [],
        mappings: "AAAA"
      }),
      expected: true
    },
    {
      input: '//# sourceMappingURL=https://example.com/bundle.js.map\n' + JSON.stringify({
        version: 3,
        file: "bundle.js",
        sources: ["src/app.ts", "src/utils.ts"],
        names: ["foo", "bar"],
        mappings: "AAAA,SAAS,EAAG,GAAG"
      }),
      expected: true
    },
    {
      input: `const apiKey = 'AKIAIOSFODNN7EXAMPLE';`,
      expected: false
    },
    {
      input: JSON.stringify({
        version: 3,
        sources: ["app.js"]
      }),
      expected: false
    }
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { input, expected } of testCases) {
    total++;
    const result = getSourceMapFromContent(input);
    const hasSourceMap = result.externalUrls?.length > 0 || result.hasInlineMap;
    if (hasSourceMap !== expected) {
      console.error(`    ✗ getSourceMapFromContent returned externalUrls=${JSON.stringify(result.externalUrls)}, hasInlineMap=${result.hasInlineMap}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ getSourceMapFromContent correctly ${expected ? 'found' : 'did not find'} source map`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} source map extraction tests work correctly`);
  return passed === total;
}

export function testExtractSourceMapReferences() {
  console.log('  Testing extractSourceMapReferences function...');
  const testHtml = `
    <!DOCTYPE html>
    <html>
    <head>
      <script src="app.js"></script>
      <script src="app.js.map"></script>
    </head>
    <body>
      <script>
        const mapUrl = 'https://example.com/bundle.js.map';
      </script>
    </body>
    </html>
  `;
  
  const result = extractSourceMapReferences(testHtml);
  
  if (!Array.isArray(result)) {
    console.error(`    ✗ extractSourceMapReferences returned ${typeof result}, expected array`);
    return false;
  }
  
  const hasSourceMapUrls = result.some(url => url.includes('.map'));
  
  if (hasSourceMapUrls) {
    console.log(`    ✓ extractSourceMapReferences correctly found ${result.length} source map references`);
    return true;
  } else {
    console.error(`    ✗ extractSourceMapReferences did not find expected source map URLs (found ${result.length})`);
    return false;
  }
}

export function testAnalyzeSourceMap() {
  console.log('  Testing analyzeSourceMap function...');
  const testMap = {
    version: 3,
    file: 'test.js',
    sources: ['test.ts', 'utils.ts'],
    names: ['foo', 'bar'],
    mappings: 'AAAA,SAAS,EAAG,GAAG'
  };
  
  const result = analyzeSourceMap(testMap);
  
  if (typeof result !== 'object' || result === null) {
    console.error(`    ✗ analyzeSourceMap returned ${typeof result}, expected object`);
    return false;
  }
  
  if (!result.sources || !Array.isArray(result.sources)) {
    console.error(`    ✗ analyzeSourceMap missing sources array`);
    return false;
  }
  
  if (result.sources.length !== 2) {
    console.error(`    ✗ analyzeSourceMap sources length=${result.sources.length}, expected 2`);
    return false;
  }
  
  console.log(`    ✓ analyzeSourceMap correctly returns object with ${result.sources.length} sources`);
  return true;
}

export function testSourceMapEdgeCases() {
  console.log('  Testing source map edge cases...');
  const testCases = [
    { input: '', expected: false },
    { input: 'no source map here', expected: false },
    { input: 'null', expected: false },
  ];
  
  let passed = 0;
  let total = 0;
  
  for (const { input, expected } of testCases) {
    total++;
    const result = getSourceMapFromContent(input);
    const hasSourceMap = result.externalUrls?.length > 0 || result.hasInlineMap;
    if (hasSourceMap !== expected) {
      console.error(`    ✗ getSourceMapFromContent("${input}") returned ${JSON.stringify(result)}, expected ${expected}`);
    } else {
      passed++;
      console.log(`    ✓ getSourceMapFromContent("${input}") correctly ${expected ? 'found' : 'did not find'} source map`);
    }
  }
  
  console.log(`    ✓ ${passed}/${total} edge case tests work correctly`);
  return passed === total;
}
