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

# Mistral-family models whose chat template enforces strict user/assistant role
# alternation and raises "conversation roles must alternate" (a 404 through
# mlx_lm.server) on OpenCode's tool-call follow-ups. They're served with a
# lenient copy of the template instead — same [SYSTEM_PROMPT]/[INST]/[TOOL_CALLS]
# token format, alternation check removed. Keep in sync with
# `lenientMistralChatTemplate` in MLXServer/MLXServer/ServerController.swift.
MISTRAL_MODELS=(
  "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"
  "mlx-community/Ministral-3-8B-Instruct-2512-4bit"
  "mlx-community/Ministral-3-3B-Instruct-2512-4bit"
)

uses_mistral_lenient_template() {
  local m
  for m in "${MISTRAL_MODELS[@]}"; do
    if [[ "$m" == "$MODEL" ]]; then
      return 0
    fi
  done
  return 1
}

# The lenient template (see MISTRAL_MODELS above) is read into a variable and
# passed verbatim via --chat-template. It is the exact same template embedded as
# `lenientMistralChatTemplate` in MLXServer/MLXServer/ServerController.swift.
LENIENT_MISTRAL_TEMPLATE=''
if uses_mistral_lenient_template; then
  read -r -d '' LENIENT_MISTRAL_TEMPLATE <<'JINJA' || true
  {#- Default system message if no system prompt is passed. #}
  {%- set default_system_message = '' %}
  {{- bos_token }}
  {%- if messages[0]['role'] == 'system' %}
      {{- '[SYSTEM_PROMPT]' -}}
      {%- if messages[0]['content'] is string %}
          {{- messages[0]['content'] -}}
      {%- else %}
          {%- for block in messages[0]['content'] %}
              {%- if block['type'] == 'text' %}
                  {{- block['text'] }}
              {%- else %}
                  {{- raise_exception('Only text chunks are supported in system message contents.') }}
              {%- endif %}
          {%- endfor %}
      {%- endif %}
      {{- '[/SYSTEM_PROMPT]' -}}
      {%- set loop_messages = messages[1:] %}
  {%- else %}
      {%- set loop_messages = messages %}
      {%- if default_system_message != '' %}
          {{- '[SYSTEM_PROMPT]' + default_system_message + '[/SYSTEM_PROMPT]' }}
      {%- endif %}
  {%- endif %}
  {%- set tools_definition = '' %}
  {%- set has_tools = false %}
  {%- if tools is defined and tools is not none and tools|length > 0 %}
      {%- set has_tools = true %}
      {%- set tools_definition = '[AVAILABLE_TOOLS]' + (tools| tojson) + '[/AVAILABLE_TOOLS]' %}
      {{- tools_definition }}
  {%- endif %}
  {%- for message in loop_messages %}
      {%- if message['role'] == 'user' %}
          {%- if message['content'] is string %}
              {{- '[INST]' + message['content'] + '[/INST]' }}
          {%- elif message['content'] | length > 0 %}
              {{- '[INST]' }}
              {%- if message['content'] | length == 2 %}
                  {%- set blocks = message['content'] | sort(attribute='type') %}
              {%- else %}
                  {%- set blocks = message['content'] %}
              {%- endif %}
              {%- for block in blocks %}
                  {%- if block['type'] == 'text' %}
                      {{- block['text'] }}
                  {%- elif block['type'] in ['image', 'image_url'] %}
                      {{- '[IMG]' }}
                  {%- else %}
                      {{- raise_exception('Only text, image and image_url chunks are supported in user message content.') }}
                  {%- endif %}
              {%- endfor %}
              {{- '[/INST]' }}
          {%- else %}
              {{- raise_exception('User message must have a string or a list of chunks in content') }}
          {%- endif %}
      {%- elif message['role'] == 'assistant' %}
          {%- if (message['content'] is none or message['content'] == '' or message['content']|length == 0) and (message['tool_calls'] is not defined or message['tool_calls'] is none or message['tool_calls']|length == 0) %}
              {{- raise_exception('Assistant message must have a string or a list of chunks in content or a list of tool calls.') }}
          {%- endif %}
          {%- if message['content'] is string %}
              {{- message['content'] }}
          {%- elif message['content'] | length > 0 %}
              {%- for block in message['content'] %}
                  {%- if block['type'] == 'text' %}
                      {{- block['text'] }}
                  {%- else %}
                      {{- raise_exception('Only text chunks are supported in assistant message contents.') }}
                  {%- endif %}
              {%- endfor %}
          {%- endif %}
          {%- if message['tool_calls'] is defined and message['tool_calls'] is not none and message['tool_calls']|length > 0 %}
              {%- for tool in message['tool_calls'] %}
                  {%- set arguments = tool['function']['arguments'] %}
                  {%- if arguments is not string %}
                      {%- set arguments = arguments|tojson|safe %}
                  {%- elif arguments == '' %}
                      {%- set arguments = '{}' %}
                  {%- endif %}
                  {{- '[TOOL_CALLS]' + tool['function']['name'] + '[ARGS]' + arguments }}
              {%- endfor %}
          {%- endif %}
          {{- eos_token }}
      {%- elif message['role'] == 'tool' %}
          {{- '[TOOL_RESULTS]' + message['content']|string + '[/TOOL_RESULTS]' }}
      {%- else %}
          {{- raise_exception('Only user, assistant and tool roles are supported, got ' + message['role'] + '.') }}
      {%- endif %}
  {%- endfor %}
JINJA
fi

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
if uses_mistral_lenient_template; then
  ARGS+=(--chat-template "$LENIENT_MISTRAL_TEMPLATE")
fi

# Disable hf_xet's Xet backend — its CAS reconstruction API hangs on anonymous
# downloads, so a model mlx_lm.server auto-downloads on first launch would stall
# at 0 bytes. The classic LFS path downloads and resumes cleanly instead.
export HF_HUB_DISABLE_XET=1

exec mlx_lm.server "${ARGS[@]}"
