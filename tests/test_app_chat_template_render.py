"""#63: the opt-in `--render app_chat_template` trainer rendering.

`plain` (the default) is the historic trainer rendering and must stay
byte-for-byte unchanged.  `app_chat_template` renders the bytes the deployed
app/Cactus (`vendor/cactus-sdk/cactus-engine/src/tokenizer.cpp:620-696`) and the
Qwen3.5 `chat_template.jinja:100-154` produce at serving time: the assistant
generation boundary starts with the empty think block
`<think>\n\n</think>\n\n`, earlier assistant history stays plain, retention rows
that already carry a `<think>` block are not double-prefixed, and the empty
think block is masked out of the loss.
"""
from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest import mock

from scripts.train_qwen35_sft import (
    APP_CHAT_EMPTY_THINK,
    RENDER_APP_CHAT_TEMPLATE,
    RENDER_MODES,
    RENDER_PLAIN,
    encode_masked_row,
    messages_for,
    parse_args,
    render_app_chat_template,
    render_app_chat_template_with_spans,
    render_chat,
    target_message_indices,
    verify_masking_example,
)

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent / "bioaccumulator-benchmark-workspace"
V5_TRAIN = WORKSPACE / "corpus" / "targeted_v5" / "train.jsonl"


def single_target_row() -> dict:
    return {
        "source": "targeted_recipe_v5",
        "example_id": "unit_call",
        "target_turn": 2,
        "messages": [
            {"role": "system", "content": "System instructions", "train": False},
            {"role": "user", "content": "Bioaccumulator recipe: Banana for my Onion, 2 m2", "train": False},
            {"role": "assistant", "content": '<tool_call>\n{"name": "bioaccumulator_recipe"}\n</tool_call>', "train": True},
        ],
    }


def history_row() -> dict:
    return {
        "source": "targeted_recipe_v5",
        "example_id": "unit_multi_turn",
        "target_turn": 4,
        "messages": [
            {"role": "system", "content": "System instructions", "train": False},
            {"role": "user", "content": "recipe question", "train": False},
            {"role": "assistant", "content": "earlier recipe answer", "train": False},
            {"role": "user", "content": "Can I apply it in autumn?", "train": False},
            {"role": "assistant", "content": "Yes, you can.", "train": True},
        ],
    }


def retention_row() -> dict:
    return {
        "source": "teacher_distill_qwen3-8b",
        "messages": [
            {"role": "user", "content": "Which cherry variety is self-fertile?"},
            {
                "role": "assistant",
                "content": "<think>\nReasoning here.\n</think>\n\nThe Black Tartarian.",
            },
        ],
    }


class RendererTests(unittest.TestCase):
    def test_generation_boundary_gets_the_empty_think_block(self):
        text = render_app_chat_template(single_target_row())
        self.assertIn("<|im_start|>assistant\n" + APP_CHAT_EMPTY_THINK, text)
        self.assertTrue(
            text.endswith('<tool_call>\n{"name": "bioaccumulator_recipe"}\n</tool_call><|im_end|>')
        )

    def test_history_assistant_stays_plain(self):
        text, spans = render_app_chat_template_with_spans(history_row())
        history = spans[2]
        segment = text[history["start"]:history["end"]]
        self.assertEqual(segment, "<|im_start|>assistant\nearlier recipe answer<|im_end|>")
        self.assertEqual(history["content_start"], history["start"] + len("<|im_start|>assistant\n"))
        # The target turn is the only one with the empty think block.
        self.assertEqual(text.count(APP_CHAT_EMPTY_THINK), 1)

    def test_retention_row_is_not_double_prefixed(self):
        text = render_app_chat_template(retention_row())
        self.assertEqual(text.count("<think>"), 1)
        self.assertEqual(text.count("</think>"), 1)
        self.assertIn("<|im_start|>assistant\n<think>\nReasoning here.\n</think>\n\nThe Black Tartarian.<|im_end|>", text)

    def test_plain_render_is_unchanged(self):
        row = single_target_row()
        expected = (
            "<|im_start|>system\nSystem instructions<|im_end|>\n"
            "<|im_start|>user\nBioaccumulator recipe: Banana for my Onion, 2 m2<|im_end|>\n"
            '<|im_start|>assistant\n<tool_call>\n{"name": "bioaccumulator_recipe"}\n</tool_call><|im_end|>'
        )
        self.assertEqual(render_chat(row), expected)

    def test_render_mode_validation(self):
        with self.assertRaises(ValueError):
            render_app_chat_template_with_spans({"messages": [{"role": "assistant", "content": "x"}]})


