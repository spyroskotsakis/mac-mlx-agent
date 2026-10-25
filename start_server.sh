#!/usr/bin/env bash
# Start the local MLX-LM server (OpenAI-compatible) on port 8080.
# Usage: ./start_server.sh [model]
set -euo pipefail

# Default is the Qwen3.5-35B-A3B MoE — the model the WWDC26 demo ran for its
# OpenCode/Xcode agent loop. It emits the `<tool_call>\n<function=…>` XML tool
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

echo "Starting MLX-LM server for: $MODEL"
echo "Listening on http://127.0.0.1:${PORT}  (OpenAI API at /v1)"
echo "Smoke test:"
echo "  curl http://127.0.0.1:${PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"default_model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'"
echo

# Quantize the KV cache to 4 bits. Needed for the 35B-A3B MoE (its
# full-precision KV cache overflows Metal memory on 36 GB Macs during long agent
# prompts — "Insufficient Memory" -> "generation thread died").
# Override with KV_BITS=8 if quality suffers (and it still fits in RAM).
KV_BITS="${KV_BITS:-4}"
# Cap output at 8192 tokens. Agents spend tokens on reasoning before their tool
# call; lower caps truncate the tool call mid-generation ("No function provided"),
# which breaks OpenCode's agent loop.
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

exec mlx_lm.server --model "$MODEL" --port "$PORT" \
  --kv-bits "$KV_BITS" \
  --max-tokens "$MAX_TOKENS" \
  --temp "$TEMP" \
  --top-p "$TOP_P" \
  --top-k "$TOP_K"
