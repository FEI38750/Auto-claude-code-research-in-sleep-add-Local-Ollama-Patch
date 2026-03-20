#!/usr/bin/env python3
"""Minimal web search + fetch MCP server.

Default behavior:
- search: DuckDuckGo HTML search, no API key required
- fetch: direct URL fetch with lightweight HTML-to-text extraction

Optional environment variables:
    WEB_SEARCH_SERVER_NAME   - MCP server name (default: web-search)
    WEB_SEARCH_PROVIDER      - brave or duckduckgo (default: duckduckgo)
    BRAVE_API_KEY            - Required when WEB_SEARCH_PROVIDER=brave
    HTTP_TIMEOUT_SECONDS     - Network timeout (default: 20)
    MAX_FETCH_CHARS          - Default fetch output cap (default: 12000)
"""

from __future__ import annotations

import html
from html.parser import HTMLParser
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

sys.stdout = os.fdopen(sys.stdout.fileno(), "wb", buffering=0)
sys.stdin = os.fdopen(sys.stdin.fileno(), "rb", buffering=0)

SERVER_NAME = os.environ.get("WEB_SEARCH_SERVER_NAME", "web-search")
SEARCH_PROVIDER = os.environ.get("WEB_SEARCH_PROVIDER", "duckduckgo").strip().lower()
BRAVE_API_KEY = os.environ.get("BRAVE_API_KEY", "")
HTTP_TIMEOUT_SECONDS = float(os.environ.get("HTTP_TIMEOUT_SECONDS", "20"))
MAX_FETCH_CHARS = int(os.environ.get("MAX_FETCH_CHARS", "12000"))

DEBUG_LOG = os.path.join(tempfile.gettempdir(), f"{SERVER_NAME}-mcp-debug.log")
_use_ndjson = False


def debug_log(msg: str) -> None:
    try:
        with open(DEBUG_LOG, "a", encoding="utf-8") as f:
            import datetime
            f.write(f"{datetime.datetime.now()}: {msg}\n")
    except Exception:
        pass


def send_response(response: dict) -> None:
    global _use_ndjson
    payload = json.dumps(response, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if _use_ndjson:
        sys.stdout.write(payload + b"\n")
    else:
        header = f"Content-Length: {len(payload)}\r\n\r\n".encode("utf-8")
        sys.stdout.write(header + payload)
    sys.stdout.flush()


def make_request(url: str, headers: dict | None = None) -> str:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/133.0 Safari/537.36"
            ),
            "Accept-Language": "en-US,en;q=0.9",
            **(headers or {}),
        },
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
        charset = resp.headers.get_content_charset() or "utf-8"
        raw = resp.read()
    return raw.decode(charset, errors="replace")


class TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self.skip_depth = 0
        self.title_parts: list[str] = []
        self.in_title = False

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in {"script", "style", "noscript", "svg"}:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag == "title":
            self.in_title = True
        if tag in {"p", "div", "section", "article", "main", "br", "li", "tr", "h1", "h2", "h3"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript", "svg"} and self.skip_depth:
            self.skip_depth -= 1
            return
        if tag == "title":
            self.in_title = False
        if self.skip_depth:
            return
        if tag in {"p", "div", "section", "article", "main", "li", "tr", "h1", "h2", "h3"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self.skip_depth:
            return
        if self.in_title:
            self.title_parts.append(data)
        self.parts.append(data)

    def title(self) -> str:
        return collapse_ws(" ".join(self.title_parts))

    def text(self) -> str:
        return normalize_text("".join(self.parts))


def collapse_ws(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(text or "")).strip()


def normalize_text(text: str) -> str:
    text = html.unescape(text or "")
    text = text.replace("\r", "\n")
    text = re.sub(r"\n\s*\n\s*\n+", "\n\n", text)
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.split("\n")]
    return "\n".join(line for line in lines if line).strip()


def extract_page_text(body: str) -> tuple[str, str]:
    parser = TextExtractor()
    parser.feed(body)
    return parser.title(), parser.text()


def decode_duckduckgo_link(href: str) -> str:
    if not href:
        return ""
    if href.startswith("//"):
        href = "https:" + href
    parsed = urllib.parse.urlparse(href)
    if parsed.netloc.endswith("duckduckgo.com") and parsed.path.startswith("/l/"):
        qs = urllib.parse.parse_qs(parsed.query)
        if "uddg" in qs and qs["uddg"]:
            return qs["uddg"][0]
    return href


def duckduckgo_search(query: str, max_results: int) -> list[dict]:
    url = "https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({"q": query})
    body = make_request(url)

    results: list[dict] = []
    seen: set[str] = set()
    anchor_re = re.compile(
        r'<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>(.*?)</a>',
        re.IGNORECASE | re.DOTALL,
    )
    snippet_re = re.compile(r'<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>', re.IGNORECASE | re.DOTALL)
    snippets = [collapse_ws(re.sub(r"<[^>]+>", " ", s)) for s in snippet_re.findall(body)]

    for idx, match in enumerate(anchor_re.finditer(body)):
        href, title_html = match.groups()
        final_url = decode_duckduckgo_link(html.unescape(href))
        if not final_url or final_url in seen:
            continue
        seen.add(final_url)
        title = collapse_ws(re.sub(r"<[^>]+>", " ", title_html))
        snippet = snippets[idx] if idx < len(snippets) else ""
        results.append({"title": title or final_url, "url": final_url, "snippet": snippet})
        if len(results) >= max_results:
            break

    if not results:
        generic_anchor_re = re.compile(r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', re.IGNORECASE | re.DOTALL)
        for href, title_html in generic_anchor_re.findall(body):
            final_url = decode_duckduckgo_link(html.unescape(href))
            if not final_url.startswith("http") or final_url in seen:
                continue
            title = collapse_ws(re.sub(r"<[^>]+>", " ", title_html))
            if not title or "duckduckgo" in final_url.lower():
                continue
            seen.add(final_url)
            results.append({"title": title, "url": final_url, "snippet": ""})
            if len(results) >= max_results:
                break

    return results


def brave_search(query: str, max_results: int) -> list[dict]:
    if not BRAVE_API_KEY:
        raise RuntimeError("BRAVE_API_KEY environment variable not set")
    url = "https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode(
        {"q": query, "count": max_results}
    )
    body = make_request(url, headers={"Accept": "application/json", "X-Subscription-Token": BRAVE_API_KEY})
    payload = json.loads(body)
    results = []
    for item in payload.get("web", {}).get("results", []):
        results.append(
            {
                "title": collapse_ws(item.get("title", "")),
                "url": item.get("url", ""),
                "snippet": collapse_ws(item.get("description", "")),
            }
        )
        if len(results) >= max_results:
            break
    return results


def search_web(query: str, max_results: int) -> list[dict]:
    if SEARCH_PROVIDER == "brave":
        return brave_search(query, max_results)
    return duckduckgo_search(query, max_results)


def render_search_results(query: str, results: list[dict]) -> str:
    if not results:
        return f'No search results found for "{query}".'
    lines = [f'Search results for "{query}":']
    for idx, item in enumerate(results, start=1):
        lines.append(f"{idx}. {item['title']}")
        lines.append(f"   URL: {item['url']}")
        if item.get("snippet"):
            lines.append(f"   Snippet: {item['snippet']}")
    return "\n".join(lines)


def fetch_url(url: str, max_chars: int) -> str:
    body = make_request(url)
    title, text = extract_page_text(body)
    if not text:
        text = collapse_ws(re.sub(r"<[^>]+>", " ", body))
    text = text[:max_chars].rstrip()
    lines = [f"URL: {url}"]
    if title:
        lines.append(f"Title: {title}")
    lines.append("")
    lines.append(text or "[no extractable text]")
    return "\n".join(lines)


def success_response(request_id, text: str) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {"content": [{"type": "text", "text": text}]},
    }


