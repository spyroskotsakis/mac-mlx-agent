#!/usr/bin/env bash
# One-command setup for the terminal (non-GUI) path of this repo.
#
# Checks that every prerequisite is installed, installs whatever is missing, and
# (optionally) downloads one of the supported models and writes the OpenCode +
# Claude Code configs that point at it. This is the shell equivalent of the
# menu-bar app's "Install" buttons + model picker.
#
# Usage:
#   ./setup.sh                                              # check, install missing tools, then pick a model
#   ./setup.sh --check                                      # only report status, install nothing
#   ./setup.sh --yes                                        # non-interactive: install tools + the default model
#   ./setup.sh --model mlx-community/Qwen3-14B-4bit         # install tools + a specific model
#   ./setup.sh --no-model                                   # install tools only, skip the model
#
# Ports (must match the app and start_server.sh):
#   MLX server     = 8080
#   LiteLLM bridge = 4001  (not 4000 — that's commonly taken by another LiteLLM)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Overridable settings (same defaults as the app / start_server.sh).
MLX_PORT="${MLX_PORT:-8080}"
BRIDGE_PORT="${BRIDGE_PORT:-4001}"
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-8192}"
PYTHON="${PYTHON:-python3}"

# --- model table (mirrors ServerController.availableModels) --------------------
MODELS_REPO=(
  "mlx-community/Qwen3.5-35B-A3B-4bit"
  "mlx-community/Qwen3.6-35B-A3B-4bit"
  "mlx-community/Qwen3.8-27B-4bit"
  "mlx-community/Qwen3-14B-4bit"
  "mlx-community/Qwen3.5-9B-4bit"
  "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
  "mlx-community/Qwen3.5-4B-4bit"
  "mlx-community/Qwen3.5-2B-4bit"
  "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"
  "mlx-community/gemma-4-12B-it-qat-4bit"
  "mlx-community/Ministral-3-8B-Instruct-2512-4bit"
  "mlx-community/gemma-4-e4b-it-4bit"
  "mlx-community/gemma-4-e2b-it-4bit"
  "mlx-community/Ministral-3-3B-Instruct-2512-4bit"
  "mlx-community/Llama-3.2-3B-Instruct-4bit"
  "mlx-community/Qwen3-Coder-Next-4bit"
  "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
  "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit"
  "mlx-community/gpt-oss-120b-MXFP4-Q8"
  "mlx-community/gpt-oss-20b-MXFP4-Q8"
  "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
  "mlx-community/GLM-4.7-Flash-4bit"
  "mlx-community/LFM2-24B-A2B-4bit"
  "mlx-community/LFM2.5-1.2B-Instruct-4bit"
)
MODELS_NAME=(
  "Qwen3.5-35B-A3B (4-bit)"
  "Qwen3.6-35B-A3B (4-bit)"
  "Qwen3.8-27B (4-bit)"
  "Qwen3-14B (4-bit)"
  "Qwen3.5-9B (4-bit)"
  "Qwen2.5-Coder-7B-Instruct (4-bit)"
  "Qwen3.5-4B (4-bit)"
  "Qwen3.5-2B (4-bit)"
  "Devstral Small 2 24B Instruct (4-bit)"
  "Gemma 4 12B IT QAT (4-bit)"
  "Ministral 3 8B Instruct (4-bit)"
  "Gemma 4 E4B Instruct (4-bit)"
  "Gemma 4 E2B Instruct (4-bit)"
  "Ministral 3 3B Instruct (4-bit)"
  "Llama 3.2 3B Instruct (4-bit)"
  "Qwen3-Coder-Next (4-bit)"
  "Qwen3-Coder-30B-A3B-Instruct (4-bit)"
  "DeepSeek-R1-Distill-Qwen-32B (4-bit)"
  "GPT-OSS 120B (MXFP4-Q8)"
  "GPT-OSS 20B (MXFP4-Q8)"
  "Gemma 4 26B A4B IT QAT (4-bit)"
  "GLM-4.7-Flash (4-bit)"
  "LFM2 24B A2B (4-bit)"
  "LFM2.5 1.2B Instruct (4-bit)"
)
MODELS_CTX=(262144 262144 262144 40960 262144 32768 262144 262144 393216 262144 262144 131072 131072 262144 131072 262144 262144 131072 131072 131072 262144 202752 128000 128000)
MODELS_WGT=(18 18 14 7 6 4.28 3.03 1.72 15.10 10.99 5.60 5.15 3.55 2.75 1.81 44.84 17.18 18.43 63.39 12.08 15.61 16.85 12.49 0.66)
MODELS_THINK=(yes yes yes yes yes no yes yes no no no no no no no no no no no no no no no no)
DEFAULT_INDEX=0

