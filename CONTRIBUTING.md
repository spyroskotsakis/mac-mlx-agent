# Contributing

Thanks for looking at MLX Server — a macOS menu-bar app that runs local MLX models
behind an OpenAI-compatible API, plus shell scripts that do the same from a terminal.

## Build the app from source

Open `MLXServer/MLXServer.xcodeproj` in Xcode and run the `MLXServer` scheme, or:

```bash
xcodebuild -project MLXServer/MLXServer.xcodeproj -scheme MLXServer \
  -configuration Release -destination 'platform=macOS' build
```

Core logic is in `MLXServer/MLXServer/ServerController.swift` (subprocesses, model
list, settings, memory guard); the UI is in `ContentView.swift`.

## Run the terminal path

```bash
./start_server.sh          # mlx_lm.server on 127.0.0.1:8080
```

For the Claude Code bridge, start LiteLLM alongside it, then launch Claude:

```bash
.venv-litellm/bin/litellm --config litellm-mlx.yaml --host 127.0.0.1 --port 4001
./claude-local.sh
```

## Python environments

`mlx-lm` and `litellm` live in **separate** virtualenvs on purpose: LiteLLM pins
`tokenizers==0.22.2`, while mlx-lm's transformers needs `>=0.23.1`. Don't merge them.

## Submitting a change

1. Branch off `main` (`git switch -c my-fix`).
2. Keep the memory-safety guard, KV-cache flags, and ports from `CLAUDE.md` intact.
3. Add an entry to `CHANGELOG.md`.
4. Open a PR against `main` describing what changed and why.

There's no automated test suite — verify by building the app and running the server
or agent path you touched, and note what you checked in the PR.
