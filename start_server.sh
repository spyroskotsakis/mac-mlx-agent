#!/usr/bin/env bash
# Start the local MLX-LM server (OpenAI-compatible) on port 8080.
# Usage: ./start_server.sh [model]
set -euo pipefail

# Default is the Qwen3.5-35B-A3B MoE, chosen for its reliable OpenCode/Xcode
# agent loop. It emits the `<tool_call>\n<function=…>` XML tool
# format that mlx_lm.server's qwen3_coder parser is built for, and its chat
# template carries an explicit "<IMPORTANT>: MUST be nested within <tool_call>"
# reminder, so structured tool calls come out reliably.
#
# The two models we tried first are NOT reliable under OpenCode's long ~20-tool
# prompt and were removed from cache: Qwen3-Coder-30B-A3B drops the <tool_call>
# wrapper, and Qwen2.5-Coder-14B wraps its call in <tools> instead of
# <tool_call> — both come back as plain text and stall the agent loop. Don't
# switch back to either one for agentic use.
MODEL="${1:-mlx-community/Qwen3.5-35B-A3B-4bit}"
PORT="${PORT:-8080}"

# The server ships the same models as the menu-bar app (MLXServer/) and the
# `./setup.sh` picker — 15 total. Pass any of their ids to `./start_server.sh <id>`.
# The server reads each model's own max context from its config, so no context
# flag is needed here. Only the client needs the matching per-model value
# (OpenCode's `limit.context`) — setup.sh / the app writes that for you; set it by
# hand only if you configure OpenCode without them. Thinking mode applies only to
# the Qwen3 family (see THINKING_MODELS below).

echo "Starting MLX-LM server for: $MODEL"
echo "Listening on http://127.0.0.1:${PORT}  (OpenAI API at /v1)"
echo "Smoke test:"
echo "  curl http://127.0.0.1:${PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"default_model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'"
echo

# Quantize the KV cache to 4 bits. Needed for the 35B-A3B MoE (its
# full-precision KV cache overflows Metal memory on Macs where the model and its
# KV cache don't both fit — "Insufficient Memory" -> "generation thread died").
# Override with KV_BITS=8 if quality suffers (and it still fits in RAM).
KV_BITS="${KV_BITS:-4}"

# Cap output at 8192 tokens. Agents spend tokens on reasoning before their tool
# call; lower caps truncate the tool call mid-generation ("No function provided"),
# which breaks OpenCode's agent loop. All Qwen3-family models here generate at
# most 32768 tokens per response — the same ceiling the app's Max tokens field
# enforces — so keep this at or below 32768.
MAX_TOKENS="${MAX_TOKENS:-8192}"

# Sampling params. mlx_lm.server IGNORES the model's generation_config.json and
# defaults to GREEDY decoding (temp 0.0, top_p 1.0, top_k 0) with NO repetition
# penalty — the classic recipe for a repetition loop ("the same phrase forever").
# A modest temp (0.2) keeps output deterministic enough for reliable tool calls
# while breaking the greedy repetition loop. The MODEL (Qwen3.5, not the older
# Qwen3/2.5 coders) is what makes the tool-call FORMAT reliable — see the model
# note above. Raise TEMP toward ~1.0 for creative (non-agent) use.
TEMP="${TEMP:-0.2}"
TOP_P="${TOP_P:-0.8}"
TOP_K="${TOP_K:-20}"

# Thinking mode — the same toggle as the menu-bar app, default off. Only the
# Qwen3-family chat templates accept `enable_thinking`, so the flag is passed for
# those models only (see THINKING_MODELS below); for Coder / Ministral / Gemma /
# Llama / Devstral it's meaningless and is omitted. mlx-lm ≥ 0.32 keeps the answer
# clean either way: with thinking on it emits the reasoning in a separate
# `reasoning` field, so agents still see a clean answer. It just burns extra
# reasoning tokens per turn (slower + more KV cache), so it stays off.
ENABLE_THINKING="${ENABLE_THINKING:-false}"

# Models whose chat template accepts `enable_thinking` (the Qwen3 family).
THINKING_MODELS=(
  "mlx-community/Qwen3.5-35B-A3B-4bit"
  "mlx-community/Qwen3.6-35B-A3B-4bit"
  "mlx-community/Qwen3.8-27B-4bit"
  "mlx-community/Qwen3-14B-4bit"
  "mlx-community/Qwen3.5-9B-4bit"
  "mlx-community/Qwen3.5-4B-4bit"
  "mlx-community/Qwen3.5-2B-4bit"
)

supports_thinking() {
  local m
  for m in "${THINKING_MODELS[@]}"; do
    if [[ "$m" == "$MODEL" ]]; then
      return 0
    fi
  done
  return 1
}

# Models whose KV cache is mlx_lm's RotatingKVCache (Gemma 4, Ministral 3,
# Llama 3.2's sliding-window layers). Rotating caches have no quantized form
# yet — passing --kv-bits raises "RotatingKVCache Quantization NYI" on the
# first request — so it's omitted for them and they run a full-precision cache.
ROTATING_KV_MODELS=(
  "mlx-community/gemma-4-12B-it-qat-4bit"
  "mlx-community/Ministral-3-8B-Instruct-2512-4bit"
  "mlx-community/gemma-4-e4b-it-4bit"
  "mlx-community/gemma-4-e2b-it-4bit"
  "mlx-community/Ministral-3-3B-Instruct-2512-4bit"
  "mlx-community/Llama-3.2-3B-Instruct-4bit"
)

uses_rotating_kv() {
  local m
  for m in "${ROTATING_KV_MODELS[@]}"; do
    if [[ "$m" == "$MODEL" ]]; then
      return 0
    fi
  done
  return 1
}

ARGS=(--model "$MODEL" --port "$PORT" \
  --max-tokens "$MAX_TOKENS" \
  --temp "$TEMP" \
  --top-p "$TOP_P" \
  --top-k "$TOP_K")
if ! uses_rotating_kv; then
  ARGS+=(--kv-bits "$KV_BITS")
fi
if supports_thinking; then
  ARGS+=(--chat-template-args "{\"enable_thinking\":${ENABLE_THINKING}}")
fi

# Enable the fast Rust downloader when the active Python has it, so a model the
# server auto-downloads on first launch doesn't stall behind anonymous HF limits.
if command -v python3 >/dev/null 2>&1 && python3 -c "import hf_transfer" >/dev/null 2>&1; then
  export HF_HUB_ENABLE_HF_TRANSFER=1
fi

exec mlx_lm.server "${ARGS[@]}"
