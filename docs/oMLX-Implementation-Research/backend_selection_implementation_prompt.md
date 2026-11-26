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
- This brief's **§8 (M5 research findings)** and **§9 (references)** — the
  verified oMLX M5 story (NAX kernels, ANE split tuner, GPU power cap, macOS
  gate) and every source URL. Treat §8/§9 as the ground truth for the M5 work.

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
2. **One codebase, two launch paths — no duplicated code.** Backend is a
   setting, not a fork, and shared logic is implemented once: process-tree
   stop/exit confirmation, health polling, client-config writing, the memory
   guard, and port checks are parameterized per backend — never a copy-pasted
   second server controller. A refactor to make sharing possible IS allowed,
   but only with a written analysis first (what is duplicated, why the current
   shape blocks sharing, the exact blast radius, and what behavior must stay
   byte-identical) — never a refactor for its own sake.
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
- App: `enum Backend: String, CaseIterable { case mlx, omlx, omlxM5 }`.
  Resolution: `Backend(rawValue: stored) ?? .mlx`, plus two downgrade guards:
  - `omlxM5` stored on a non-M5 Mac → resolve to `.omlx` (silent downgrade,
    never an error).
  - `omlxM5` on macOS < 26.2 → resolve to `.omlx` (the M5 Neural-Accelerator
    path needs macOS 26.2+; see §8).
- CLI: the string `mlx`, `omlx`, or `omlx-m5`; anything else → `mlx`; the
  same two downgrade guards apply before dispatch.

### 4.2 Persistence
- App: UserDefaults key `mlxServerBackend` (new entry in `Keys`), written by a
  `@Published var backend` `didSet` — same pattern as `selectedModel`/`port`.
- CLI: state file `~/.config/mac-mlx-agent/backend` containing one word
  (`mlx`/`omlx`). Written only on explicit selection; missing/invalid → `mlx`.

### 4.3 Controls
- App: `Picker("Backend", selection: $server.backend)` at the top of the model
  section — `"MLX (default)"`, `"oMLX"`, and `"oMLX (M5 optimized)"`.
  - The M5 entry is rendered **only when M5 is detected** (see §4.8); on
    other Macs the picker shows MLX + oMLX only.
  - Disabled while `!canSwitchBackend` (running/transitioning). When the
    oMLX runtime is unavailable, the oMLX entries are disabled with a
    one-line hint instead of silently failing; when M5 is detected but macOS
    < 26.2 or the custom kernels are missing, the M5 entry is disabled with
    the reason.
- CLI: `./setup.sh --backend omlx|omlx-m5` (opt-in runtime install + persist)
  and `./start_server.sh --backend omlx|omlx-m5` (persist after a successful
  start). No flag → today's behavior exactly, MLX.

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
  runtime when present. **Reuse the existing helpers instead of duplicating
  them** — the process-tree/exit-confirmation loop, the health-poll task, the
  port-conflict sweep, and the config writers are shared between backends
  (hard constraint 2). The M5 variant is a **launch profile** on this same
  controller (env + post-start settings), never a second controller.
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
- `setup.sh`: `--backend omlx|omlx-m5` → `install_omlx()` creating a
  repo-local `.venv-omlx` (mirror `install_litellm()`; for M5 mode prefer the
  custom-kernel build — full Xcode — or the official DMG, which ships the
  kernels precompiled), then write the state file; `check_status()` gains the
  oMLX runtime + custom-kernel lines; `configure_agents()` writes the
  OpenCode port for the active backend.
- `start_server.sh`: read the state file; `mlx` → existing `mlx_lm.server`
  exec path untouched; `omlx` / `omlx-m5` → exec the oMLX venv python with
  `-m omlx.cli serve` + env isolation (see §4.8 for the M5 env profile),
  curl-poll the catalog once, and only then persist the `--backend` choice.
  Before dispatching `omlx-m5`: verify the chip (`sysctl -n
  machdep.cpu.brand_string` must match `Apple M5`…) and macOS ≥ 26.2 — on
  mismatch, print a warning and run plain `omlx`, never writing `omlx-m5`
  into the state file.
