"""#47: per-epoch checkpoint and eval-loss reporting for checkpoint selection."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from scripts.train_qwen35_sft import (
    checkpoint_step,
    eval_loss_history,
    list_checkpoints,
)


class CheckpointStepTests(unittest.TestCase):
    def test_reads_step_suffix(self):
        self.assertEqual(checkpoint_step(Path("checkpoint-140")), 140)

    def test_rejects_non_checkpoint(self):
        self.assertIsNone(checkpoint_step(Path("final")))
        self.assertIsNone(checkpoint_step(Path("checkpoint-abc")))


class EvalLossHistoryTests(unittest.TestCase):
    def test_keeps_every_eval_entry_in_order(self):
        log_history = [
            {"loss": 0.7, "step": 10, "epoch": 0.5},
            {"eval_loss": 0.53, "step": 70, "epoch": 1.0},
            {"loss": 0.4, "step": 80, "epoch": 1.1},
            {"eval_loss": 0.55, "step": 140, "epoch": 2.0},
            {"eval_loss": 0.57, "step": 210, "epoch": 3.0},
        ]
        self.assertEqual(
            eval_loss_history(log_history),
            [
                {"step": 70, "epoch": 1.0, "eval_loss": 0.53},
                {"step": 140, "epoch": 2.0, "eval_loss": 0.55},
                {"step": 210, "epoch": 3.0, "eval_loss": 0.57},
            ],
        )

    def test_empty_history(self):
        self.assertEqual(eval_loss_history([{"loss": 0.7}]), [])


class ListCheckpointsTests(unittest.TestCase):
    def test_orders_by_step_and_ignores_other_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("checkpoint-210", "checkpoint-70", "checkpoint-140", "final"):
                (root / name).mkdir()
            (root / "training_metrics.json").write_text("{}\n", encoding="utf-8")
            self.assertEqual(
                list_checkpoints(root),
                [
                    {"step": 70, "path": str(root / "checkpoint-70")},
                    {"step": 140, "path": str(root / "checkpoint-140")},
                    {"step": 210, "path": str(root / "checkpoint-210")},
                ],
            )

    def test_no_checkpoints(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(list_checkpoints(Path(tmp)), [])


if __name__ == "__main__":
    unittest.main()
