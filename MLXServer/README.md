# MLX Server (menu bar app)

A small native macOS **menu-bar app** that starts and stops the local
`mlx_lm.server` for the **Qwen3.5-35B-A3B** model, so you don't have to run
`./start_server.sh` by hand. It lives in the menu bar, next to the clock.

## What it does

- **Start / Stop** the MLX-LM server (OpenAI-compatible,
  `http://127.0.0.1:8080/v1`).
- **Pick the model** (one now — Qwen3.5-35B-A3B — with a single place to add more).
- Shows a **live log** of the server (model load progress, requests, errors).
- Lets you override the **port** and the **`mlx_lm.server` path** under *Advanced*.

The server arguments mirror `start_server.sh` exactly:

```
--model <model> --host 127.0.0.1 --port <port> \
  --kv-bits 4 --max-tokens 8192 --temp 0.2 --top-p 0.8 --top-k 20
```

## Requirements check

The panel shows a **Requirements** list and verifies the two things the server
needs, with one-click fixes when something is missing:

- **mlx-lm (`mlx_lm.server`)** — if the binary isn't found, click **Install** to
  run `python -m pip install --upgrade mlx-lm uvicorn fastapi` into the detected
  Python environment (the same one the `mlx_lm.server` shebang points at).
- **Model files** — checks the local HuggingFace cache for the selected model's
  weights; click **Download** to fetch them with `hf download <repo-id>`. (You
  can also just press Start — the server auto-downloads on first launch.)

The checks run when you open the panel and whenever you switch models.

## Build & run

Open `MLXServer.xcodeproj` in Xcode and press **Run**, or build from the terminal:

```bash
xcodebuild -project MLXServer.xcodeproj -target MLXServer -configuration Debug build
```

The app runs as a **menu bar extra** (no Dock icon — `LSUIElement`). Click its
icon (a circle) next to the clock to open the control panel. The icon shape
tracks the server state:

| Icon | State |
|------|-------|
| `○` circle | stopped |
| `◌` circle.dotted | starting / stopping |
| `●` circle.fill | running |
| `!` exclamationmark.circle | failed |

## Quitting

Because it's a menu-bar-only app (no Dock icon or menu bar), you quit it from
inside the panel:

- Click **Quit MLX Server** at the bottom of the panel, or
- press **⌘Q**.

Quitting first stops the model server (SIGTERM, then SIGKILL if it lingers) so
you never leave an orphaned `mlx_lm.server` holding port 8080.

## How it finds `mlx_lm.server`

GUI apps don't inherit your shell `PATH`, so the app auto-detects the binary by
checking common install locations (`/opt/anaconda3/bin/mlx_lm.server`,
`/opt/homebrew/bin/…`, `~/miniconda3/bin/…`, …) and falls back to asking your
login shell (`zsh -ic "command -v mlx_lm.server"`). If it still can't find it,
paste the full path into **Advanced → mlx_lm.server path** (blank = auto-detect).

## Adding more models later

Edit `ServerController.availableModels` in `MLXServer/ServerController.swift`:

```swift
static let availableModels: [ModelOption] = [
    ModelOption(repoID: "mlx-community/Qwen3.5-35B-A3B-4bit",
                displayName: "Qwen3.5-35B-A3B (4-bit)"),
    ModelOption(repoID: "mlx-community/Your-New-Model-4bit",
                displayName: "Your New Model (4-bit)"),
]
```

Download the model first (the server also auto-downloads on first launch). The
selected model is remembered across launches.

> Only use a model whose tool-call format `mlx_lm.server` can actually parse.
> See the main repo `README.md` — Qwen3-Coder-30B and Qwen2.5-Coder-14B emit
> the wrong wrapper and stall the agent loop.