class CharTokenizer:
    """A deterministic character tokenizer: one token per character."""

    def __call__(self, text, add_special_tokens=False, return_offsets_mapping=False, truncation=False):
        return {
            "input_ids": [ord(char) for char in text],
            "offset_mapping": [(i, i + 1) for i in range(len(text))],
        }

    def decode(self, ids, skip_special_tokens=False):
        return "".join(chr(token_id) for token_id in ids)


class MaskingTests(unittest.TestCase):
    def setUp(self):
        self.tokenizer = CharTokenizer()

    def test_empty_think_block_is_masked_out_of_the_loss(self):
        row = single_target_row()
        input_ids, labels = encode_masked_row(row, self.tokenizer, 10**9, False, RENDER_APP_CHAT_TEMPLATE)
        self.assertEqual(len(input_ids), len(labels))
        decoded = self.tokenizer.decode([t for t in labels if t != -100])
        self.assertEqual(decoded, messages_for(row)[2]["content"] + "<|im_end|>")
        # The empty think block is prompt, not target.
        self.assertNotIn("<think>", decoded)

    def test_plain_masking_still_learns_the_bare_target(self):
        row = single_target_row()
        _input_ids, labels = encode_masked_row(row, self.tokenizer, 10**9, False, RENDER_PLAIN)
        decoded = self.tokenizer.decode([t for t in labels if t != -100])
        self.assertEqual(decoded, messages_for(row)[2]["content"] + "<|im_end|>")

    def test_verification_example_decodes_app_target(self):
        verification = verify_masking_example([single_target_row()], self.tokenizer, RENDER_APP_CHAT_TEMPLATE)
        self.assertIsNotNone(verification)
        self.assertTrue(verification["decode_matches_target"])
        self.assertTrue(verification["labels_only_inside_target_slice"])

    def test_target_message_indices_unchanged(self):
        self.assertEqual(target_message_indices(single_target_row()), [2])


class CliTests(unittest.TestCase):
    def test_default_render_is_plain(self):
        with mock.patch("sys.argv", ["train_qwen35_sft.py"]):
            args = parse_args()
        self.assertEqual(args.render, RENDER_PLAIN)
        self.assertFalse(args.assistant_only_loss)

    def test_app_chat_template_is_selectable(self):
        with mock.patch("sys.argv", ["train_qwen35_sft.py", "--render", RENDER_APP_CHAT_TEMPLATE]):
            args = parse_args()
        self.assertEqual(args.render, RENDER_APP_CHAT_TEMPLATE)
        self.assertIn(RENDER_APP_CHAT_TEMPLATE, RENDER_MODES)


class ParityTests(unittest.TestCase):
    """The trainer prefix must equal the runner's deployed serving bytes."""

    @classmethod
    def setUpClass(cls):
        if not V5_TRAIN.is_file():
            raise unittest.SkipTest(f"targeted_v5 corpus not available at {V5_TRAIN}")
        import sys

        for path in (str(WORKSPACE), str(ROOT)):
            if path not in sys.path:
                sys.path.insert(0, path)
        from scripts import run_hf_gpu_tool_benchmark as runner

        cls.runner = runner
        cls.rows = [json.loads(line) for line in V5_TRAIN.read_text(encoding="utf-8").splitlines() if line.strip()]

    def _sampled_targeted(self):
        targeted = [row for row in self.rows if row.get("source") == "targeted_recipe_v5"]
        self.assertTrue(targeted)
        return targeted[:60]

    def test_prefix_up_to_the_generation_boundary_equals_cactus(self):
        checked = 0
        for row in self._sampled_targeted():
            messages = [{"role": m["role"], "content": m["content"]} for m in messages_for(row)]
            target = row.get("target_turn", row["target_turns"][-1])
            text, spans = render_app_chat_template_with_spans(row)
            trainer_prefix = text[: spans[target]["content_start"]]
            cactus = self.runner.cactus_qwen_prompt(messages[:target])
            self.assertEqual(trainer_prefix, cactus, row.get("example_id"))
            checked += 1
        self.assertGreater(checked, 0)

    def test_prefix_ends_with_the_empty_think_block(self):
        for row in self._sampled_targeted():
            target = row.get("target_turn", row["target_turns"][-1])
            text, spans = render_app_chat_template_with_spans(row)
            prefix = text[: spans[target]["content_start"]]
            self.assertTrue(
                prefix.endswith("<|im_start|>assistant\n" + APP_CHAT_EMPTY_THINK),
                row.get("example_id"),
            )


if __name__ == "__main__":
    unittest.main()
