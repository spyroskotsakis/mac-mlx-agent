# Implementation Brief — MLX ↔ oMLX Backend Selection (Backward-Compatible)

Hand this file to the implementing agent (Claude Code / Hermes worker). It is
self-contained, but the agent MUST also read `CLAUDE.md` and `AGENTS.md` in the
repo root first and treat every invariant there as binding.

## Mission

Add an opt-in second inference backend (**oMLX**) next to the existing **MLX**
backend, in **both** the macOS menu-bar app and the terminal/CLI path, without
changing any current default behavior. MLX stays the default everywhere;
oMLX starts only after the user explicitly selects it, and the user can switch
back with the same control.

## 1. Read first (context loading)

- `CLAUDE.md` — the 4-layer architecture, the model/classification system, and
  the critical invariants: memory-safety guard, ports 8080/4001, KV-cache &
  sampling defaults, LiteLLM venv pinning, OpenCode `limit.output`, the release
  Gatekeeper/installer rules, and **no AI-attribution anywhere**.
- `AGENTS.md` — the hard rules (MLX-compatible models only, classification
  mirroring, memory guard).
- `docs/oMLX-Implementation-Research/omlx_backend_integration_example.py` — the
  canonical oMLX process controller (stdlib-only Python). Study its lifecycle:
  `OMLXServer.start/stop`, readiness = `GET /v1/models` with an
  `Authorization: Bearer` key, default port **8000**, `OMLX_*`/`PYTHON*` env
  stripping, per-start API key. This is the design reference for the oMLX path —
  port its logic into Swift for the app; keep it as the CLI reference.

## 2. Code map (exact hooks — touch only these)

`MLXServer/MLXServer/ServerController.swift`
- `ServerState` — `stopped / starting / running / stopping / failed(String)`.
- `enum Keys` — UserDefaults keys (`mlxServerModel`, `mlxServerPort`, …).
- `init()` — settings load with fallbacks (the resolution pattern to copy).
- `canSwitchModel` — disabled while running/transitioning (the guard pattern).
- Memory guard: `physicalRAMGB`, `concurrentRequestsSafe`,
  `memorySafetyBlock()`, `clampConcurrentRequestsForSelectedModel()`.
- `start()` — `killAllServers()` → `checkPortConflicts()` → memory block →
  `modelIsCached` → `arguments(model:port:)` → `Process` launch (MLX exe vs
  OptiQ `python -c` path) → `beginHealthPoll()` → `startBridge()`.
- `stop()` — SIGTERM to the process tree, SIGKILL escalation after 5 s.
  `stopSynchronouslyForQuit()` — the confirmed-exit poll loop to reuse.
- `handleTermination(of:)` — state transitions on process exit.
- `beginHealthPoll()` / `isServerUp()` — readiness polling pattern.
- `writeOpenCodeConfig()` / `autoSyncOpenCodeConfig()` /
  `OpenCodeConfigStatus` — client-config writers.
- Process helpers: `processTreePIDs`, `childPIDs`, `signal`,
  `killListeners(on:)`, `runTool`.
- Published health flags `mlxLMHealthy`, `optiqHealthy` — the pattern for
  `omlxHealthy` / `omlxRuntimeAvailable`.

`MLXServer/MLXServer/ContentView.swift` — `modelSection` (Picker ~line 1210,
`.disabled(!server.canSwitchModel …)`), `modelSettingsSection`.

`setup.sh` — `check_status()`, `install_litellm()` (the isolated-venv pattern),
`configure_agents()` (writes `opencode.jsonc` with the port), `pick_model()`,
`print_next_steps()`.

`start_server.sh` — flag assembly, per-model gates (THINKING/ROTATING/MISTRAL/
OPTIQ), the exec dispatch at the bottom.

`claude-local.sh` / `litellm-mlx.yaml` — the bridge; only the config the bridge
is started with may follow the active backend.

## 3. Hard constraints

1. **Additive only.** No unrelated refactors, renames, or reformatting. With
   oMLX not selected, every existing behavior must stay exactly as today.
2. **One codebase, two launch paths.** Backend is a setting, not a fork.
3. **MLX is the default.** Missing or invalid preference → MLX, silently, on
   both surfaces (fresh installs *and* upgrades).
4. **One backend at a time.** Never run both servers simultaneously.
5. **oMLX is isolated.** Own runtime (venv / embedded), own env (`OMLX_*`),
   own state dir, own port (8000), own settings keys. An unavailable oMLX
   runtime must leave the MLX workflow 100% usable — the oMLX choice is
   disabled with a one-line reason, never an error blocking MLX.
