#!/usr/bin/env bash
# Start the local MLX-LM server (OpenAI-compatible) on port 8080.
# Usage: ./start_server.sh [model]
set -euo pipefail

MODEL="${1:-mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit}"
PORT="${PORT:-8080}"

echo "Starting MLX-LM server for: $MODEL"
echo "Listening on http://127.0.0.1:${PORT}  (OpenAI API at /v1)"
echo "Smoke test:"
echo "  curl http://127.0.0.1:${PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"default_model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'"
echo

exec mlx_lm.server --model "$MODEL" --port "$PORT"
