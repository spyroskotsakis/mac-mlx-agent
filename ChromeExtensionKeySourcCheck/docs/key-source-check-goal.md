# Goal: Build "KeySourceCheck" — Chrome extension that finds leaked API keys & secrets in website source code

You are building a complete, production-quality Chrome extension (Manifest V3) **in this folder** (`ChromeExtensionKeySourcCheck` — treat it as the repo root). Do not work anywhere else. Build it to completion, verify it with real execution, and end with the acceptance matrix filled in.

## 1. Product vision (non-negotiables, from the user)

1. **User-gated:** the extension does absolutely nothing until the user enables it (toggle). Disabling stops all scanning, network activity, and badge updates. State persists across restarts.
2. **Automatic:** once enabled, scanning happens automatically while the user browses — no manual per-page action.
3. **Deep discovery:** on every page load, the extension must also fetch and scan files that are *not initially visible* in the HTML (external `.js`, `.css`, source maps and their embedded sources). While the user keeps browsing within a site, newly discovered asset URLs are queued and scanned in the background ("stash more files") — politely rate-limited, deduplicated, capped.
4. **Local Ollama deep check:** regex detection runs fully offline. In addition, suspicious/medium-confidence findings are sent in batches to a **local Ollama** instance for LLM classification ("deeper check"). The extension must work fine when Ollama is down (graceful fallback + notice). This is an opt-in feature in settings; default = ON if Ollama is reachable, else auto-off.
5. **Fluid, polished UI/UX:** a modern, clean popup dashboard, per-tab results, severity badges, progress states, and an options page. Dark-mode friendly. No jank.
6. **Defensive tool, privacy-first:** no data leaves the machine except fetches of the browsed site's own origin(s) and calls to `localhost:11434`. Never use external APIs, analytics, or third-party CDNs in the extension UI. Keep secrets in storage only long enough to display; redact values in the UI.

## 2. Tech constraints

- Manifest V3: background **service worker** + **content script(s)** + **popup** + **options page**. No legacy background pages.
- Plain modern JavaScript (ES modules) or TypeScript with esbuild — **your choice, record it once, stay consistent**. No UI frameworks, no jQuery, no runtime deps unless genuinely necessary (prefer zero).
- Storage: `chrome.storage.local` for settings, per-tab findings, and the scan queue.
- Permissions: `storage`, `webNavigation`; scanning uses **optional host permissions** (`<all_urls>` + `http://localhost:11434/*`) requested the first time the user enables the extension — this is what "enabled by the user" means in practice. Handle denial gracefully (banner explaining why scanning is limited).
- **Pitfall to respect:** ALL `fetch` calls to Ollama MUST go through the background service worker (which has host permissions). Content-script fetches inherit page CORS and will fail.
- Skip scanning for: `chrome://`, `chrome-extension://`, `edge://`, `file://`, Web Store pages. Skip data: URLs.
- SPA support: react to `webNavigation.onHistoryStateUpdated` as well as `onCommitted`.
- macOS dev machine: you can only natively verify macOS Chrome. Note anything you cannot verify (Windows/Linux) in the final report; do not claim it.

## 3. Detection engine (the heart of it)

Implement a pure-JS detector module (no DOM access, fully unit-testable) that scans any string (HTML, JS, CSS, map content) and returns findings: `{id, category, severity, matchedValue, redactedValue, snippet (±60 chars), confidence, detectionType: 'regex'|'entropy'|'llm'}`.

### 3.1 Category matrix (all MUST, unless marked optional)