6. **Repo invariants stay intact.** Memory guard on both paths; ports 8080/4001
   unchanged; KV/sampling defaults unchanged; LiteLLM venv pinning unchanged;
   OpenCode `limit.output` matches the server's max tokens; release
   xattr/install.sh rules untouched; **no AI attribution anywhere, including
   commit messages**.
7. **No new models.** The model list and classification stay exactly as-is.
   OptiQ models remain MLX-runtime-only until verified on oMLX — when
   backend == omlx, disable them in the picker with a caption (the picker
   must never lie).

## 4. Design contract (exact semantics)

### 4.1 Backend type & default resolution
- App: `enum Backend: String, CaseIterable { case mlx, omlx }`.
  Resolution: `Backend(rawValue: stored) ?? .mlx`.
- CLI: the string `mlx` or `omlx`; anything else → `mlx`.

### 4.2 Persistence
- App: UserDefaults key `mlxServerBackend` (new entry in `Keys`), written by a
  `@Published var backend` `didSet` — same pattern as `selectedModel`/`port`.
- CLI: state file `~/.config/mac-mlx-agent/backend` containing one word
  (`mlx`/`omlx`). Written only on explicit selection; missing/invalid → `mlx`.

### 4.3 Controls
- App: `Picker("Backend", selection: $server.backend)` at the top of the model
  section — `"MLX (default)"` and `"oMLX"`. Disabled while
  `!canSwitchBackend` (running/transitioning) and, when the oMLX runtime is
  unavailable, disabled with a hint instead of silently failing.
- CLI: `./setup.sh --backend omlx` (opt-in runtime install + persist) and
  `./start_server.sh --backend omlx` (persist after a successful start).
  No flag → today's behavior exactly, MLX.

### 4.4 Switch protocol — `switchBackend(to:)` (app)
1. Guard: not transitioning; oMLX runtime present when target == omlx.
2. If the current backend is running: stop it, then **confirm exit** — poll the
   process tree (`processTreePIDs` + `kill(pid, 0)`, same loop style as
   `stopSynchronouslyForQuit`) until every PID is gone or a 5 s timeout, then
   SIGKILL survivors. Never start the new backend before exit is confirmed.
3. Start the target backend.
4. **Failure handling (oMLX cannot start):** surface the error (`.failed(...)`
   + log), restore `backend` to the previous value (didSet re-persists), and
   restart the previous backend **if it was running**. If that recovery restart
   also fails: show **both** errors, state `.failed`, server stays stopped —
   and the picker must still offer an obvious path back to MLX.
5. Selection persistence follows `didSet`; rollback rewrites the old value.
- CLI equivalent: if oMLX fails its health check, print the error and
  `Backend remains mlx`; do **not** write the state file.

### 4.5 Ports & clients
- MLX = 8080 (unchanged), LiteLLM bridge = 4001 (unchanged), oMLX = **8000**.
- OpenCode config (`writeOpenCodeConfig` / `autoSyncOpenCodeConfig`) and the
  bridge config must target the **active** backend's port; for oMLX the
  generated provider entry carries the `apiKey` header (see 4.6).
  `checkOpenCodeConfig()` portMismatch logic uses the active port. Switching
  back rewrites the configs for 8080 exactly as today.

### 4.6 oMLX launch path
- Port the research controller into an `OMLXBackendController` (stdlib-only,
  same lifecycle as `OMLXServer`): `omlx.cli serve --headless --port 8000
  --model-dir … --paged-ssd-cache-max-size 20GB`, launched from the managed
  Python (an Advanced-path setting, like `executablePath`) or an embedded
  runtime when present.
- Env isolation: strip inherited `OMLX_*` / `PYTHON*` vars; set
  `OMLX_BASE_PATH` to the oMLX state dir
  (`~/Library/Application Support/MLXServer/omlx/`).
- API key: generate once, persist to `<state-dir>/api_key` (0600), **reuse
  across starts** so client configs stay valid; regenerate only if missing.
- Readiness: poll `GET http://127.0.0.1:8000/v1/models` with the Bearer header
  (mirror `beginHealthPoll`).
- Memory guard and model-cached checks apply on this path too.
- Runtime availability probe (app startup + `setup.sh check_status()`):
  launcher/venv present → `omlxRuntimeAvailable`, shown as a Requirements line
  exactly like `mlx-optiq (OptiQ runtime)`.