# --- flags ---------------------------------------------------------------------
CHECK_ONLY=0
ASSUME_YES=0
SKIP_MODEL=0
MODEL_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--check)   CHECK_ONLY=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    -n|--no-model) SKIP_MODEL=1 ;;
    -m|--model)   MODEL_ARG="${2:-}"; shift ;;
    -h|--help)    sed -n '2,17p' "$0"; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- output helpers ------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
ok()   { printf '  \342\234\223 %s\n' "$*"; }
bad()  { printf '  \342\234\227 %s\n' "$*"; }
warn() { printf '  \342\234\203 %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve the `hf` CLI. It's a console script that pip installs into the active
# Python's scripts dir, which isn't always on PATH — fall back to that dir.
HF_BIN=""
find_hf() {
  if have hf; then HF_BIN="$(command -v hf)"; return 0; fi
  local scripts
  scripts="$("$PYTHON" -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>/dev/null)"
  if [[ -n "$scripts" && -x "$scripts/hf" ]]; then HF_BIN="$scripts/hf"; return 0; fi
  return 1
}

# --- status checks (sets *_OK flags) -------------------------------------------
check_status() {
  say ""
  say "Checking prerequisites…"

  if have "$PYTHON"; then
    ok "Python ($("$PYTHON" --version 2>&1))"
    PYTHON_OK=1
  elif have python3; then
    PYTHON="python3"
    ok "Python ($("$PYTHON" --version 2>&1))"
    PYTHON_OK=1
  else
    bad "Python 3 not found (install from https://www.python.org, or `xcode-select --install`)"
    PYTHON_OK=0
  fi

  if "$PYTHON" -c "import mlx_lm" >/dev/null 2>&1; then ok "mlx-lm"; MLXLM_OK=1; else bad "mlx-lm"; MLXLM_OK=0; fi
  if find_hf; then ok "hf (huggingface_hub) → $HF_BIN"; HF_OK=1; else bad "hf (huggingface_hub)"; HF_OK=0; fi
  if "$PYTHON" -c "import uvicorn, fastapi" >/dev/null 2>&1; then ok "uvicorn + fastapi"; UVICORN_OK=1; else bad "uvicorn + fastapi"; UVICORN_OK=0; fi
  if have opencode || [[ -x "$HOME/.opencode/bin/opencode" ]]; then ok "OpenCode (recommended agent)"; OPENCODE_OK=1; else bad "OpenCode (recommended agent)"; OPENCODE_OK=0; fi
  if have claude; then ok "Claude Code"; CLAUDE_OK=1; else warn "Claude Code not found (optional — OpenCode is recommended for local models)"; CLAUDE_OK=0; fi
  if [[ -x "$SCRIPT_DIR/.venv-litellm/bin/litellm" ]]; then ok "LiteLLM (.venv-litellm)"; LITELLM_OK=1; else bad "LiteLLM (.venv-litellm)"; LITELLM_OK=0; fi
  say ""
}

# --- installers ----------------------------------------------------------------
install_python_pkgs() {
  if [[ "${MLXLM_OK:-0}" -eq 1 && "${HF_OK:-0}" -eq 1 && "${UVICORN_OK:-0}" -eq 1 ]]; then
    ok "Python packages already installed — nothing to do."
    return 0
  fi
  say "Installing mlx-lm, uvicorn, fastapi, and huggingface_hub (the \`hf\` CLI)…"
  "$PYTHON" -m pip install --upgrade mlx-lm uvicorn fastapi huggingface_hub 'brotli>=1.2.0' || {
    say "pip install failed. If you use a venv, re-run with: PYTHON=/path/to/venv/bin/python ./setup.sh" >&2
    return 1
  }
  ok "Python packages installed."
  "$PYTHON" -c "import mlx_lm" >/dev/null 2>&1 && MLXLM_OK=1 || MLXLM_OK=0
  "$PYTHON" -c "import uvicorn, fastapi" >/dev/null 2>&1 && UVICORN_OK=1 || UVICORN_OK=0
  find_hf && HF_OK=1 || HF_OK=0
}

install_litellm() {
  if [[ "${LITELLM_OK:-0}" -eq 1 ]]; then ok "LiteLLM already installed."; return 0; fi
  say "Creating isolated venv .venv-litellm and installing litellm[proxy]…"
  "$PYTHON" -m venv "$SCRIPT_DIR/.venv-litellm"
  "$SCRIPT_DIR/.venv-litellm/bin/pip" install --upgrade 'litellm[proxy]' || {
    say "litellm install failed." >&2
    return 1
  }
  LITELLM_OK=1
  ok "LiteLLM installed."
}

install_opencode() {
  if [[ "${OPENCODE_OK:-0}" -eq 1 ]]; then ok "OpenCode already installed."; return 0; fi
  say "Installing OpenCode (the recommended agent for local models)…"
  curl -fsSL https://opencode.ai/install | bash || {
    say "OpenCode install failed — install it manually with: curl -fsSL https://opencode.ai/install | bash" >&2
    return 1
  }
  OPENCODE_OK=1
  ok "OpenCode installed."
}

