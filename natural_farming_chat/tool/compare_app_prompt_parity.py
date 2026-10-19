#!/usr/bin/env python3
"""Compare the app's exported prompts with candidate 4's #64 run records.

The Dart exporter (`tool/export_recipe_turn_messages.dart`) builds the app's
real decision and instruction message lists for every v3 **development** turn
and exports the exact six-tool catalog. This script renders those lists with
the benchmark runner's own `cactus_qwen_prompt` (default `runner_default`
assistant prefix) and compares them byte for byte with the `decision_prompt`
and `recipe_instruction_prompt` fields recorded in the candidate-4
`issue_64_ckpt423_seed_{42,43,44}` results.

The test split is never read. The reference workspace is read-only: this
script and the Dart exporter only read it, and the JSON summary is written in
this repository.

Run with the workspace's local Python (it has the runner's tokenizers
dependency)::

    /home/goya/anaconda3/envs/clc_local/bin/python \
        tool/compare_app_prompt_parity.py
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

APP_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = APP_DIR.parent
DEFAULT_WORKSPACE = Path(
    os.environ.get(
        "BIOACCUMULATOR_WORKSPACE",
        REPO_ROOT.parent / "bioaccumulator-benchmark-workspace",
    )
)
DEFAULT_SUMMARY = REPO_ROOT / "docs" / "issue-19-prompt-parity-2026-10-19.json"
CANDIDATE_4_CHECKPOINT = "issue_64_ckpt423"
SEEDS = (42, 43, 44)


def _results_path(workspace: Path, seed: int) -> Path:
    stem = f"bioaccumulator_gpu_issue_64_ckpt423_seed_{seed}"
    return (
        workspace
        / "results"
        / "bioaccumulator"
        / "gpu_hf"
        / "development"
        / f"issue_64_ckpt423_seed_{seed}"
        / f"{stem}.results.json"
    )


def _first_difference(actual: str, expected: str) -> dict[str, Any]:
    limit = min(len(actual), len(expected))
    index = next((i for i in range(limit) if actual[i] != expected[i]), limit)
    return {
        "byte_index": index,
        "actual_total_bytes": len(actual),
        "expected_total_bytes": len(expected),
        "actual_context": actual[max(0, index - 60) : index + 60],
        "expected_context": expected[max(0, index - 60) : index + 60],
    }


def _explain_mismatch(
    kind: str,
    seed: int,
    key: str,
    actual: str,
    expected: str,
) -> dict[str, Any]:
    return {
        "kind": kind,
        "seed": seed,
        "turn": key,
        "explanation": (
            "Rendered app prompt differs from the recorded candidate-4 prompt; "
            "see the byte offset and surrounding text."
        ),
        **_first_difference(actual, expected),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=DEFAULT_WORKSPACE)
    parser.add_argument("--summary", type=Path, default=DEFAULT_SUMMARY)
    parser.add_argument(
        "--dart",
        default="dart",
        help="Dart executable used to run the app exporter",
    )
    parser.add_argument(
        "--export",
        type=Path,
        default=None,
        help="Keep the intermediate app export at this path",
    )
    parser.add_argument(
        "--skip-export",
        action="store_true",
        help="Reuse --export instead of running the Dart exporter",
    )
    args = parser.parse_args(argv)

    workspace = args.workspace.resolve()
    if not (workspace / "scenarios" / "v3" / "development.jsonl").is_file():
        raise SystemExit(f"reference workspace not found: {workspace}")
    sys.path.insert(0, str(workspace / "scripts"))
    sys.path.insert(0, str(workspace))

    import run_hf_gpu_tool_benchmark as runner  # noqa: PLC0415

    export_path = args.export or Path("/tmp/issue-19-app-prompt-export.json")
    if not args.skip_export:
        command = [
            args.dart,
            "run",
            "tool/export_recipe_turn_messages.dart",
            "--scenarios",
            str(workspace / "scenarios" / "v3" / "development.jsonl"),
            "--output",
            str(export_path),
        ]
        for seed in SEEDS:
            command.extend(["--results", str(_results_path(workspace, seed))])
        subprocess.run(command, cwd=APP_DIR, check=True)

    app_export = json.loads(export_path.read_text(encoding="utf-8"))
    app_tools = app_export["app_tools"]
    tool_prompt = runner.serialize_cactus_tools(app_tools)
    tool_schema_json = json.dumps(
        app_tools, separators=(",", ":"), ensure_ascii=False
    )
    runner_schema_json = json.dumps(
        runner.load_recipe_tools(), separators=(",", ":"), ensure_ascii=False
    )

    summary: dict[str, Any] = {
        "schema_version": "issue_19_app_prompt_parity_v1",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "runner_profile": runner.TRIGGER_RECIPE_PROFILE,
        "runner_version": runner.RUNNER_VERSION,
        "assistant_prefix": runner.ASSISTANT_PREFIX_RUNNER_DEFAULT,
        "candidate_checkpoint": CANDIDATE_4_CHECKPOINT,
        "app_scenario_path": app_export["scenario_path"],
        "app_scenario_turn_count": app_export["scenario_turn_count"],
        "tool_schema_sha256": _sha256(tool_schema_json),
        "tool_prompt_sha256": _sha256(tool_prompt),
        "runner_tool_schema_sha256": _sha256(runner_schema_json),
        "app_tools_equal_runner_tools": tool_schema_json == runner_schema_json,
        "seeds": [],
        "totals": {
            "decision_matched": 0,
            "decision_total": 0,
            "instruction_matched": 0,
            "instruction_total": 0,
            "tool_context_matched": 0,
            "tool_context_total": 0,
            "history_matched": 0,
            "history_total": 0,
        },
        "mismatches": [],
    }

    for seed_export in app_export["seeds"]:
        results_path = Path(seed_export["results_path"])
        seed = _seed_from_path(results_path)
        results = json.loads(results_path.read_text(encoding="utf-8"))
        recorded_turns = results["turns"]
        seed_summary = {
            "seed": seed,
            "results_path": str(results_path),
            "decision": {"matched": 0, "total": 0},
            "instruction": {"matched": 0, "total": 0},
            "tool_context": {"matched": 0, "total": 0},
            "history": {"matched": 0, "total": 0},
        }

        for turn in seed_export["turns"]:
            key = turn["key"]
            record = recorded_turns[key]

            seed_summary["history"]["total"] += 1
            summary["totals"]["history_total"] += 1
            if turn["history_match"]:
                seed_summary["history"]["matched"] += 1
                summary["totals"]["history_matched"] += 1
            else:
                summary["mismatches"].append(
                    {
                        "kind": "history",
                        "seed": seed,
                        "turn": key,
                        "explanation": (
                            "The app's reconstructed full-turn history differs "
                            "from the runner's conversation_before snapshot. "
                            "The app excludes only its UI welcome message and "
                            "never truncates."
                        ),
                        "expected_history": turn.get("history_expected"),
                    }
                )

            if record.get("tool_result_context") is not None:
                seed_summary["tool_context"]["total"] += 1
                summary["totals"]["tool_context_total"] += 1
                if turn["tool_context_match"]:
                    seed_summary["tool_context"]["matched"] += 1
                    summary["totals"]["tool_context_matched"] += 1
                else:
                    summary["mismatches"].append(
                        {
                            "kind": "tool_context",
                            "seed": seed,
                            "turn": key,
                            "explanation": (
                                "formatToolResultsForPrompt did not reproduce "
                                "the runner's tool_result_context."
                            ),
                            "actual": turn["tool_context"],
                            "expected": record.get("tool_result_context"),
                        }
                    )

            expected_decision = record["decision_prompt"]
            actual_decision = runner.cactus_qwen_prompt(
                turn["decision_messages"], tools_text=tool_prompt
            )
            seed_summary["decision"]["total"] += 1
            summary["totals"]["decision_total"] += 1
            if actual_decision == expected_decision:
                seed_summary["decision"]["matched"] += 1
                summary["totals"]["decision_matched"] += 1
            else:
                summary["mismatches"].append(
                    _explain_mismatch(
                        "decision_prompt", seed, key, actual_decision, expected_decision
                    )
                )

            expected_instruction = record.get("recipe_instruction_prompt")
            if expected_instruction:
                actual_instruction = runner.cactus_qwen_prompt(
                    turn["instruction_messages"], tools_text=tool_prompt
                )
                seed_summary["instruction"]["total"] += 1
                summary["totals"]["instruction_total"] += 1
                if actual_instruction == expected_instruction:
                    seed_summary["instruction"]["matched"] += 1
                    summary["totals"]["instruction_matched"] += 1
                else:
                    summary["mismatches"].append(
                        _explain_mismatch(
                            "instruction_prompt",
                            seed,
                            key,
                            actual_instruction,
                            expected_instruction,
                        )
                    )

        summary["seeds"].append(seed_summary)

    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    totals = summary["totals"]
    print(
        "decision prompts: "
        f"{totals['decision_matched']}/{totals['decision_total']} exact"
    )
    print(
        "instruction prompts: "
        f"{totals['instruction_matched']}/{totals['instruction_total']} exact"
    )
    print(
        "tool contexts: "
        f"{totals['tool_context_matched']}/{totals['tool_context_total']} exact"
    )
    print(
        "histories: "
        f"{totals['history_matched']}/{totals['history_total']} exact"
    )
    print(f"app tools equal runner tools: {summary['app_tools_equal_runner_tools']}")
    print(f"summary: {args.summary}")
    if summary["mismatches"]:
        print(f"mismatches: {len(summary['mismatches'])} (see summary)", file=sys.stderr)
        return 1
    return 0


def _sha256(text: str) -> str:
    import hashlib

    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _seed_from_path(path: Path) -> int:
    for seed in SEEDS:
        if f"seed_{seed}" in str(path):
            return seed
    raise ValueError(f"cannot determine seed from {path}")


if __name__ == "__main__":
    raise SystemExit(main())