- `claude-local.sh`: unchanged (the bridge follows the active backend via the
  config written at start).

### 4.8 M5-optimized oMLX (the `omlx-m5` profile)
Same `OMLXBackendController`, one extra launch profile — never a copy.

**Chip detection (verified):**
- Swift: `sysctlbyname("machdep.cpu.brand_string")` → `"Apple M5 …"` /
  `"Apple M5 Pro/Max/Ultra …"`; match the prefix `Apple M5` with a word
  boundary. Once the server is up, `GET /admin/api/device-info` (chip, GPU
  cores, memory) is the authoritative check.
- bash: `sysctl -n machdep.cpu.brand_string | grep -Eq '^Apple M5([[:space:]]|$)'`.
- macOS gate: NA acceleration in MLX needs macOS ≥ 26.2 (Apple, §9). Swift:
  `ProcessInfo.processInfo.operatingSystemVersion`; bash:
  `sw_vers -productVersion`.

**The profile differs from plain `omlx` in three ways:**
1. **NAX kernels on.** Plain `omlx` runs the GPU-only baseline and sets the
   NAX kill switch (`OMLX_QWEN35_QMM_NAX=0`) for a deterministic cross-chip
   baseline; the M5 profile leaves it unset. If the custom kernels or the NAX
   metallib are unavailable, oMLX falls back to the Metal path automatically
   (upstream behavior) — surface that as a warning, not an error. Kernel
   availability check (from the oMLX README):
   `python -c "from omlx.custom_kernels import native_kernel_status; print(native_kernel_status())"`.
2. **ANE/GPU prefill split (experimental, opt-in).** Off by default. When the
   user enables it, apply per model via the admin API
   (`PUT /admin/api/models/{model_id}/settings`; run the tuner through
   `/admin/api/bench/ane-tune/…` or the built-in tuner). It needs the native
   custom kernels and uses private Apple runtime interfaces — label it
   experimental in the UI, never enable it implicitly.
3. **GPU power cap (optional, M5).** Surface oMLX's GPU power-limit setting —
   it writes the AGX GPU power target (`SetMaxGPUAbsolutePower` +
   `AbsoluteTarget` mW; `-1000` removes; `0` parks the GPU at its frequency
   floor and must be refused). Root required, undocumented driver interface,
   tested on macOS 26.5 only (m5gpu, §9). The UI must warn about all three.

**Degradation ladder:** oMLX runtime unavailable → both oMLX entries
disabled, MLX untouched (constraint 5). Kernels/NAX missing on M5 → M5 entry
runs with a warning (Metal fallback is automatic). Non-M5 or macOS < 26.2 →
M5 entry hidden; a persisted `omlx-m5` resolves to `omlx`.

## 5. Execution protocol (Claude Code technique)

1. **Plan first.** Write a short plan to
   `docs/oMLX-Implementation-Research/PLAN.md` and track progress with
   TodoWrite using the phases below.
2. **grep before edit.** `rg` each symbol, read the surrounding region, then
   patch minimally. Never trust remembered line numbers.
3. **Deduplication analysis before any refactor.** If sharing a lifecycle
   primitive across backends forces touching existing code, first write the
   analysis in `PLAN.md`: the duplication inventory, why the current shape
   blocks sharing, the blast radius, and the behavior-preservation plan.
   Refactors happen only with that written justification — never for style.
4. **Implement in phases; build after each phase; commit per phase.**
   - **A — Foundation (app):** `Backend` enum (incl. `omlxM5`), `Keys.backend`,
     init resolution + M5 downgrade guards, `canSwitchBackend`, picker UI,
     runtime probe, chip detection (`machdep.cpu.brand_string`) + macOS gate.
   - **B — Lifecycle (app):** `OMLXBackendController`, `switchBackend(to:)`
     with confirmed-exit + rollback, health polling, quit-path stop, the
     `omlx-m5` launch profile (§4.8).
   - **C — Clients (app):** OpenCode + bridge configs follow the active
     backend (incl. apiKey), portMismatch checks.
   - **D — CLI:** `setup.sh` / `start_server.sh` backend flag + state file +
     `.venv-omlx` install + dispatch.
   - **E — Docs:** README "Backends" subsection, CHANGELOG entry.