# --- model selection + download + config --------------------------------------
list_models() {
  say "Available models:"
  local i think
  for i in "${!MODELS_REPO[@]}"; do
    think="no thinking"
    [[ "${MODELS_THINK[$i]}" == yes ]] && think="thinking"
    printf '  %2d) %-38s ~%5s GB weights, %s context, %s\n' \
      "$((i + 1))" "${MODELS_NAME[$i]}" "${MODELS_WGT[$i]}" "${MODELS_CTX[$i]}" "$think"
  done
}

pick_model() {
  if [[ -n "$MODEL_ARG" ]]; then
    local i
    for i in "${!MODELS_REPO[@]}"; do
      if [[ "${MODELS_REPO[$i]}" == "$MODEL_ARG" ]]; then SELECTED_INDEX=$i; return 0; fi
    done
    say "Unknown model: $MODEL_ARG" >&2
    list_models
    exit 2
  fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then SELECTED_INDEX=$DEFAULT_INDEX; return 0; fi

  list_models
  local choice re="^[1-${#MODELS_REPO[@]}]$"
  read -r -p "Choose a model [1-${#MODELS_REPO[@]}, default 1]: " choice
  choice="${choice:-1}"
  if [[ "$choice" =~ $re ]]; then
    SELECTED_INDEX=$((choice - 1))
  else
    say "Invalid choice, using the default." >&2
    SELECTED_INDEX=$DEFAULT_INDEX
  fi
}

# Resolve the installed OpenCode's major version (1 or 2) so the config is
# written in the matching shape. v1 uses `provider`/`npm`/`options`; v2 uses
# `providers`/`package`/`settings`/`capabilities`. Defaults to 1 (v1) when the
# binary can't be run, so a machine without OpenCode yet gets the v1 shape.
opencode_major() {
  local bin="" v="" c
  # Same precedence as ServerController.resolveOpenCode(), so the app and this
  # script always agree on which installed binary to probe.
  for c in \
    "$HOME/.opencode/bin/opencode" \
    "$HOME/.local/bin/opencode" \
    "/opt/homebrew/bin/opencode" \
    "/usr/local/bin/opencode"; do
    if [[ -x "$c" ]]; then bin="$c"; break; fi
  done
  if [[ -z "$bin" ]] && have opencode; then bin="$(command -v opencode)"; fi
  if [[ -z "$bin" ]]; then echo "1"; return 0; fi
  v="$("$bin" --version 2>/dev/null)" || { echo "1"; return 0; }
  # `opencode --version` prints "opencode v2.2.4" (not "v2.2.4"), so match the
  # first N.M version token anywhere in the line instead of assuming a leading
  # "v" or digit.
  if [[ "$v" =~ ([0-9]+)\.([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "1"
  fi
}

configure_agents() {
  local repo="$1" name="$2" ctx="$3"

  # OpenCode config (JSONC filename, pure-JSON content — same as the app writes).
  # The shape follows the installed OpenCode major: v1 uses `provider`/`npm`/
  # `options`/`modalities`; v2 uses `providers`/`package`/`settings`/`capabilities`.
  # Mistral-family models get `compatibility.requireAssistantAfterTool` in v2 to
  # bridge the tool-result→user boundary their chat template otherwise rejects.
  local oc_major oc_compat=""
  oc_major="$(opencode_major)"
  case "$repo" in
    *Devstral*|*Ministral*) oc_compat=$',\n          "compatibility": { "requireAssistantAfterTool": true }' ;;
  esac
  local oc_dir="$HOME/.config/opencode"
  local oc_file="$oc_dir/opencode.jsonc"
  mkdir -p "$oc_dir"
  if [[ -f "$oc_file" ]]; then
    local bak="$oc_file.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$oc_file" "$bak"
    say "Backed up existing OpenCode config → $bak"
  fi
  if [[ "$oc_major" -ge 2 ]]; then
    cat > "$oc_file" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "mlx/default_model",
  "providers": {
    "mlx": {
      "package": "@opencode/ai/providers/openai-compatible",
      "name": "MLX (local)",
      "settings": {
        "baseURL": "http://127.0.0.1:${MLX_PORT}/v1",
        "chunkTimeout": false,
        "headerTimeout": false
      },
      "models": {
        "default_model": {
          "modelID": "default_model",
          "name": "${name}",
          "limit": {
            "context": ${ctx},
            "output": ${MAX_OUTPUT_TOKENS}
          },
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          }${oc_compat}
        }
      }
    }
  }
}
EOF
  else
    cat > "$oc_file" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "mlx/default_model",
  "provider": {
    "mlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "MLX (local)",
      "options": {
        "baseURL": "http://127.0.0.1:${MLX_PORT}/v1",
        "chunkTimeout": false,
        "headerTimeout": false
      },
      "models": {
        "default_model": {
          "name": "${name}",
          "limit": {
            "context": ${ctx},
            "output": ${MAX_OUTPUT_TOKENS}
          },
          "modalities": {
            "input": ["text"],
            "output": ["text"]
          },
          "attachment": false
        }
      }
    }
  }
}
EOF
  fi
  ok "Wrote OpenCode config → $oc_file"

  # Claude Code env profile (sourced by ./claude-local.sh or manually).
  local cc_dir="$HOME/.config/mlx-local"
  local cc_file="$cc_dir/claude-code.env"
  mkdir -p "$cc_dir"
  if [[ -f "$cc_file" ]]; then
    local bak="$cc_file.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$cc_file" "$bak"
    say "Backed up existing Claude Code profile → $bak"
  fi
  cat > "$cc_file" <<EOF
