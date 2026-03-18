#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Patch an existing ARIS install to use local Ollama models for both executor and reviewer.

This script is intended to be run after the normal ARIS install steps.

Usage:
  bash tools/patch_local_ollama.sh [options]

Options:
  --claude-dir PATH          Claude config dir to patch. Default: ~/.claude
  --python PATH              Python executable for llm-chat MCP server. Default: python3
  --ollama-host HOST:PORT    Ollama host. Default: $OLLAMA_HOST or 127.0.0.1:11434
  --executor-model MODEL     Executor model. Default: qwen3-coder-next:latest
  --reviewer-model MODEL     Reviewer model. Default: qwen3.5:35b
  --timeout-ms VALUE         API timeout in ms. Default: 3000000
  --skip-pip-install         Do not install mcp-servers/llm-chat Python requirements
  --skip-skills-copy         Do not copy repo skills into ~/.claude/skills
  --skip-tests               Do not run endpoint smoke tests
  --force                    Overwrite settings.json without a confirmation prompt
  -h, --help                 Show this help

Examples:
  bash tools/patch_local_ollama.sh
  bash tools/patch_local_ollama.sh --ollama-host 127.0.0.1:11435
  bash tools/patch_local_ollama.sh --executor-model qwen3.5:35b --reviewer-model deepseek-r1:32b
  bash tools/patch_local_ollama.sh --python /path/to/venv/bin/python
EOF
}

log() {
  printf '[patch-local-ollama] %s\n' "$*"
}

