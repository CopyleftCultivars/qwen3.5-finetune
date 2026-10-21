#!/usr/bin/env python3
"""Prove the app's recipe-form prompt path against candidate 4's #64 records.

The Dart exporter (`tool/export_recipe_form_messages.dart`) builds the form's
real messages for every single-turn **exact-trigger** v3 development case that
candidate 4 called correctly on `issue_64_ckpt423_seed_{42,43,44}`:

* empty history (a fresh form request);
* user = the form's canonical trigger text;
* assistant = the synthesized `<tool_call>` text;
* tool = the app/runner `tool_result_context` for the deterministic served view.

The script renders those lists with the benchmark runner's own
`cactus_qwen_prompt` (default `runner_default` assistant prefix) and compares:

* the synthesized assistant text with the recorded `native_response`;
* the full instruction prompt with the recorded `recipe_instruction_prompt`;
* the tool context with the recorded `tool_result_context`.

The test split is never read. The reference workspace is read-only.

Run from anywhere with the workspace's runner Python::

    /home/goya/anaconda3/envs/clc_local/bin/python \
        natural_farming_chat/tool/compare_form_prompt_parity.py
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
DEFAULT_SUMMARY = REPO_ROOT / "docs" / "issue-20-form-prompt-parity-2026-10-21.json"
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=DEFAULT_WORKSPACE)
    parser.add_argument("--summary", type=Path, default=DEFAULT_SUMMARY)
    parser.add_argument("--dart", default="dart")
    parser.add_argument(
        "--export",
        type=Path,
        default=Path("/tmp/issue-20-form-export.json"),
        help="Keep the intermediate app form export at this path",
    )
    parser.add_argument(
        "--skip-export",
        action="store_true",
        help="Reuse --export instead of running the Dart exporter",
    )
    args = parser.parse_args(argv)

    workspace = args.workspace.resolve()
    scenarios = workspace / "scenarios" / "v3" / "development.jsonl"
    if not scenarios.is_file():
        raise SystemExit(f"reference workspace not found: {workspace}")
    sys.path.insert(0, str(workspace / "scripts"))
    sys.path.insert(0, str(workspace))

    import run_hf_gpu_tool_benchmark as runner  # noqa: PLC0415

    if not args.skip_export:
        command = [
            args.dart,
            "run",
            "tool/export_recipe_form_messages.dart",
            "--scenarios",
            str(scenarios),
            "--output",
            str(args.export),
        ]
        for seed in SEEDS:
            command.extend(["--results", str(_results_path(workspace, seed))])
        subprocess.run(command, cwd=APP_DIR, check=True)

    app_export = json.loads(args.export.read_text(encoding="utf-8"))
    app_tools = app_export["app_tools"]
    tool_prompt = runner.serialize_cactus_tools(app_tools)
    runner_schema_json = json.dumps(
        runner.load_recipe_tools(), separators=(",", ":"), ensure_ascii=False
    )
    app_schema_json = json.dumps(app_tools, separators=(",", ":"), ensure_ascii=False)

    summary: dict[str, Any] = {
        "schema_version": "issue_20_recipe_form_prompt_parity_v1",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "runner_profile": runner.TRIGGER_RECIPE_PROFILE,
        "runner_version": runner.RUNNER_VERSION,
        "assistant_prefix": runner.ASSISTANT_PREFIX_RUNNER_DEFAULT,
        "candidate_checkpoint": CANDIDATE_4_CHECKPOINT,
        "app_scenario_path": app_export["scenario_path"],
        "single_turn_call_count": app_export["single_turn_call_count"],
        "called_correctly_on_every_seed_count": app_export[
            "called_correctly_on_every_seed_count"
        ],
        "exact_trigger_case_ids": app_export["exact_trigger_case_ids"],
        "alias_unit_case_ids": app_export["alias_unit_case_ids"],
        "app_tools_equal_runner_tools": app_schema_json == runner_schema_json,
        "tool_schema_sha256": _sha256(app_schema_json),
        "tool_prompt_sha256": _sha256(tool_prompt),
        "totals": {
            "assistant_matched": 0,
            "assistant_total": 0,
            "instruction_matched": 0,
            "instruction_total": 0,
            "tool_context_matched": 0,
            "tool_context_total": 0,
        },
        "seeds": [],
        "mismatches": [],
    }

    for seed_export in app_export["seeds"]:
        results_path = Path(seed_export["results_path"])
        seed = _seed_from_path(results_path)
        recorded_turns = json.loads(results_path.read_text(encoding="utf-8"))[
            "turns"
        ]
        seed_summary = {
            "seed": seed,
            "results_path": str(results_path),
            "assistant": {"matched": 0, "total": 0},
            "instruction": {"matched": 0, "total": 0},
            "tool_context": {"matched": 0, "total": 0},
        }

        for turn in seed_export["turns"]:
            key = turn["key"]
            record = recorded_turns[key]

            expected_native = turn["recorded_native_response"]
            actual_native = turn["synthesized_assistant"]
            seed_summary["assistant"]["total"] += 1
            summary["totals"]["assistant_total"] += 1
            if actual_native == expected_native:
                seed_summary["assistant"]["matched"] += 1
                summary["totals"]["assistant_matched"] += 1
            else:
                summary["mismatches"].append(
                    {
                        "kind": "assistant_tool_call",
                        "seed": seed,
                        "turn": key,
                        **_first_difference(actual_native, expected_native),
                    }
                )

            expected_context = record.get("tool_result_context")
            if expected_context is not None:
                seed_summary["tool_context"]["total"] += 1
                summary["totals"]["tool_context_total"] += 1
                if turn["tool_context"] == expected_context:
                    seed_summary["tool_context"]["matched"] += 1
                    summary["totals"]["tool_context_matched"] += 1
                else:
                    summary["mismatches"].append(
                        {
                            "kind": "tool_context",
                            "seed": seed,
                            "turn": key,
                            **_first_difference(
                                turn["tool_context"], expected_context
                            ),
                        }
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
                        {
                            "kind": "instruction_prompt",
                            "seed": seed,
                            "turn": key,
                            **_first_difference(
                                actual_instruction, expected_instruction
                            ),
                        }
                    )

        summary["seeds"].append(seed_summary)

    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    totals = summary["totals"]
    print(
        "form assistant tool calls: "
        f"{totals['assistant_matched']}/{totals['assistant_total']} exact"
    )
    print(
        "form instruction prompts: "
        f"{totals['instruction_matched']}/{totals['instruction_total']} exact"
    )
    print(
        "form tool contexts: "
        f"{totals['tool_context_matched']}/{totals['tool_context_total']} exact"
    )
    print(
        f"exact-trigger cases: {len(summary['exact_trigger_case_ids'])}; "
        f"alias-unit cases excluded: {len(summary['alias_unit_case_ids'])}"
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