### 4.7 CLI specifics
- `setup.sh`: `--backend omlx` → `install_omlx()` creating a repo-local
  `.venv-omlx` (mirror `install_litellm()`), then write the state file;
  `check_status()` gains the oMLX runtime line; `configure_agents()` writes
  the OpenCode port for the active backend.
- `start_server.sh`: read the state file; `mlx` → existing `mlx_lm.server`
  exec path untouched; `omlx` → exec the oMLX venv python with
  `-m omlx.cli serve` + env isolation, curl-poll the catalog once, and only
  then persist the `--backend` choice.
- `claude-local.sh`: unchanged (the bridge follows the active backend via the
  config written at start).

## 5. Execution protocol (Claude Code technique)

1. **Plan first.** Write a short plan to
   `docs/oMLX-Implementation-Research/PLAN.md` and track progress with
   TodoWrite using the phases below.
2. **grep before edit.** `rg` each symbol, read the surrounding region, then
   patch minimally. Never trust remembered line numbers.
3. **Implement in phases; build after each phase; commit per phase.**
   - **A — Foundation (app):** `Backend` enum, `Keys.backend`, init
     resolution, `canSwitchBackend`, picker UI, runtime probe.
   - **B — Lifecycle (app):** `OMLXBackendController`, `switchBackend(to:)`
     with confirmed-exit + rollback, health polling, quit-path stop.
   - **C — Clients (app):** OpenCode + bridge configs follow the active
     backend (incl. apiKey), portMismatch checks.
   - **D — CLI:** `setup.sh` / `start_server.sh` backend flag + state file +
     `.venv-omlx` install + dispatch.
   - **E — Docs:** README "Backends" subsection, CHANGELOG entry.
4. **Build gates (run after A/B/C):**
   ```bash
   cd MLXServer && xcodebuild -project MLXServer.xcodeproj -scheme MLXServer \
     -configuration Debug build   # zero errors
   bash -n setup.sh start_server.sh claude-local.sh
   ```
5. **No fabricated output.** Every verification result below must come from
   real command output, pasted into the report.

## 6. Definition of Done — the 5 scenarios (all must pass)

1. **Fresh install starts with MLX selected.** App: no `mlxServerBackend` in
   defaults → picker shows MLX. CLI: no state file → `./start_server.sh`
   prints the MLX launch line.
2. **Existing config without a backend key keeps today's MLX behavior.**
   Snapshot `defaults read` + `~/.config/opencode/opencode.jsonc` before
   upgrade; afterwards: same model, port 8080, OpenCode config unchanged,
   bridge behaves as before.
3. **Explicit oMLX selection starts it and survives relaunch.** Switch →
   `curl -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/v1/models`
   returns 200 + catalog; quit and relaunch the app → picker still oMLX.
   CLI: `--backend omlx` → state file contains `omlx` after a successful
   health check.
4. **Switching back restores the MLX workflow.** Pick MLX → oMLX process gone
   (`lsof -nP -iTCP:8000 -sTCP:LISTEN` empty), MLX healthy on 8080
   (`curl http://127.0.0.1:8080/v1/models` → 200), OpenCode config back to
   8080, bridge up.
5. **A failed oMLX startup preserves a usable path back to MLX.** Make the
   runtime unavailable (rename `.venv-omlx` / break the launcher path) →
   attempt the switch: the error is surfaced, the selection reverts to MLX,
   and a previously-running MLX server auto-restarts and is healthy. Then
   break MLX too and repeat: **both** errors are shown, the server stays
   stopped, and the picker still offers the path back.
6. **Fresh-clone audit.** Clone the pushed branch into `/tmp`, build, and run
   scenarios 1 and 5 end-to-end with no assumptions. Parallelize scenarios
   1–5 across headless `claude -p` subagents, each returning its own real
   command output; the orchestrator merges the results.

## 7. Commit & release hygiene

- Branch `feat/omlx-backend-selection` off `main`; atomic commits per surface
  (`feat(app): …`, `feat(cli): …`, `docs: …`).
- **No AI attribution, no `Co-Authored-By`** — repo hard rule.
- `CHANGELOG.md`: document the feature under the next version heading,
  following the repo's existing release pattern.
- `README.md`: add a "Backends" subsection; do **not** touch the model table,
  the one-line installer, or the Gatekeeper instructions.
- Final state: `git status` clean, build passing, all 6 verification items
  recorded with real output.