die() {
  printf '[patch-local-ollama] ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLAUDE_DIR="${HOME}/.claude"
PYTHON_BIN="python3"
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
EXECUTOR_MODEL="qwen3-coder-next:latest"
REVIEWER_MODEL="qwen3.5:35b"
TIMEOUT_MS="3000000"
SKIP_PIP_INSTALL=0
SKIP_SKILLS_COPY=0
SKIP_TESTS=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-dir)
      [[ $# -ge 2 ]] || die "missing value for --claude-dir"
      CLAUDE_DIR="$2"
      shift 2
      ;;
    --python)
      [[ $# -ge 2 ]] || die "missing value for --python"
      PYTHON_BIN="$2"
      shift 2
      ;;
    --ollama-host)
      [[ $# -ge 2 ]] || die "missing value for --ollama-host"
      OLLAMA_HOST="$2"
      shift 2
      ;;
    --executor-model)
      [[ $# -ge 2 ]] || die "missing value for --executor-model"
      EXECUTOR_MODEL="$2"
      shift 2
      ;;
    --reviewer-model)
      [[ $# -ge 2 ]] || die "missing value for --reviewer-model"
      REVIEWER_MODEL="$2"
      shift 2
      ;;
    --timeout-ms)
      [[ $# -ge 2 ]] || die "missing value for --timeout-ms"
      TIMEOUT_MS="$2"
      shift 2
      ;;
    --skip-pip-install)
      SKIP_PIP_INSTALL=1
      shift
      ;;
    --skip-skills-copy)
      SKIP_SKILLS_COPY=1
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -d "${REPO_ROOT}/skills" ]] || die "could not find repo skills directory at ${REPO_ROOT}/skills"
[[ -f "${REPO_ROOT}/mcp-servers/llm-chat/server.py" ]] || die "could not find llm-chat server at ${REPO_ROOT}/mcp-servers/llm-chat/server.py"
[[ -f "${REPO_ROOT}/mcp-servers/llm-chat/requirements.txt" ]] || die "could not find llm-chat requirements at ${REPO_ROOT}/mcp-servers/llm-chat/requirements.txt"

if [[ "${PYTHON_BIN}" = */* ]]; then
  [[ -x "${PYTHON_BIN}" ]] || die "python executable not found: ${PYTHON_BIN}"
  PYTHON_RESOLVED="${PYTHON_BIN}"
else
  PYTHON_RESOLVED="$(command -v "${PYTHON_BIN}" || true)"
  [[ -n "${PYTHON_RESOLVED}" ]] || die "python executable not found in PATH: ${PYTHON_BIN}"
fi

if ! command -v curl >/dev/null 2>&1; then
  die "curl is required"
fi

if ! command -v ollama >/dev/null 2>&1; then
  log "ollama CLI not found in PATH; continuing because HTTP tests may still work"
fi

SETTINGS_PATH="${CLAUDE_DIR}/settings.json"
MCP_DIR="${CLAUDE_DIR}/mcp-servers/llm-chat"
SKILLS_DIR="${CLAUDE_DIR}/skills"
REWRITE_PROMPT_PATH="${CLAUDE_DIR}/ARIS_OLLAMA_SKILL_REWRITE_PROMPT.txt"
BACKUP_TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p "${CLAUDE_DIR}" "${MCP_DIR}" "${SKILLS_DIR}"

if [[ -f "${SETTINGS_PATH}" ]]; then
  BACKUP_PATH="${SETTINGS_PATH}.bak.${BACKUP_TS}"
  cp "${SETTINGS_PATH}" "${BACKUP_PATH}"
  log "backed up existing settings.json to ${BACKUP_PATH}"
fi

if [[ -f "${SETTINGS_PATH}" && ${FORCE} -eq 0 ]]; then
  if [[ -t 0 ]]; then
    printf 'Overwrite %s with local Ollama settings? [y/N] ' "${SETTINGS_PATH}"
    read -r reply
    case "${reply}" in
      y|Y|yes|YES)
        ;;
      *)
        die "aborted by user"
        ;;
    esac
  else
    die "${SETTINGS_PATH} already exists; rerun with --force to overwrite non-interactively"
  fi
fi

if [[ ${SKIP_PIP_INSTALL} -eq 0 ]]; then
  log "installing llm-chat Python dependency with ${PYTHON_RESOLVED}"
  "${PYTHON_RESOLVED}" -m pip install -r "${REPO_ROOT}/mcp-servers/llm-chat/requirements.txt"
else
  log "skipping pip install"
fi

log "copying llm-chat MCP server"
cp "${REPO_ROOT}/mcp-servers/llm-chat/server.py" "${MCP_DIR}/server.py"

if [[ ${SKIP_SKILLS_COPY} -eq 0 ]]; then
  log "copying ARIS skills into ${SKILLS_DIR}"
  cp -R "${REPO_ROOT}/skills/." "${SKILLS_DIR}/"
else
  log "skipping skills copy"
fi

log "writing a local-Ollama settings.json to ${SETTINGS_PATH}"

cat > "${SETTINGS_PATH}" <<EOF
{
  "model": "${EXECUTOR_MODEL}",
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "ollama",
    "ANTHROPIC_API_KEY": "",
    "ANTHROPIC_BASE_URL": "http://${OLLAMA_HOST}",
    "API_TIMEOUT_MS": "${TIMEOUT_MS}"
  },
  "mcpServers": {
    "llm-chat": {
      "command": "${PYTHON_RESOLVED}",
      "args": [
        "${MCP_DIR}/server.py"
      ],
      "env": {
        "LLM_API_KEY": "ollama",
        "LLM_BASE_URL": "http://${OLLAMA_HOST}/v1",
        "LLM_MODEL": "${REVIEWER_MODEL}"
      }
    }
  }
}
EOF

cat > "${REWRITE_PROMPT_PATH}" <<'EOF'
Read skills/auto-review-loop-llm/SKILL.md as a reference.
It replaces mcp__codex__codex with mcp__llm-chat__chat.
Now rewrite ALL other skills that use mcp__codex__codex / mcp__codex__codex-reply
to use mcp__llm-chat__chat instead, following the same pattern.
EOF

log "wrote ${SETTINGS_PATH}"
log "wrote ${REWRITE_PROMPT_PATH}"

if [[ ${SKIP_TESTS} -eq 0 ]]; then
  log "testing Ollama model inventory endpoint"
  curl -fsS "http://${OLLAMA_HOST}/api/tags" >/dev/null

  log "testing Anthropic-compatible executor endpoint with ${EXECUTOR_MODEL}"
  curl -fsS "http://${OLLAMA_HOST}/v1/messages" \
    -H 'Content-Type: application/json' \
    -H 'x-api-key: ollama' \
    -H 'anthropic-version: 2023-06-01' \
    -d "{\"model\":\"${EXECUTOR_MODEL}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: executor-ok\"}]}" >/dev/null

  log "testing OpenAI-compatible reviewer endpoint with ${REVIEWER_MODEL}"
  curl -fsS "http://${OLLAMA_HOST}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer ollama' \
    -d "{\"model\":\"${REVIEWER_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: reviewer-ok\"}],\"max_tokens\":16}" >/dev/null
else
  log "skipping endpoint tests"
fi

cat <<EOF

Patch complete.

Files:
  settings: ${SETTINGS_PATH}
  reviewer MCP server: ${MCP_DIR}/server.py
  local skill rewrite prompt: ${REWRITE_PROMPT_PATH}

Configured models:
  executor: ${EXECUTOR_MODEL}
  reviewer: ${REVIEWER_MODEL}
  ollama host: ${OLLAMA_HOST}

Start Claude Code with:
  claude

If your Claude Code binary is not on PATH, use your normal launch command, for example:
  micromamba run -n aris claude

Recommended first ARIS command:
  /auto-review-loop-llm "your topic"

Recommended one-time conversion step inside Claude Code:
  paste the contents of ${REWRITE_PROMPT_PATH}
EOF
