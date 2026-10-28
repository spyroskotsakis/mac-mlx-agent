export function parseSourceMap(mapContent) {
  try {
    const map = typeof mapContent === 'string' ? JSON.parse(mapContent) : mapContent;
    
    if (!map.sources || !map.sourcesContent) {
      return { sources: [], sourcesContent: [] };
    }

    const sources = map.sources || [];
    const sourcesContent = map.sourcesContent || [];
    
    return {
      sources,
      sourcesContent,
      mappings: map.mappings,
      file: map.file
    };
  } catch (e) {
    console.error('Failed to parse source map:', e);
    return { sources: [], sourcesContent: [] };
  }
}

export function extractSourceMapUrls(content) {
  const urls = [];
  const regex = /\/\/[#@]?\s*sourceMappingURL=(.+?)(?:\s|$)/g;
  let match;
  
  while ((match = regex.exec(content)) !== null) {
    const url = match[1].trim();
    if (url && !url.startsWith('data:')) {
      urls.push(url);
    }
  }
  
  return urls;
}

export function parseDataUrlSourceMap(dataUrl) {
  try {
    const base64 = dataUrl.split(',')[1];
    const decoded = atob(base64);
    return JSON.parse(decoded);
  } catch (e) {
    console.error('Failed to parse inline source map:', e);
    return null;
  }
}

export function getSourceMapFromContent(content) {
  const urls = extractSourceMapUrls(content);
  
  if (urls.length > 0) {
    return {
      externalUrls: urls,
      hasInlineMap: content.includes('data:application/json') && content.includes('sourceMappingURL')
    };
  }
  
  return { externalUrls: [], hasInlineMap: false };
}

export function analyzeSourceMap(mapContent) {
  try {
    const map = typeof mapContent === 'string' ? JSON.parse(mapContent) : mapContent;
    
    if (!map.sources) {
      return { sources: [], sourcesContent: [] };
    }

    const sources = map.sources || [];
    const sourcesContent = map.sourcesContent || [];
    
    return {
      sources,
      sourcesContent,
      mappings: map.mappings,
      file: map.file
    };
  } catch (e) {
    console.error('Failed to analyze source map:', e);
    return { sources: [], sourcesContent: [] };
  }
}

export function extractSourceMapReferences(content) {
  const references = [];
  const scriptRegex = /<script\s[^>]*src=["']([^"']*\.map[^"']*)["']\s*[^>]*>/gi;
  const urlRegex = /\/\/[#@]?\s*sourceMappingURL=(.+?)(?:\s|$)/g;
  const inlineRegex = /data:application\/json;base64,[A-Za-z0-9+\/=]+/g;
  let match;

  while ((match = scriptRegex.exec(content)) !== null) {
    references.push(match[1]);
  }

  while ((match = urlRegex.exec(content)) !== null) {
    const url = match[1].trim();
    if (url && !url.startsWith('data:')) {
      references.push(url);
    }
  }

  while ((match = inlineRegex.exec(content)) !== null) {
    references.push(match[0].slice(0, 50) + '...');
  }

  return references;
}