5. **Build gates (run after A/B/C):**
   ```bash
   cd MLXServer && xcodebuild -project MLXServer.xcodeproj -scheme MLXServer \
     -configuration Debug build   # zero errors
   bash -n setup.sh start_server.sh claude-local.sh
   ```
6. **No fabricated output.** Every verification result below must come from
   real command output, pasted into the report.

## 6. Definition of Done — the 7 scenarios (all must pass)

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
7. **M5 gating (on an M5 Mac and on a non-M5 Mac).** M5: the picker shows all
   three entries; selecting "oMLX (M5 optimized)" starts oMLX with NAX on
   (launch env carries no `OMLX_QWEN35_QMM_NAX=0`) and the selection survives
   relaunch; plain "oMLX" launches with the kill switch set. Non-M5 (or M5 on
   macOS < 26.2): the M5 entry is absent/hidden, and a state file or
   UserDefaults value of `omlx-m5` resolves to `omlx` — verify against the
   real `sysctl -n machdep.cpu.brand_string` output on each machine.

## 7. Commit & release hygiene

- Branch `feat/omlx-backend-selection` off `main`; atomic commits per surface
  (`feat(app): …`, `feat(cli): …`, `docs: …`).
- **No AI attribution, no `Co-Authored-By`** — repo hard rule.
- `CHANGELOG.md`: document the feature under the next version heading,
  following the repo's existing release pattern.
- `README.md`: add a "Backends" subsection; do **not** touch the model table,
  the one-line installer, or the Gatekeeper instructions.
- Final state: `git status` clean, build passing, all 7 verification items
  recorded with real output.

## 8. M5 research findings (verified, Nov 2026)

**What M5 changes.** The M5 GPU adds per-core **Neural Accelerators (NA)** —
dedicated matrix-multiplication units exposed to MLX through Metal 4 TensorOps
/ Metal Performance Primitives. Apple measured 3.3–4.1× faster TTFT vs M4 and
19–27% faster decode (memory bandwidth 120 → 153 GB/s). MLX takes the NA path
only on **macOS ≥ 26.2** (source: Apple ML research, §9). oMLX supports
M1–M5; the non-M5 path is unaffected by all of this.

**What oMLX does for M5 specifically:**
- **NAX kernels** (since 0.6.2): dedicated NAX QMM suffix kernels for
  Qwen3.5/3.6/3.8 quantized layers on M5-family; automatic Metal fallback when
  unavailable; kill switch `OMLX_QWEN35_QMM_NAX=0`. 0.7.0 added more M5 paths:
  QSA attention on M5 tensor units, segmented NAX tile scheduling for MoE,
  4096/8192-token prefill chunks on M5 GPUs, exact fused decode + MTP-verify
  kernels on M5 GPUs, JIT NAX attention kernels.
- **ANE/GPU split tuner** (since 0.6.2): benchmarks GPU-only vs MLP/GDN splits
  directly on the local Mac; the earlier blanket M5 ANE disable was removed.
  ANE prefill stays experimental, opt-in per model, needs the native custom
  kernels, and uses private Apple runtime interfaces. Community M5 testing:
  ~5% gain, best tuner trial ~1,000 prefill tok/s; the tuner recommends
  GPU-only when the ANE candidate is <1% faster.
- **GPU power cap**: writes the AGX GPU power target (m5gpu method:
  `SetMaxGPUAbsolutePower` + `AbsoluteTarget` mW via `IORegistryEntrySetCFProperties`
  on the `AGXAccelerator` node; `-1000` removes; `0` parks the GPU at its
  338 MHz floor and must be refused). Undocumented, root required, tested on
  macOS 26.5 only. M5 Max reference curve: ~107 GFLOPS/W at 5 W → ~29 GFLOPS/W
  uncapped (~96.6 W).
