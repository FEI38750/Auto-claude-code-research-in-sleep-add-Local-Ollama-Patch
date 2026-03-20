# Local Ollama Patch Guide

This guide explains how to patch a standard ARIS install so it uses local Ollama models for both:

- executor via Ollama's Anthropic-compatible API
- reviewer via the built-in `llm-chat` MCP server and Ollama's OpenAI-compatible API
- web search/fetch via the built-in `web-search` MCP server

## When to use this

Use this after the normal ARIS install if you want to run ARIS with local free models instead of Claude/OpenAI-hosted APIs.

## Patch script

The patch script is:

`tools/patch_local_ollama.sh`

## Typical usage

From the repository root:

```bash
bash tools/patch_local_ollama.sh --ollama-host 127.0.0.1:11434
```

If your Ollama server runs on another port:

```bash
bash tools/patch_local_ollama.sh --ollama-host 127.0.0.1:11435
```

If `claude` is not on your shell `PATH`, pass it explicitly:

```bash
bash tools/patch_local_ollama.sh \
  --python /path/to/env/bin/python \
  --claude-bin /path/to/env/bin/claude
```

## Recommended model choices

Example 1: coder executor + general reviewer

```bash
bash tools/patch_local_ollama.sh \
  --executor-model qwen3-coder:latest \
  --reviewer-model qwen3.5:35b
```

Example 2: lighter executor

```bash
bash tools/patch_local_ollama.sh \
  --executor-model qwen3.5:35b \
  --reviewer-model qwen3.5:35b
```

Example 3: mixed local families

```bash
bash tools/patch_local_ollama.sh \
  --executor-model qwen3.5:35b \
  --reviewer-model deepseek-r1:32b
```

## What the script does

1. Backs up `~/.claude/settings.json` if it already exists
2. Installs `mcp-servers/llm-chat/requirements.txt` with the Python you choose
3. Copies `mcp-servers/llm-chat/server.py` into `~/.claude/mcp-servers/llm-chat/`
4. Copies `mcp-servers/web-search/server.py` into `~/.claude/mcp-servers/web-search/`
5. Copies ARIS skills into `~/.claude/skills/`
6. Rewrites copied skills so local-Ollama workflows use:
   - `mcp__llm-chat__chat` instead of `mcp__codex__codex` / `mcp__codex__codex-reply`
   - `mcp__web-search__search` / `mcp__web-search__fetch` instead of built-in `WebSearch` / `WebFetch`
7. Writes a local-Ollama `~/.claude/settings.json`
8. Registers `llm-chat` and `web-search` in Claude Code via `claude mcp add-json` when the CLI is available
9. Optionally smoke-tests the local Ollama executor/reviewer endpoints and the DuckDuckGo search endpoint

## Why this is needed

Claude Code's built-in `WebSearch` is not available for local Ollama models, so unmodified ARIS skills that depend on `WebSearch`/`WebFetch` will fail under a purely local executor.

This patch avoids that limitation by routing search and page fetches through a separate MCP server that works with local models.

## After the patch

Start Claude Code with your normal command, for example:

```bash
claude
```

or, if Claude lives inside a specific environment:

```bash
micromamba run -n aris claude
```

Recommended first commands inside Claude Code:

```text
/research-lit "your topic" — sources: web
/auto-review-loop-llm "your topic"
```

If you skipped MCP registration because `claude` was not available during patching, run the patch again later with `--claude-bin` or register the servers manually with `claude mcp add-json`.

## Official references

- ARIS repository: <https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep>
- Ollama Claude Code integration: <https://docs.ollama.com/integrations/claude-code>
- Ollama Anthropic compatibility: <https://docs.ollama.com/api/anthropic-compatibility>
- Ollama OpenAI compatibility: <https://docs.ollama.com/api/openai-compatibility>
