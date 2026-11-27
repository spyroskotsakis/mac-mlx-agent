# oMLX Backend Selection — Implementation Plan

Branch: `feat/omlx-backend-selection`. Phases A–E, build after each, commit per phase.
No merge to `main` until final QA.

## Deduplication analysis (required before any refactor)

**Duplication inventory (current):** none — there is a single `ServerController` and the
oMLX path does not exist yet. The risk is creating a *second* controller for oMLX.

**Why the current shape could block sharing:** `start()` / `stop()` / `beginHealthPoll()` /
`isServerUp()` / the config writers are hard-wired to `port` (8080) and the MLX launch
command, with no notion of a backend.

**Blast radius:** `start()`, `stop()`, `stopSynchronouslyForQuit()`, `killAllServers()`,
`isServerUp()`, `beginHealthPoll()`, the config writers (`mlxProviderConfigV1/V2`,
`litellmConfigText`, `checkOpenCodeConfig`), and `ContentView` (picker). All are additive or
one-line parameterizations — no behavior changes when backend == `.mlx`.

**Behavior-preservation plan (how sharing is achieved without a fork):**
- A `Backend` enum drives two computed values the rest of the code already uses:
  `activePort` (8080 for MLX, 8000 for oMLX) and `launchCommand` (MLX args vs oMLX args).
- `start()` keeps its existing flow and simply swaps the command + port by backend; the
  `Process` / termination handler / health poll stay single.
- `isServerUp()` polls `activePort` and adds the `Authorization: Bearer` header only for
  oMLX — same task, one parameterized function.
- Config writers replace `port` with `activePort` and add the oMLX `apiKey` only when the
  backend requires it.
- No second controller class. `switchBackend(to:)` reuses `stop()`/`start()` plus the
  existing `processTreePIDs` + `kill(pid, 0)` confirmed-exit loop from
  `stopSynchronouslyForQuit()`.

## Phases

- **A — Foundation:** `Backend` enum (`mlx`/`omlx`/`omlxM5`), `Keys.backend`, init
  resolution + M5 downgrade guards, `canSwitchBackend`, `omlxRuntimeAvailable` probe,
  chip detection (`machdep.cpu.brand_string`) + macOS ≥ 26.2 gate, picker UI.
- **B — Lifecycle:** parameterize `start()`/`stop()`/`isServerUp()`/`beginHealthPoll()` by
  backend, oMLX launch command (`omlx.cli serve …`), API-key persistence, `switchBackend(to:)`
  with confirmed-exit + rollback, M5 launch profile, quit-path stop, `killAllServers` sweep.
- **C — Clients:** OpenCode + bridge configs follow `activePort` (+ apiKey for oMLX);
  `checkOpenCodeConfig` portMismatch uses the active port.
- **D — CLI:** `setup.sh` `--backend` + `.venv-omlx` + state file; `start_server.sh`
  backend dispatch + M5 gate + persist-after-health.
- **E — Docs:** README "Backends" subsection, CHANGELOG entry.

## Progress

- [x] A — Foundation
- [x] B — Lifecycle
- [x] C — Clients
- [x] D — CLI
- [x] E — Docs