- **Custom kernels are load-bearing for the fast paths.** NAX/ANE and the
  GLM-5.2 / MiniMax M3 / Qwen3.5 fast paths need the native custom kernels
  (full-Xcode build, `xcodebuild -downloadComponent MetalToolchain`, or the
  official DMG which ships them precompiled). oMLX runs on M1–M5 via generic
  paths when kernels are absent. Verify with `native_kernel_status()`.
- **Version churn is real:** M5-specific regressions appear and get fixed fast
  (e.g. #5685: 0.8.4 GLM-5.3-Flash ~2× slower MTP draft on M5 Ultra). Pin the
  oMLX version the app installs (latest at research time: 0.8.4) and
  smoke-test it on M5 before shipping; do not assume M5 speed claims.
- **Server-side chip truth:** `GET /admin/api/device-info` (chip, GPU cores,
  memory) — authoritative for the runtime probe and the active-profile label.

**Community-verified M5 Max settings** (ricky8848/mac-m5-128g-omlx-settings,
MIT): `~/.omlx/settings.json` with `sampling.max_context_window: 128000`,
`memory.prefill_memory_guard` + tier + ceiling,
`scheduler.max_concurrent_requests: 1`, SSD + hot KV cache caps; measured
~12 tok/s at 30k-token prompts on M5 Max 128 GB. Also see discussion #3599
(oQ4e + MTP + TurboQuant KV combo, 85–96% MTP accept, <3 s warm TTFT).

## 9. References (hand these to the dev team)

Upstream oMLX:
- Repo: https://github.com/jundot/omlx
- README (M1–M5 support, macOS 15+, Python 3.11–3.13, `omlx start` / `omlx serve`, custom-kernel + `native_kernel_status()` instructions, m5gpu acknowledgment): https://github.com/jundot/omlx#readme-ov-file
- v0.6.2 release notes (NAX kernels, ANE/GPU split tuner, blanket M5 ANE disable removed, `OMLX_QWEN35_QMM_NAX=0`, Metal fallback, ~5% / ~1,000 tok/s M5 numbers, per-model opt-in): https://github.com/jundot/omlx/releases/tag/v0.6.2
- v0.7.0 release notes (M5 tensor-unit QSA, NAX tile scheduling, M5 prefill chunks, exact fused decode/MTP-verify on M5, rebuilt memory-guard tiers): https://github.com/jundot/omlx/releases/tag/v0.7.0
- Admin API (device-info, global-settings, per-model settings/acceleration, ane-tune benchmarks, headless mode): https://github.com/jundot/omlx/blob/main/docs/admin-api.md
- Custom kernels doc: https://github.com/jundot/omlx/blob/main/docs/custom-kernels.md
- M5 Ultra regression example (version-churn caution): https://github.com/jundot/omlx/issues/5685
- Latest release (pin target): https://github.com/jundot/omlx/releases

Apple / MLX:
- Apple ML research — "Exploring LLMs with MLX and the Neural Accelerators in the M5 GPU" (NA concept, Metal 4 TensorOps, macOS 26.2 gate, M4-vs-M5 tables): https://machinelearning.apple.com/research/exploring-llms-mlx-m5
- MLX: https://github.com/ml-explore/mlx · mlx-lm: https://github.com/ml-explore/mlx-lm

M5 GPU power:
- m5gpu (AGX power-target method, 0/-1000 semantics, sudoers pattern, M5 Max measurement table, cautions): https://github.com/beamivalice/m5gpu

Community M5 configs:
- M5 Max 128 GB oMLX settings + DSH (settings keys, guard tiers, measured throughput): https://github.com/ricky8848/mac-m5-128g-omlx-settings
- Discussion #3599 (M5 Max oQ4e + MTP + TurboQuant KV summary): https://github.com/jundot/omlx/discussions/3599

Local research artifacts (this repo):
- `docs/oMLX-Implementation-Research/omlx_backend_integration_example.py` — controller reference
- `docs/oMLX-Implementation-Research/backend_selection_implementation_prompt.md` — this brief
