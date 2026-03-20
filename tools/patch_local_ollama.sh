#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Patch an existing ARIS install to use local Ollama models for executor/reviewer
and register MCP servers for reviewer chat plus web search.

This script is intended to be run after the normal ARIS install steps.

Usage:
  bash tools/patch_local_ollama.sh [options]

Options:
  --claude-dir PATH          Claude config dir to patch. Default: ~/.claude
  --claude-bin PATH          Claude CLI executable for MCP registration. Default: claude
  --python PATH              Python executable for MCP servers. Default: python3
  --ollama-host HOST:PORT    Ollama host. Default: $OLLAMA_HOST or 127.0.0.1:11434
  --executor-model MODEL     Executor model. Default: qwen3-coder:latest
  --reviewer-model MODEL     Reviewer model. Default: qwen3.5:35b
  --timeout-ms VALUE         API timeout in ms. Default: 3000000
  --skip-pip-install         Do not install mcp-servers/llm-chat Python requirements
  --skip-skills-copy         Do not copy repo skills into ~/.claude/skills
  --skip-skill-rewrite       Do not rewrite copied skills for llm-chat + web-search MCP
  --skip-mcp-register        Do not run 'claude mcp add-json' registration
  --skip-tests               Do not run endpoint smoke tests
  --force                    Overwrite settings.json without a confirmation prompt
  -h, --help                 Show this help

Examples:
  bash tools/patch_local_ollama.sh
  bash tools/patch_local_ollama.sh --ollama-host 127.0.0.1:11435
  bash tools/patch_local_ollama.sh --executor-model qwen3.5:35b --reviewer-model deepseek-r1:32b
  bash tools/patch_local_ollama.sh --python /path/to/venv/bin/python --claude-bin /path/to/claude
USAGE
}

log() {
  printf '[patch-local-ollama] %s\n' "$*"
}

