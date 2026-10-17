"""#44: assistant-only loss masking honours the #43 target marker."""
from __future__ import annotations

import unittest
from pathlib import Path

from scripts.train_qwen35_sft import (
    build_masked_dataset,
    encode_masked_row,
    messages_for,
    render_chat,
    render_chat_with_spans,
    target_message_indices,
    verify_masking_example,
)

ROOT = Path(__file__).resolve().parents[1]
TOKENIZER_DIR = ROOT / "outputs/qwen35-combined-merged"


def load_tokenizer():
    if not (TOKENIZER_DIR / "tokenizer_config.json").is_file():
        raise unittest.SkipTest(f"tokenizer not available at {TOKENIZER_DIR}")
    from transformers import AutoTokenizer

    return AutoTokenizer.from_pretrained(
        str(TOKENIZER_DIR), local_files_only=True, trust_remote_code=True
    )


def marked_row() -> dict:
    return {
        "source": "targeted_decision_v2",
        "example_id": "unit_marked",
        "target_turn": 4,
        "messages": [
            {"role": "system", "content": "System instructions", "train": False},
            {"role": "user", "content": "Earlier question", "train": False},
            {"role": "assistant", "content": "Earlier answer", "train": False},
            {"role": "user", "content": "Compare comfrey with cabbage.", "train": False},
            {
                "role": "assistant",
                "content": '<tool_call>\n{"name": "bioaccumulator_ratio", '
                '"arguments": {"crop": "Cabbage", "candidate_plant": "Comfrey"}}\n</tool_call>',
                "train": True,
            },
        ],
    }


class TargetMessageIndexTests(unittest.TestCase):
    def test_target_turn_from_marker(self):
        self.assertEqual(target_message_indices(marked_row()), [4])

    def test_unmarked_row_uses_assistant_turns(self):
        row = {
            "messages": [
                {"role": "user", "content": "question"},
                {"role": "assistant", "content": "answer"},
            ]
        }
        self.assertEqual(target_message_indices(row), [1])

    def test_train_flags_without_target_turn(self):
        row = {
            "messages": [
                {"role": "user", "content": "q1"},
                {"role": "assistant", "content": "a1", "train": False},
                {"role": "user", "content": "q2"},
                {"role": "assistant", "content": "a2", "train": True},
            ]
        }
        self.assertEqual(target_message_indices(row), [3])

    def test_target_turn_mismatch_fails(self):
        row = marked_row()
        row["target_turn"] = 2
        with self.assertRaises(ValueError):
            target_message_indices(row)


class MaskingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tokenizer = load_tokenizer()

    def test_only_target_assistant_tokens_carry_labels(self):
        row = marked_row()
        input_ids, labels = encode_masked_row(row, self.tokenizer, 4096, True)
        self.assertEqual(len(input_ids), len(labels))
        decoded = self.tokenizer.decode(
            [token for token in labels if token != -100], skip_special_tokens=False
        )
        expected = messages_for(row)[row["target_turn"]]["content"] + "<|im_end|>"
        self.assertEqual(decoded, expected)
        self.assertGreater(sum(1 for label in labels if label == -100), 0)

    def test_history_and_user_tokens_are_masked(self):
        row = marked_row()
        _input_ids, labels = encode_masked_row(row, self.tokenizer, 4096, True)
        _, spans = render_chat_with_spans(row)
        text = render_chat(row)        # No token whose character span sits in an earlier message is labelled.
        encoded = self.tokenizer(
            text, add_special_tokens=False, return_offsets_mapping=True
        )
        for token_index, (start, end) in enumerate(encoded["offset_mapping"]):
            for span_index, span in enumerate(spans):
                if span_index == row["target_turn"]:
                    continue
                if end > start >= span["start"] and end <= span["end"]:
                    self.assertEqual(labels[token_index], -100)

    def test_masked_dataset_reports_fraction(self):
        dataset, stats = build_masked_dataset(
            [marked_row()], self.tokenizer, 4096, True
        )
        self.assertEqual(stats["rows"], 1)
        self.assertEqual(stats["rows_over_max_seq_len"], 0)
        self.assertGreater(stats["labelled_tokens"], 0)
        self.assertGreater(stats["masked_token_fraction"], 0)
        self.assertLess(stats["masked_token_fraction"], 1)
        self.assertIn("labels", dataset.column_names)

    def test_verification_example_decodes_target(self):
        verification = verify_masking_example([marked_row()], self.tokenizer)
        self.assertIsNotNone(verification)
        self.assertTrue(verification["decode_matches_target"])
        self.assertTrue(verification["labels_only_inside_target_slice"])


if __name__ == "__main__":
    unittest.main()
