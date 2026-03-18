# Local Ollama Patch Guide

This guide explains how to patch a standard ARIS install so it uses local Ollama models for both:

- executor via Ollama's Anthropic-compatible API
- reviewer via the built-in `llm-chat` MCP server and Ollama's OpenAI-compatible API

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

## Recommended model choices

Example 1: coder executor + general reviewer

```bash
bash tools/patch_local_ollama.sh \
  --executor-model qwen3-coder-next:latest \
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
4. Copies ARIS skills into `~/.claude/skills/`
5. Writes a local-Ollama `~/.claude/settings.json`
6. Writes a one-time skill rewrite prompt file into `~/.claude/`
7. Optionally smoke-tests the local Ollama executor and reviewer endpoints

## After the patch

Start Claude Code with your normal command, for example:

```bash
claude
```

or, if Claude lives inside a specific environment:

```bash
micromamba run -n aris claude
```

Recommended first command inside Claude Code:

```text
/auto-review-loop-llm "your topic"
```

For broader ARIS workflow compatibility, paste the generated rewrite prompt into Claude Code once.

## Official references

- ARIS repository: <https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep>
- Ollama Claude Code integration: <https://docs.ollama.com/integrations/claude-code>
- Ollama Anthropic compatibility: <https://docs.ollama.com/api/anthropic-compatibility>
- Ollama OpenAI compatibility: <https://docs.ollama.com/api/openai-compatibility>