| Category | Examples / pattern hints | Default severity |
|---|---|---|
| LLM API keys | OpenAI `sk-proj-…`, `sk-…`; Anthropic `sk-ant-api03-…`; Google AI Studio `AIza[0-9A-Za-z_-]{35}`; DeepSeek `sk-…`; Mistral; Cohere; Groq `gsk_[A-Za-z0-9]{40,}`; OpenRouter `sk-or-…`; Together; HuggingFace `hf_[A-Za-z0-9]{30,}`; Replicate `r8_…`; ElevenLabs; Perplexity `pplx-…`; xAI | HIGH |
| Cloud provider keys | AWS access key `AKIA[0-9A-Z]{16}` (Critical), AWS secret (context), GCP service-account JSON `"private_key"`, Azure `AccountKey=`, SAS tokens `sig=` | CRITICAL |
| Git / CI tokens | GitHub `ghp_[A-Za-z0-9]{36}`, `github_pat_…` (fine-grained), `gho_…`; GitLab `glpat-…`; Bitbucket; npm `npm_[A-Za-z0-9]{36}`; PyPI `pypi-…`; CircleCI/Travis tokens | CRITICAL |
| Payments | Stripe `sk_live_[0-9a-zA-Z]{24,}` (Critical); `sk_test_…` (High); PayPal, Square, Coinbase keys | CRITICAL/HIGH |
| Messaging & webhooks | Slack `xoxb-…`, `xoxp-…`, webhook URL `hooks.slack.com/services/…`; Discord webhook `discord.com/api/webhooks/\d{17,20}/[A-Za-z0-9_-]{60,}`; Telegram bot `\d{8,10}:[A-Za-z0-9_-]{35}` | HIGH |
| Databases / connection strings | `postgres://user:pass@`, `mysql://`, `mongodb+srv://`, `redis://` with credentials, JDBC with password | CRITICAL |
| Firebase / Supabase / BaaS | `serviceAccount` JSON, `supabase_key`, long `eyJ…` JWT secrets with `secret`/`service_role` context, Firebase `private_key_id` | HIGH |
| Email / SMS services | Twilio `AC[a-f0-9]{32}` + auth token context; SendGrid `SG.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}`; Mailgun `key-…`; Resend `re_[A-Za-z0-9]{24,}` | HIGH |
| Private keys / certs | `-----BEGIN (RSA|EC|DSA|OPENSSH|PGP) PRIVATE KEY-----` blocks | CRITICAL |
| OAuth / app secrets | `client_secret=…`, `client_secret": "…"` (non-empty, long), `client_id` only when paired with secret-like value | HIGH |
| Credentials in URLs | `scheme://user:password@host` (incl. URL-encoded `%40`) | HIGH |
| Generic secret assignment | `(api[_ -]?key|apikey|secret|password|passwd|auth[_ -]?token|access[_ -]?token|bearer)` followed by `=`/`:` and a quoted string ≥ 12 chars that is not a placeholder (`YOUR_`, `xxx`, `example`, `changeme`, `TODO`, `…`, `${env`, `process.env`, `undefined`, `null`) | MEDIUM |
| High-entropy strings (heuristic) | base64/hex/blob ≥ 24 chars, Shannon entropy ≥ 4.4, inside JS source, not matching known-lib fingerprints | LOW (escalates via Ollama) |
| JWT-looking tokens | `eyJ…` segments in script context (optional — can merge into generic/BaaS) | LOW |

False-positive controls (required): exclude matches inside comments that say "example/placeholder", inside test fixtures if clearly a test domain, well-known public libs hashes, UUIDs, and any value containing `process.env`/`import.meta.env`. Redaction rule: show first 4 and last 4 chars of the value, everything else `…` (e.g. `sk-pr…zY12`).

### 3.2 Layered scan pipeline