# Claude Code → local MLX model via the LiteLLM bridge.
# Source this file (or use ./claude-local.sh) before running \`claude\`.
export ANTHROPIC_BASE_URL="http://127.0.0.1:${BRIDGE_PORT}"
export ANTHROPIC_AUTH_TOKEN="sk-local-claude"
export ANTHROPIC_MODEL="default_model"
export ANTHROPIC_DEFAULT_OPUS_MODEL="default_model"
export ANTHROPIC_DEFAULT_SONNET_MODEL="default_model"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="default_model"
export CLAUDE_CODE_SUBAGENT_MODEL="default_model"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=${ctx}
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=${MAX_OUTPUT_TOKENS}
export MAX_THINKING_TOKENS=0
EOF
  ok "Wrote Claude Code env profile → $cc_file"
}

download_and_configure() {
  local idx="$SELECTED_INDEX"
  local repo="${MODELS_REPO[$idx]}"
  local name="${MODELS_NAME[$idx]}"
  local ctx="${MODELS_CTX[$idx]}"

  say ""
  say "Downloading $name …"
  if ! find_hf; then
    say "hf not found — installing huggingface_hub first."
    "$PYTHON" -m pip install --upgrade huggingface_hub 'brotli>=1.2.0' || { say "huggingface_hub install failed." >&2; return 1; }
    find_hf || { say "Still can't find the \`hf\` CLI." >&2; return 1; }
  fi
  # Disable hf_xet's Xet backend — its CAS reconstruction API hangs on anonymous
  # downloads (established sockets, zero bytes), while the classic LFS path
  # downloads and resumes cleanly. `hf download` falls back to classic LFS when
  # this is set, so model weights actually arrive instead of stalling.
  export HF_HUB_DISABLE_XET=1
  "$HF_BIN" download "$repo" || {
    say "Download failed. Re-run ./setup.sh — \`hf download\` resumes where it left off." >&2
    return 1
  }
  ok "Model downloaded."

  configure_agents "$repo" "$name" "$ctx"
}

print_next_steps() {
  local repo="${1:-}"
  say ""
  say "Done. Next steps:"
  say ""
  say "  # 1. Start the MLX server (port ${MLX_PORT}):"
  if [[ -n "$repo" ]]; then
    say "  ./start_server.sh \"$repo\""
  else
    say "  ./start_server.sh"
  fi
  say ""
  say "  # 2. OpenCode (recommended):"
  say "  opencode   # or ~/.opencode/bin/opencode if it isn't on your PATH yet"
  say ""
  say "  # 3. Claude Code (optional — slower; bridge on port ${BRIDGE_PORT}):"
  say "  .venv-litellm/bin/litellm --config litellm-mlx.yaml --host 127.0.0.1 --port ${BRIDGE_PORT}"
  say "  ./claude-local.sh"
  say ""
}

# --- main ----------------------------------------------------------------------
check_status

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  say "Check only — nothing installed. Run ./setup.sh to install the missing pieces."
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  local ans
  read -r -p "Install missing components now? [Y/n] " ans
  if [[ "$ans" =~ ^[Nn] ]]; then
    say "Skipping install. Re-run ./setup.sh when ready."
    exit 0
  fi
fi

install_python_pkgs || exit 1
install_litellm     || exit 1
install_opencode    || exit 1

if [[ "$SKIP_MODEL" -eq 1 ]]; then
  say "Skipping model download (--no-model)."
  print_next_steps ""
  exit 0
fi

pick_model
download_and_configure
print_next_steps "${MODELS_REPO[$SELECTED_INDEX]}"
