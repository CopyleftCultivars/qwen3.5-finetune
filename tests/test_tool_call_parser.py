from __future__ import annotations

import unittest

from rlm_slice.tool_call_parser import extract_tool_calls, strip_tool_calls


class ExtractToolCallsTests(unittest.TestCase):
    """Mirrors cactus-engine's extract_qwen_tool_calls (chat_tools.h) behaviour,
    since the model is trained to emit the same native format the on-device
    engine and the production app already parse."""

    def test_single_well_formed_call(self):
        text = 'Sure, let me check.\n<tool_call>{"name": "get_weather", "arguments": {"city": "SF"}}</tool_call>'
        calls = extract_tool_calls(text)
        self.assertEqual(calls, [{"name": "get_weather", "arguments": {"city": "SF"}}])

    def test_no_tool_call_returns_empty_list(self):
        self.assertEqual(extract_tool_calls("Just a plain answer, no tools needed."), [])

    def test_multiple_calls_extracted_in_order(self):
        text = (
            '<tool_call>{"name": "a", "arguments": {}}</tool_call>'
            "some text in between"
            '<tool_call>{"name": "b", "arguments": {"x": 1}}</tool_call>'
        )
        calls = extract_tool_calls(text)
        self.assertEqual([c["name"] for c in calls], ["a", "b"])
        self.assertEqual(calls[1]["arguments"], {"x": 1})

    def test_python_literal_style_falls_back_correctly(self):
        # Single-quoted, Python-dict-literal style -- not strict JSON. The C++
        # side normalizes this via its own py_literal_to_json helper; this
        # mirrors that behaviour via ast.literal_eval.
        text = "<tool_call>{'name': 'send_message', 'arguments': {'recipient': 'Bob'}}</tool_call>"
        calls = extract_tool_calls(text)
        self.assertEqual(calls, [{"name": "send_message", "arguments": {"recipient": "Bob"}}])

    def test_missing_arguments_key_defaults_to_empty_dict(self):
        text = '<tool_call>{"name": "ping"}</tool_call>'
        calls = extract_tool_calls(text)
        self.assertEqual(calls, [{"name": "ping", "arguments": {}}])

    def test_non_json_inner_content_is_skipped(self):
        # Inner content doesn't start with "{" -- not a call, per the C++
        # extraction's own front-anchor check.
        text = "<tool_call>not a tool call at all</tool_call>"
        self.assertEqual(extract_tool_calls(text), [])

    def test_malformed_json_is_skipped_not_raised(self):
        text = '<tool_call>{"name": "broken", "arguments": {unterminated</tool_call>'
        self.assertEqual(extract_tool_calls(text), [])

    def test_missing_name_is_skipped(self):
        text = '<tool_call>{"arguments": {"x": 1}}</tool_call>'
        self.assertEqual(extract_tool_calls(text), [])

    def test_non_dict_arguments_is_skipped(self):
        text = '<tool_call>{"name": "weird", "arguments": "not a dict"}</tool_call>'
        self.assertEqual(extract_tool_calls(text), [])

    def test_unclosed_tag_is_not_matched(self):
        text = '<tool_call>{"name": "incomplete", "arguments": {}}'
        self.assertEqual(extract_tool_calls(text), [])


class StripToolCallsTests(unittest.TestCase):
    def test_strips_single_block_and_keeps_surrounding_text(self):
        text = 'Before. <tool_call>{"name": "x", "arguments": {}}</tool_call> After.'
        self.assertEqual(strip_tool_calls(text), "Before.  After.")

    def test_strips_multiple_blocks(self):
        text = '<tool_call>{"a": 1}</tool_call>middle<tool_call>{"b": 2}</tool_call>'
        self.assertEqual(strip_tool_calls(text), "middle")

    def test_no_op_when_no_tool_call_present(self):
        text = "Nothing to strip here."
        self.assertEqual(strip_tool_calls(text), text)

    def test_strips_even_malformed_blocks(self):
        # Cleaning for display should never leak raw tool-call text, even if
        # extract_tool_calls itself would have skipped the block as unparseable.
        text = "Before <tool_call>garbage, not json</tool_call> after"
        self.assertEqual(strip_tool_calls(text), "Before  after")


if __name__ == "__main__":
    unittest.main()