- **Layer 0 — instant:** content script extracts the page's own HTML source, inline `<script>` bodies, JSON-LD, meta tags, and notable HTML comments → send to SW → detector scans → findings appear within ~1s, badge updates.
- **Layer 1 — deep fetch:** from the DOM, collect all `<script src>`, `<link rel="stylesheet" href>`, and module preload URLs; SW fetches each (same-origin + CORS-permitted cross-origin), caps size (≤ 5 MB per file, skip larger but note it), scans content. Record unreachable URLs as "not scanned (count)" without spamming the UI.
- **Layer 2 — source map recursion:** for every fetched JS containing `//# sourceMappingURL=…`, fetch the `.map` (including data: URL maps), parse `sources` + `sourcesContent`, scan every embedded source. Recursion depth ≤ 3. This is where forgotten keys usually live — make it bulletproof.
- **Layer 3 — browse-driven crawl:** every discovered asset URL is pushed into a per-origin queue in `storage`; a SW worker drains it while the user keeps browsing that site (and across navigations within it). Dedupe by URL globally (per session), rate-limit (default: max 3 concurrent fetches, ~400 ms between same-origin requests), respect `Content-Type` (skip images/videos/fonts), stop when the user disables the extension or leaves the origin's browsing session.
- **Layer 4 — Ollama deep check:** when enabled and reachable, collect candidates (entropy hits + MEDIUM/LOW-confidence regex hits, batched ≤ 10 snippets or ~4k chars per request) → POST to `{ollamaUrl}/api/chat` (JSON mode, `format: json`) with a strict system prompt: *"You are a secret-scanner classifier. For each snippet, return JSON: [{id, verdict: 'secret'|'benign'|'uncertain', category, severity, reason}]"*. Merge verdicts: `secret` → raise severity per category, `benign` → demote to ignored/Info with "LLM-cleared" tag, `uncertain` → keep. Mark findings as `llm: confirmed|cleared|pending`. Connection check: `GET {ollamaUrl}/api/tags` with 2s timeout.

## 4. UI/UX spec

- **Toolbar badge:** per-tab count of unignored findings, colored by max severity (critical=red, high=orange, medium=yellow, low=gray), spinner state while scanning, hidden when disabled.
- **Popup (dashboard):** header with master enable/disable toggle + gear (options) + per-site summary (site favicon/origin, finding counts by severity). Tab bar: "This site" / "All sites". Findings list: severity badge, category chip, redacted value (monospace), source (file URL or "inline HTML"), snippet preview, confidence + detection type, LLM tag if any. Click to expand: full details + actions — Copy value (copies redacted + warns), Open source file, Ignore (adds whitelist rule), Export. Empty state: friendly "Nothing leaked here — nice!" illustration-free, clean. Live scan progress bar per tab while layers 0–2 run. Findings persist per tab while browsing; cleared on tab close (keep a small "recent sites" history in options if cheap).
- **Options page:** Ollama section (URL input default `http://localhost:11434`, model dropdown loaded from `/api/tags`, "Test connection" button with live result, enable/disable deep check); Detector section (per-category toggles); Custom patterns (user-defined regex + name + severity, validated, persisted, applied before generic rules); Ignore/whitelist rules list (delete items); Crawl settings (on/off, max files per site, rate limit); Data (clear all findings/history). All settings persist in `chrome.storage.local` and apply immediately.
- **Design language:** modern, compact, readable; CSS custom properties for theming (support `prefers-color-scheme: dark`); subtle transitions only; accessible (keyboard nav, aria labels, focus states); no external fonts/images — inline SVG icons.

## 5. Project structure (suggested, adapt minimally)

```
manifest.json
src/
  background/sw.js          # pipeline, queue, Ollama client, badge
  content/extractor.js      # Layer 0 extraction + asset discovery
  detector/                 # PURE logic, no chrome APIs
    engine.js patterns.js entropy.js redact.js sourcemap.js
  popup/  (popup.html/js/css)
  options/ (options.html/js/css)
  shared/ (storage.js, messages.js, ui.css)
test/
  detector.test.js          # node --test, fixture-driven
  fixtures/secrets.json     # per-category: true-positives + negatives
  fixtures/leaky-site/      # local test site: index.html + app.js + app.js.map with fake embedded secrets + 2nd page for crawl test + clean-page/
README.md
```

