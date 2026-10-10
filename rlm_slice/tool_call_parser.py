"""Model-initiated tool-call detection, mirroring Cactus's own extraction.

Qwen3.5-finetune's model is being trained (separately, see chainlink #4) to
decide mid-answer when it needs a tool, and to signal this the same way
Cactus's native engine already parses: a `<tool_call>{"name": ..., "arguments":
{...}}</tool_call>` block in its own decoded output (cactus-engine/src/
chat_tools.h's `extract_qwen_tool_calls`, used by `cactus_complete` on both the
Dart and Python bindings -- see `cactus-sdk/python/cactus/bindings/cactus.py`).

This module replicates that extraction as a small, dependency-free Python
utility, so `rlm_slice/model_host.py` can detect the same signal without
switching off plain HF `transformers` generation (needed for the harness's
existing MCQ logprob scoring, `ModelHost.score_with_trace`, which the Cactus
engine does not expose).

Mirrors the C++ extraction's actual behaviour:
  - find a `<tool_call>...</tool_call>` block (there may be more than one);
  - keep only ones whose trimmed inner content starts with `{` (a bare
    non-JSON block is not a call);
  - parse the inner content as JSON, falling back to a light single-quote
    normalization for models that emit Python-dict-literal style instead of
    strict JSON (a documented quirk the C++ side also guards against via its
    own `py_literal_to_json` helper).
"""

from __future__ import annotations

import ast
import json
import re
from typing import Any

_TOOL_CALL_RE = re.compile(r"<tool_call>(.*?)</tool_call>", re.DOTALL)


def _parse_call_body(inner: str) -> dict[str, Any] | None:
    """Parse one `<tool_call>` block's inner text into {"name", "arguments"}.

    Tries strict JSON first (the documented/expected format), then falls back
    to `ast.literal_eval` for Python-dict-literal-style output (single quotes,
    `True`/`False`/`None`) -- the same real-world quirk Cactus's own C++
    extraction normalizes for. Returns None for anything that parses to
    something other than a dict, or that fails both ways.
    """
    try:
        parsed = json.loads(inner)
    except json.JSONDecodeError:
        try:
            parsed = ast.literal_eval(inner)
        except (ValueError, SyntaxError):
            return None
    if not isinstance(parsed, dict):
        return None
    return parsed


def extract_tool_calls(text: str) -> list[dict[str, Any]]:
    """Return every well-formed tool call found in `text`, in order.

    Each result is `{"name": str, "arguments": dict}`. A `<tool_call>` block
    that doesn't parse to a dict with a usable "name", or whose trimmed inner
    content doesn't start with "{", is silently skipped -- matching the C++
    side's own behaviour of only collecting candidates that look like JSON
    objects, so a malformed call degrades to "no call found" rather than
    raising.
    """
    calls: list[dict[str, Any]] = []
    for match in _TOOL_CALL_RE.finditer(text):
        inner = match.group(1).strip()
        if not inner.startswith("{"):
            continue
        parsed = _parse_call_body(inner)
        if parsed is None:
            continue
        name = parsed.get("name")
        if not isinstance(name, str) or not name:
            continue
        arguments = parsed.get("arguments", {})
        if not isinstance(arguments, dict):
            continue
        calls.append({"name": name, "arguments": arguments})
    return calls


def strip_tool_calls(text: str) -> str:
    """Remove every `<tool_call>...</tool_call>` block from `text`.

    Mirrors `model_service.dart`'s `_cleanResponse` stripping on the Dart
    side, so a trace shown to a human (or logged) never includes the raw
    tool-call JSON -- whether or not the block was well-formed enough for
    `extract_tool_calls` to parse it.
    """
    return _TOOL_CALL_RE.sub("", text)
