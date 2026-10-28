export const PATTERNS = {
  // Cloud Provider Keys
  AWS_ACCESS_KEY: {
    category: 'Cloud provider keys',
    severity: 'CRITICAL',
    regex: /AKIA[0-9A-Z]{16}/gi,
    defaultEnabled: true
  },
  AWS_SECRET: {
    category: 'Cloud provider keys',
    severity: 'CRITICAL',
    regex: /(aws_secret_access_key|aws_secret)\s*[=:]\s*["']?([A-Za-z0-9/+=]{40})["']?/gi,
    defaultEnabled: true
  },
  GCP_SERVICE_ACCOUNT: {
    category: 'Cloud provider keys',
    severity: 'CRITICAL',
    regex: /"private_key":\s*"-----BEGIN RSA PRIVATE KEY-----[\s\S]*?-----END RSA PRIVATE KEY-----/gi,
    defaultEnabled: true
  },
  AZURE_ACCOUNT_KEY: {
    category: 'Cloud provider keys',
    severity: 'CRITICAL',
    regex: /AccountKey=[A-Za-z0-9+/=]{88}/gi,
    defaultEnabled: true
  },
  AZURE_SAS: {
    category: 'Cloud provider keys',
    severity: 'CRITICAL',
    regex: /sig=[A-Za-z0-9%+=\/]{100,}/gi,
    defaultEnabled: true
  },

  // LLM API Keys
  OPENAI: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /sk-proj-[A-Za-z0-9]{48,}/gi,
    defaultEnabled: true
  },
  ANTHROPIC: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /sk-ant-[A-Za-z0-9_-]{48,}/gi,
    defaultEnabled: true
  },
  GOOGLE_AI_STUDIO: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /AIza[0-9A-Za-z_-]{33}/gi,
    defaultEnabled: true
  },
  DEEPSEEK: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /sk-[A-Za-z0-9]{48,}/gi,
    defaultEnabled: true
  },
  MISTRAL: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /mistral-[A-Za-z0-9]{48,}/gi,
    defaultEnabled: true
  },
  COHERE: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9_-]{48}/gi,
    defaultEnabled: false
  },
  GROQ: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /gsk_[A-Za-z0-9]{48}/gi,
    defaultEnabled: true
  },
  OPENROUTER: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /sk-or-v1-[A-Za-z0-9]{64,}/gi,
    defaultEnabled: true
  },
  HUGGINGFACE: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /hf_[A-Za-z0-9]{32,}/gi,
    defaultEnabled: true
  },
  REPLICATE: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /r8_[A-Za-z0-9]{48,}/gi,
    defaultEnabled: true
  },
  ELEVENLABS: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /elevenlabs-[A-Za-z0-9]{48,}/gi,
    defaultEnabled: true
  },
  PERPLEXITY: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /pplx-[A-Za-z0-9]{48,}/gi,
    defaultEnabled: true
  },
  XAI: {
    category: 'LLM API keys',
    severity: 'HIGH',
    regex: /xai-[A-Za-z0-9]{48,}/gi,
    defaultEnabled: true
  },

  // Git/CI Tokens
  GITHUB_PAT: {
    category: 'Git / CI tokens',
    severity: 'CRITICAL',
    regex: /ghp_[A-Za-z0-9]{36}/gi,
    defaultEnabled: true
  },
  GITHUB_FINE_GRAINED: {
    category: 'Git / CI tokens',
    severity: 'CRITICAL',
    regex: /github_pat_[A-Za-z0-9]{22,}/gi,
    defaultEnabled: true
  },
  GITHUB_OAUTH: {
    category: 'Git / CI tokens',
    severity: 'CRITICAL',
    regex: /gho_[A-Za-z0-9]{36}/gi,
    defaultEnabled: true
  },
  GITLAB: {
    category: 'Git / CI tokens',
    severity: 'CRITICAL',
    regex: /glpat-[A-Za-z0-9_-]{20,}/gi,
    defaultEnabled: true
  },
  BITBUCKET: {
    category: 'Git / CI tokens',
    severity: 'CRITICAL',
    regex: /AT[A-Za-z0-9]{32,}/gi,
    defaultEnabled: true
  },
  NPM: {
    category: 'Git / CI tokens',
    severity: 'CRITICAL',
    regex: /npm_[A-Za-z0-9]{36}/gi,
    defaultEnabled: true
  },
  PYPI: {
    category: 'Git / CI tokens',
    severity: 'CRITICAL',
    regex: /pypi-[A-Za-z0-9_-]{48,}/gi,
    defaultEnabled: true
  },

  // Payments
  STRIPE_LIVE: {
    category: 'Payments',
    severity: 'CRITICAL',
    regex: /sk_live_[A-Za-z0-9]{24,}/gi,
    defaultEnabled: true
  },
  STRIPE_TEST: {
    category: 'Payments',
    severity: 'HIGH',
    regex: /sk_test_[A-Za-z0-9]{24,}/gi,
    defaultEnabled: true
  },
  PAYPAL: {
    category: 'Payments',
    severity: 'HIGH',
    regex: /A[a-zA-Z0-9_-]{20,}/gi,
    defaultEnabled: false
  },

  // Messaging & Webhooks
  SLACK: {
    category: 'Messaging & webhooks',
    severity: 'HIGH',
    regex: /xox[baprs]-[0-9A-Za-z-]+/gi,
    defaultEnabled: true
  },
  SLACK_WEBHOOK: {
    category: 'Messaging & webhooks',
    severity: 'HIGH',
    regex: /hooks\.slack\.com\/services\/[A-Za-z0-9\/]+/gi,
    defaultEnabled: true
  },
  DISCORD_WEBHOOK: {
    category: 'Messaging & webhooks',
    severity: 'HIGH',
    regex: /https:\/\/discord\.com\/api\/webhooks\/[0-9]{17,20}\/[A-Za-z0-9_-]{60,}/gi,
    defaultEnabled: true
  },
  TELEGRAM_BOT: {
    category: 'Messaging & webhooks',
    severity: 'HIGH',
    regex: /\d{8,10}:[A-Za-z0-9_-]{35}/gi,
    defaultEnabled: true
  },

  // Databases
  POSTGRES: {
    category: 'Databases / connection strings',
    severity: 'CRITICAL',
    regex: /postgres(ql)?:\/\/[^\s"'>]+:[^\s"'>]+@[^\s"'>]+/gi,
    defaultEnabled: true
  },
  MYSQL: {
    category: 'Databases / connection strings',
    severity: 'CRITICAL',
    regex: /mysql:\/\/[^\s"'>]+:[^\s"'>]+@[^\s"'>]+/gi,
    defaultEnabled: true
  },
  MONGODB: {
    category: 'Databases / connection strings',
    severity: 'CRITICAL',
    regex: /mongodb(\+srv)?:\/\/[^\s"'>]+:[^\s"'>]+@[^\s"'>]+/gi,
    defaultEnabled: true
  },
  REDIS: {
    category: 'Databases / connection strings',
    severity: 'CRITICAL',
    regex: /redis:\/\/[^\s"'>]+:[^\s"'>]+@[^\s"'>]+/gi,
    defaultEnabled: true
  },
  JDBC: {
    category: 'Databases / connection strings',
    severity: 'CRITICAL',
    regex: /jdbc:[^"'\s]+:[^"'\s]+;[^\s"'>]*password[^\s"'>]*/gi,
    defaultEnabled: true
  },

  // Firebase/Supabase/BaaS
  FIREBASE_SERVICE_ACCOUNT: {
    category: 'Firebase / Supabase / BaaS',
    severity: 'HIGH',
    regex: /"serviceAccount":\s*\{[\s\S]*?"private_key_id":\s*"[A-Za-z0-9]{32,}"[\s\S]*?\}/gi,
    defaultEnabled: true
  },
  SUPABASE_KEY: {
    category: 'Firebase / Supabase / BaaS',
    severity: 'HIGH',
    regex: /s{2,}[A-Za-z0-9_-]{40,}/gi,
    defaultEnabled: false
  },

  // Email/SMS
  TWILIO: {
    category: 'Email / SMS services',
    severity: 'HIGH',
    regex: /AC[a-f0-9]{32}/gi,
    defaultEnabled: true
  },
  SENDGRID: {
    category: 'Email / SMS services',
    severity: 'HIGH',
    regex: /SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}/gi,
    defaultEnabled: true
  },
  MAILGUN: {
    category: 'Email / SMS services',
    severity: 'HIGH',
    regex: /key-[A-Za-z0-9_-]{32,}/gi,
    defaultEnabled: true
  },
  RESEND: {
    category: 'Email / SMS services',
    severity: 'HIGH',
    regex: /re_[A-Za-z0-9]{24,}/gi,
    defaultEnabled: true
  },

  // Private Keys
  PRIVATE_KEY_HEADER: {
    category: 'Private keys / certs',
    severity: 'CRITICAL',
    regex: /-----BEGIN (RSA|EC|DSA|OPENSSH|PGP) PRIVATE KEY-----[\s\S]*?-----END (RSA|EC|DSA|OPENSSH|PGP) PRIVATE KEY-----/gi,
    defaultEnabled: true
  },

  // OAuth/Secrets
  CLIENT_SECRET: {
    category: 'OAuth / app secrets',
    severity: 'HIGH',
    regex: /"client_secret"\s*:\s*"([^"']{20,})"/gi,
    defaultEnabled: true
  },
  CLIENT_ID_SECRET_PAIR: {
    category: 'OAuth / app secrets',
    severity: 'HIGH',
    regex: /"client_id"\s*:\s*"[^"]+"[\s\S]*?"client_secret"\s*:\s*"[^"]+"/gi,
    defaultEnabled: false
  },

  // Credentials in URLs
  URL_CREDENTIALS: {
    category: 'Credentials in URLs',
    severity: 'HIGH',
    regex: /[a-z]+:\/\/[^\s"'>]+:[^\s"'>]+@[^\s"'>]+/gi,
    defaultEnabled: true
  },

  // Generic secrets
  GENERIC_SECRET: {
    category: 'Generic secret assignment',
    severity: 'MEDIUM',
    regex: /(?:(?:api[_-]?key|apikey|secret|password|passwd|auth[_-]?token|access[_-]?token|bearer)\s*[=:]\s*["'])([A-Za-z0-9_\-\/+=]{12,})["']/gi,
    defaultEnabled: true
  },

  // JWT tokens
  JWT_TOKEN: {
    category: 'JWT-looking tokens',
    severity: 'LOW',
    regex: /eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/gi,
    defaultEnabled: false
  }
};

export const PLACEHOLDERS = [
  'your_',
  'xxx',
  'example',
  'changeme',
  'todo',
  '...',
  '${env',
  'process.env',
  'undefined',
  'null',
  'placeholder',
  'insert_'
];

export function isPlaceholder(value) {
  const lower = value.toLowerCase();
  return PLACEHOLDERS.some(p => lower.includes(p.toLowerCase()));
}

export function redactValue(value) {
  if (!value || value.length <= 8) {
    return '…'.repeat(value.length);
  }
  return value.slice(0, 4) + '…' + value.slice(-4);
}

export function getSeverityLevel(severity) {
  const levels = {
    'CRITICAL': 4,
    'HIGH': 3,
    'MEDIUM': 2,
    'LOW': 1,
    'INFO': 0
  };
  return levels[severity] || 0;
}

export function getSeverityColor(severity) {
  const colors = {
    'CRITICAL': '#dc3545',
    'HIGH': '#fd7e14',
    'MEDIUM': '#ffc107',
    'LOW': '#6c757d',
    'INFO': '#17a2b8'
  };
  return colors[severity] || '#6c757d';
}