## 6. Execution order (phases with gates — do not skip a gate)

- **Phase 1 — Scaffold:** manifest (MV3, permissions per §2), folder structure, build tooling if TS, README skeleton. Gate: manifest passes validation (`chrome --load-extension` via unpacked load, or JSON schema check) + `node --test` harness boots.
- **Phase 2 — Detector engine:** §3.1 full matrix + entropy + redaction + sourcemap parser. Write `test/fixtures/secrets.json` with ≥ 3 true-positives and ≥ 3 near-miss negatives per category (use realistic fake values, never real ones). Gate: ALL unit tests green, `node --test` output pasted in report.
- **Phase 3 — Scan pipeline:** content script + SW Layers 0–2 + queue (Layer 3). Build `test/fixtures/leaky-site/` (static, serve with `python3 -m http.server`): index.html with an inline secret, app.js with another, app.js.map with a third embedded in `sourcesContent`, a second page linked from index for crawl verification, plus `clean-page/` with zero secrets. Gate: manual E2E — load unpacked in real Chrome, open fixture, document actual findings (paste real console/storage output), clean page shows zero false positives.
- **Phase 4 — Ollama integration:** Layer 4 + settings + connection test. Gate: with local Ollama running (`/usr/local/bin/ollama`, models available on this machine: `qwen3-coder:480b-cloud`, `qwen3-vl` — discover via `ollama list`; make model configurable, never hardcode), verify a real deep-check run end-to-end (paste the JSON verdict); also verify graceful behavior with Ollama stopped.
- **Phase 5 — UI:** popup + options + badge per §4. Gate: every UI action verified in real Chrome (toggle on/off stops scanning, ignore works, custom regex catches a planted value, export produces valid JSON).
- **Phase 6 — Final verification:** fresh-clone test (clone this folder to a temp dir, install, build, run unit tests, load in Chrome — no assumptions), re-run the full acceptance matrix below, write/complete README (install steps, privacy model, limitations, authorized-use disclaimer).

## 7. Guardrails

- Do NOT `git init`, commit, or push unless explicitly told. If the folder is already a repo, leave the working tree dirty.
- Never invent test results or claim verification you did not execute. Paste real command output as evidence.
- No paid services, no API keys needed to build/test. Only localhost Ollama.
- No secrets leave the machine. The extension must never send scanned content anywhere except the browsed site's origins and localhost Ollama.

## 8. Acceptance matrix (final report must include this table, each row PASS/FAIL + one-line evidence)

| ID | Criterion |
|---|---|
| KS-1 | Loads unpacked in Chrome, no manifest errors, no console errors on normal pages |
| KS-2 | Leaky fixture: ALL planted secrets detected, correct category + severity, values redacted in UI |
| KS-3 | Clean fixture: zero false positives (Info-level with valid justification acceptable) |
| KS-4 | Deep fetch: secret in external `app.js` AND in `app.js.map` `sourcesContent` found automatically |
| KS-5 | Crawl: navigating to the fixture's 2nd page surfaces its asset secrets in background; dedupe verified |
| KS-6 | Ollama ON: deep check runs, verdicts appear tagged `llm: confirmed/cleared`; Ollama OFF: graceful notice, regex scanning unaffected |
| KS-7 | Master toggle: disabled = zero scanning/network/badge activity; state persists across restarts |
| KS-8 | Popup UX: per-tab + all-sites views, severity badges, expand/copy/ignore/export all functional |
| KS-9 | Options: category toggles, custom regex, Ollama URL/model/test, ignore rules all persist and take effect |
| KS-10 | Unit tests green on a fresh clone (`node --test`); build from scratch succeeds |
| KS-11 | README: install, permissions explained, privacy model, limitations, authorized-use disclaimer |

End your run with: the filled acceptance matrix, the exact commands to build/test/load, and a 5-line "what I would improve next" note. Do not stop early — a passing matrix is the deliverable, not the code.