def error_response(request_id, message: str) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {
            "content": [{"type": "text", "text": f"Error: {message}"}],
            "isError": True,
        },
    }


def handle_request(request: dict) -> dict | None:
    method = request.get("method", "")
    params = request.get("params", {})
    request_id = request.get("id")

    if request_id is None:
        return None

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": "1.0.0"},
            },
        }

    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "tools": [
                    {
                        "name": "search",
                        "description": "Search the web and return titled results with URLs and snippets.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "query": {"type": "string", "description": "Search query"},
                                "max_results": {
                                    "type": "integer",
                                    "description": "Maximum number of results to return",
                                    "default": 8,
                                },
                            },
                            "required": ["query"],
                        },
                    },
                    {
                        "name": "fetch",
                        "description": "Fetch a URL and return extracted page text.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "url": {"type": "string", "description": "URL to fetch"},
                                "max_chars": {
                                    "type": "integer",
                                    "description": "Maximum number of extracted characters to return",
                                    "default": MAX_FETCH_CHARS,
                                },
                            },
                            "required": ["url"],
                        },
                    },
                ]
            },
        }

    if method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})
        try:
            if tool_name == "search":
                query = arguments.get("query", "").strip()
                max_results = int(arguments.get("max_results", 8))
                if not query:
                    return error_response(request_id, "query is required")
                results = search_web(query, max(1, min(max_results, 10)))
                return success_response(request_id, render_search_results(query, results))
            if tool_name == "fetch":
                url = arguments.get("url", "").strip()
                max_chars = int(arguments.get("max_chars", MAX_FETCH_CHARS))
                if not url:
                    return error_response(request_id, "url is required")
                if not urllib.parse.urlparse(url).scheme:
                    return error_response(request_id, "url must include http:// or https://")
                return success_response(request_id, fetch_url(url, max(1000, min(max_chars, 50000))))
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"},
            }
        except urllib.error.HTTPError as exc:
            return error_response(request_id, f"HTTP {exc.code} while accessing {exc.url}")
        except urllib.error.URLError as exc:
            return error_response(request_id, f"network error: {exc.reason}")
        except Exception as exc:
            debug_log(f"tools/call exception for {tool_name}: {exc}")
            return error_response(request_id, str(exc))

    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32601, "message": f"Unknown method: {method}"},
    }


def read_message():
    global _use_ndjson
    line = sys.stdin.readline()
    if not line:
        return None
    line = line.decode("utf-8").rstrip("\r\n")

    if line.lower().startswith("content-length:"):
        try:
            content_length = int(line.split(":", 1)[1].strip())
        except ValueError:
            return None
        while True:
            hdr = sys.stdin.readline()
            if not hdr:
                return None
            if hdr.decode("utf-8").rstrip("\r\n") == "":
                break
        body = sys.stdin.read(content_length)
        try:
            return json.loads(body.decode("utf-8"))
        except Exception:
            return None

    if line.startswith("{") or line.startswith("["):
        _use_ndjson = True
        try:
            return json.loads(line)
        except Exception:
            return None
    return None


def main() -> None:
    debug_log(f"=== {SERVER_NAME} MCP Server Starting ===")
    debug_log(f"provider={SEARCH_PROVIDER}")
    while True:
        try:
            request = read_message()
            if request is None:
                break
            response = handle_request(request)
            if response:
                send_response(response)
        except Exception as exc:
            debug_log(f"main loop exception: {exc}")
    debug_log("=== Server Exiting ===")


if __name__ == "__main__":
    main()
