// Content script that extracts HTML content and sends it to background for scanning
(function() {
  if (document.readyState !== 'loading') {
    extractAndSend();
  } else {
    window.addEventListener('DOMContentLoaded', extractAndSend);
  }

  function extractAndSend() {
    // Extract HTML content
    const htmlContent = document.documentElement.outerHTML;
    
    // Extract inline scripts and styles
    const inlineScripts = [];
    const inlineStyles = [];
    
    // Extract inline scripts
    const scriptElements = document.querySelectorAll('script');
    scriptElements.forEach(script => {
      if (script.src) {
        // Skip external scripts, we'll handle them separately
        return;
      }
      inlineScripts.push({
        content: script.textContent,
        type: script.type || 'text/javascript'
      });
    });
    
    // Extract styles
    const styleElements = document.querySelectorAll('style');
    styleElements.forEach(style => {
      inlineStyles.push({
        content: style.textContent,
        type: style.type || 'text/css'
      });
    });
    
    // Extract JSON-LD and other metadata
    const jsonLd = [];
    const metaTags = [];
    const comments = [];
    
    // Get all comments in the document
    const walker = document.createTreeWalker(
      document,
      Node.COMMENT_NODE,
      null,
      false
    );
    
    while (walker.nextNode()) {
      const comment = walker.currentNode.textContent.trim();
      if (comment.length > 0) {
        comments.push(comment);
      }
    }
    
    // Send extracted content to background script
    chrome.runtime.sendMessage({
      type: 'extractedContent',
      data: {
        html: htmlContent,
        inlineScripts: inlineScripts,
        inlineStyles: inlineStyles,
        comments: comments
      }
    });
  }
})();