"""#20: the recipe form renders candidate 4's instruction prompt bytes.

The form has no model tool decision. Its QUICK pass must still be exactly the
turn candidate 4 was trained on: empty history, the canonical trigger, the
synthesized `<tool_call>` assistant text, and the served-view tool context.

This test drives the same comparison script the reviewer runs
(`natural_farming_chat/tool/compare_form_prompt_parity.py`) against the
read-only `issue_64_ckpt423_seed_{42,43,44}` development results. It never reads
the test split.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "natural_farming_chat"
WORKSPACE = ROOT.parent / "bioaccumulator-benchmark-workspace"
SCRIPT = APP / "tool" / "compare_form_prompt_parity.py"
SEEDS = (42, 43, 44)


def _have_inputs() -> bool:
    if not WORKSPACE.is_dir() or not SCRIPT.is_file():
        return False
    if shutil.which("dart") is None:
        return False
    for seed in SEEDS:
        stem = f"bioaccumulator_gpu_issue_64_ckpt423_seed_{seed}"
        if not (
            WORKSPACE
            / "results"
            / "bioaccumulator"
            / "gpu_hf"
            / "development"
            / f"issue_64_ckpt423_seed_{seed}"
            / f"{stem}.results.json"
        ).is_file():
            return False
    return True


@unittest.skipUnless(
    _have_inputs(),
    "needs dart plus the read-only bioaccumulator development results",
)
class RecipeFormPromptParityTests(unittest.TestCase):
    def test_form_path_matches_candidate_4_byte_for_byte(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            summary_path = Path(tmp) / "summary.json"
            export_path = Path(tmp) / "export.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--summary",
                    str(summary_path),
                    "--export",
                    str(export_path),
                ],
                cwd=APP,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=completed.stdout + completed.stderr,
            )
            summary = json.loads(summary_path.read_text(encoding="utf-8"))

        totals = summary["totals"]
        self.assertEqual(len(summary["exact_trigger_case_ids"]), 14)
        self.assertEqual(summary["called_correctly_on_every_seed_count"], 18)
        self.assertEqual(totals["assistant_total"], 14 * len(SEEDS))
        self.assertEqual(
            totals["assistant_matched"], totals["assistant_total"]
        )
        self.assertEqual(totals["instruction_total"], 14 * len(SEEDS))
        self.assertEqual(
            totals["instruction_matched"], totals["instruction_total"]
        )
        self.assertEqual(
            totals["tool_context_matched"], totals["tool_context_total"]
        )
        self.assertTrue(summary["app_tools_equal_runner_tools"])
        self.assertEqual(summary["mismatches"], [])


if __name__ == "__main__":
    unittest.main()
