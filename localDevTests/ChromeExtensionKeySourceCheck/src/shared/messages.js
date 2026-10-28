const MESSAGE_TYPES = {
  SCAN_PAGE: 'SCAN_PAGE',
  SCAN_RESULT: 'SCAN_RESULT',
  GET_PATTERNS: 'GET_PATTERNS',
  GET_STATUS: 'GET_STATUS',
  UPDATE_SETTINGS: 'UPDATE_SETTINGS',
  GET_SETTINGS: 'GET_SETTINGS',
  CLEAR_RESULTS: 'CLEAR_RESULTS',
  SCAN_LAYERS: 'SCAN_LAYERS',
  LAYER_RESULT: 'LAYER_RESULT',
  OLLAMA_CHECK: 'OLLAMA_CHECK',
  OLLAMA_RESPONSE: 'OLLAMA_RESPONSE',
};

const MESSAGE_SCHEMA = {
  SCAN_PAGE: {
    required: ['tabId'],
    optional: ['options'],
  },
  SCAN_LAYERS: {
    required: ['tabId', 'layers'],
    optional: ['settings'],
  },
  SCAN_RESULT: {
    required: ['tabId', 'findings'],
  },
  LAYER_RESULT: {
    required: ['tabId', 'layer', 'results'],
  },
  OLLAMA_CHECK: {
    required: ['tabId', 'context'],
    optional: ['model', 'url'],
  },
  OLLAMA_RESPONSE: {
    required: ['tabId', 'analysis'],
    optional: ['model', 'confidence'],
  },
  GET_PATTERNS: {},
  GET_STATUS: {},
  UPDATE_SETTINGS: {
    required: ['settings'],
  },
  GET_SETTINGS: {},
  CLEAR_RESULTS: {
    required: ['tabId'],
  },
};

function validateMessage(type, payload) {
  const schema = MESSAGE_SCHEMA[type];
  if (!schema) {
    throw new Error(`Unknown message type: ${type}`);
  }

  for (const requiredField of schema.required) {
    if (!(requiredField in payload)) {
      throw new Error(`Missing required field: ${requiredField}`);
    }
  }

  return true;
}

export { MESSAGE_TYPES, MESSAGE_SCHEMA, validateMessage };