die() {
  printf '[patch-local-ollama] ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_bin() {
  local name="$1"
  if [[ "$name" = */* ]]; then
    [[ -x "$name" ]] || return 1
    printf '%s\n' "$name"
    return 0
  fi

  local resolved
  resolved="$(command -v "$name" || true)"
  [[ -n "$resolved" ]] || return 1
  printf '%s\n' "$resolved"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLAUDE_DIR="${HOME}/.claude"
CLAUDE_BIN="claude"
PYTHON_BIN="python3"
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
EXECUTOR_MODEL="qwen3-coder:latest"
REVIEWER_MODEL="qwen3.5:35b"
TIMEOUT_MS="3000000"
SKIP_PIP_INSTALL=0
SKIP_SKILLS_COPY=0
SKIP_SKILL_REWRITE=0
SKIP_MCP_REGISTER=0
SKIP_TESTS=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-dir)
      [[ $# -ge 2 ]] || die "missing value for --claude-dir"
      CLAUDE_DIR="$2"
      shift 2
      ;;
    --claude-bin)
      [[ $# -ge 2 ]] || die "missing value for --claude-bin"
      CLAUDE_BIN="$2"
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
    --skip-skill-rewrite)
      SKIP_SKILL_REWRITE=1
      shift
      ;;
    --skip-mcp-register)
      SKIP_MCP_REGISTER=1
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
[[ -f "${REPO_ROOT}/mcp-servers/web-search/server.py" ]] || die "could not find web-search server at ${REPO_ROOT}/mcp-servers/web-search/server.py"

PYTHON_RESOLVED="$(resolve_bin "${PYTHON_BIN}" || true)"
[[ -n "${PYTHON_RESOLVED}" ]] || die "python executable not found: ${PYTHON_BIN}"

CLAUDE_RESOLVED=""
if [[ ${SKIP_MCP_REGISTER} -eq 0 ]]; then
  CLAUDE_RESOLVED="$(resolve_bin "${CLAUDE_BIN}" || true)"
  if [[ -z "${CLAUDE_RESOLVED}" ]]; then
    log "claude CLI not found (${CLAUDE_BIN}); skipping MCP registration"
    SKIP_MCP_REGISTER=1
  fi
fi

if ! command -v curl >/dev/null 2>&1; then
  die "curl is required"
fi

if ! command -v ollama >/dev/null 2>&1; then
  log "ollama CLI not found in PATH; continuing because HTTP tests may still work"
fi

SETTINGS_PATH="${CLAUDE_DIR}/settings.json"
LLM_CHAT_DIR="${CLAUDE_DIR}/mcp-servers/llm-chat"
WEB_SEARCH_DIR="${CLAUDE_DIR}/mcp-servers/web-search"
SKILLS_DIR="${CLAUDE_DIR}/skills"
PATCH_NOTES_PATH="${CLAUDE_DIR}/ARIS_OLLAMA_PATCH_NOTES.txt"
BACKUP_TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p "${CLAUDE_DIR}" "${LLM_CHAT_DIR}" "${WEB_SEARCH_DIR}" "${SKILLS_DIR}"

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

log "copying MCP servers"
cp "${REPO_ROOT}/mcp-servers/llm-chat/server.py" "${LLM_CHAT_DIR}/server.py"
cp "${REPO_ROOT}/mcp-servers/web-search/server.py" "${WEB_SEARCH_DIR}/server.py"

if [[ ${SKIP_SKILLS_COPY} -eq 0 ]]; then
  log "copying ARIS skills into ${SKILLS_DIR}"
  cp -R "${REPO_ROOT}/skills/." "${SKILLS_DIR}/"
else
  log "skipping skills copy"
fi

if [[ ${SKIP_SKILL_REWRITE} -eq 0 ]]; then
  log "rewriting installed skills for llm-chat + web-search MCP tools"
  "${PYTHON_RESOLVED}" - "${SKILLS_DIR}" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
changed = []
for path in root.rglob('SKILL.md'):
    text = path.read_text(encoding='utf-8')
    updated = text
    updated = updated.replace('mcp__codex__codex-reply', 'mcp__llm-chat__chat')
    updated = updated.replace('mcp__codex__codex', 'mcp__llm-chat__chat')
    updated = updated.replace('WebSearch', 'mcp__web-search__search')
    updated = updated.replace('WebFetch', 'mcp__web-search__fetch')

    lines = []
    for line in updated.splitlines():
        if line.startswith('allowed-tools:'):
            prefix, raw = line.split(':', 1)
            items = [item.strip() for item in raw.split(',')]
            deduped = []
            seen = set()
            for item in items:
                if item not in seen:
                    deduped.append(item)
                    seen.add(item)
            line = f"{prefix}: {', '.join(deduped)}"
        lines.append(line)
    new = '\n'.join(lines)
    if updated.endswith('\n'):
        new += '\n'

    if new != text:
        path.write_text(new, encoding='utf-8')
        changed.append(str(path))
print(f'rewritten {len(changed)} skill files')
for item in changed:
    print(item)
PY
else
  log "skipping skill rewrite"
fi

log "writing a local-Ollama settings.json to ${SETTINGS_PATH}"
cat > "${SETTINGS_PATH}" <<EOF_SETTINGS
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
        "${LLM_CHAT_DIR}/server.py"
      ],
      "env": {
        "LLM_API_KEY": "ollama",
        "LLM_BASE_URL": "http://${OLLAMA_HOST}/v1",
        "LLM_MODEL": "${REVIEWER_MODEL}"
      }
    },
    "web-search": {
      "command": "${PYTHON_RESOLVED}",
      "args": [
        "${WEB_SEARCH_DIR}/server.py"
      ],
      "env": {
        "WEB_SEARCH_SERVER_NAME": "web-search",
        "WEB_SEARCH_PROVIDER": "duckduckgo",
        "HTTP_TIMEOUT_SECONDS": "20",
        "MAX_FETCH_CHARS": "12000"
      }
    }
  }
}
EOF_SETTINGS

if [[ ${SKIP_MCP_REGISTER} -eq 0 ]]; then
  log "registering llm-chat MCP server in Claude user config"
  "${CLAUDE_RESOLVED}" mcp remove -s user llm-chat >/dev/null 2>&1 || true
  "${CLAUDE_RESOLVED}" mcp add-json -s user llm-chat "{\"type\":\"stdio\",\"command\":\"${PYTHON_RESOLVED}\",\"args\":[\"${LLM_CHAT_DIR}/server.py\"],\"env\":{\"LLM_API_KEY\":\"ollama\",\"LLM_BASE_URL\":\"http://${OLLAMA_HOST}/v1\",\"LLM_MODEL\":\"${REVIEWER_MODEL}\"}}"

  log "registering web-search MCP server in Claude user config"
  "${CLAUDE_RESOLVED}" mcp remove -s user web-search >/dev/null 2>&1 || true
  "${CLAUDE_RESOLVED}" mcp add-json -s user web-search "{\"type\":\"stdio\",\"command\":\"${PYTHON_RESOLVED}\",\"args\":[\"${WEB_SEARCH_DIR}/server.py\"],\"env\":{\"WEB_SEARCH_SERVER_NAME\":\"web-search\",\"WEB_SEARCH_PROVIDER\":\"duckduckgo\",\"HTTP_TIMEOUT_SECONDS\":\"20\",\"MAX_FETCH_CHARS\":\"12000\"}}"
else
  log "skipping Claude MCP registration"
fi

cat > "${PATCH_NOTES_PATH}" <<EOF_NOTES
ARIS local Ollama patch notes

- executor model: ${EXECUTOR_MODEL}
- reviewer model: ${REVIEWER_MODEL}
- ollama host: ${OLLAMA_HOST}
- llm-chat MCP server copied to: ${LLM_CHAT_DIR}/server.py
- web-search MCP server copied to: ${WEB_SEARCH_DIR}/server.py
- skills rewritten in: ${SKILLS_DIR}

Skill rewrites performed by this script:
- mcp__codex__codex -> mcp__llm-chat__chat
- mcp__codex__codex-reply -> mcp__llm-chat__chat
- WebSearch -> mcp__web-search__search
- WebFetch -> mcp__web-search__fetch
EOF_NOTES

log "wrote ${SETTINGS_PATH}"
log "wrote ${PATCH_NOTES_PATH}"

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

  log "testing web-search MCP upstream endpoint"
  curl -fsS 'https://html.duckduckgo.com/html/?q=arxiv' >/dev/null

  if [[ ${SKIP_MCP_REGISTER} -eq 0 ]]; then
    log "checking Claude MCP registry"
    "${CLAUDE_RESOLVED}" mcp list >/dev/null
  fi
else
  log "skipping endpoint tests"
fi

cat <<EOF_DONE

Patch complete.

Files:
  settings: ${SETTINGS_PATH}
  llm-chat MCP server: ${LLM_CHAT_DIR}/server.py
  web-search MCP server: ${WEB_SEARCH_DIR}/server.py
  patch notes: ${PATCH_NOTES_PATH}

Configured models:
  executor: ${EXECUTOR_MODEL}
  reviewer: ${REVIEWER_MODEL}
  ollama host: ${OLLAMA_HOST}

Start Claude Code with:
  claude

If your Claude Code binary is not on PATH, use your normal launch command, for example:
  micromamba run -n aris claude

Suggested first checks inside Claude Code:
  /research-lit "your topic" — sources: web
  /auto-review-loop-llm "your topic"
EOF_DONE
