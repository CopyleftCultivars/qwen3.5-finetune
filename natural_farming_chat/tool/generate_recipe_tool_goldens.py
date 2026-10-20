#!/usr/bin/env python3
"""Generate the Dart recipe-tool conformance fixtures from the reference oracle.

This script runs the *MCP server's* executor
(``mcp_server.recipe_tools_server.ToolExecutor``) over every
``bioaccumulator_recipe`` tool call in the v3 development and validation
scenarios, and writes the full result plus the compact served view. It never
opens the test split.

Run it with the reference workspace's MCP virtualenv so the MCP package is
available::

    ../bioaccumulator-benchmark-workspace/.venv-mcp/bin/python \
        tool/generate_recipe_tool_goldens.py

The reference workspace is treated as read-only. Override its location with
``BIOACCUMULATOR_WORKSPACE`` if needed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

SPLITS = ("development", "validation")  # Never add "test": the test split is held out.
DEFAULT_WORKSPACE = Path(
    os.environ.get(
        "BIOACCUMULATOR_WORKSPACE",
        Path(__file__).resolve().parents[3] / "bioaccumulator-benchmark-workspace",
    )
)
FIXTURE_ROOT = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "recipe_tool_v3"


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=DEFAULT_WORKSPACE)
    parser.add_argument("--output", type=Path, default=FIXTURE_ROOT)
    args = parser.parse_args(argv)

    workspace = args.workspace.resolve()
    if not (workspace / "recipe_tool_oracle.py").is_file():
        raise SystemExit(f"reference workspace not found: {workspace}")
    sys.path.insert(0, str(workspace))
    sys.path.insert(0, str(workspace / "scripts"))

    import recipe_tool_oracle as oracle  # noqa: PLC0415
    from mcp_server.recipe_tools_server import ToolExecutor  # noqa: PLC0415

    app_dir = Path(__file__).resolve().parents[1]
    executor = ToolExecutor(app_dir=app_dir)
    args.output.mkdir(parents=True, exist_ok=True)

    for split in SPLITS:
        if split not in SPLITS:  # Defensive: the held-out split must never appear.
            raise SystemExit(f"refusing to read split {split!r}")
        scenario_path = workspace / "scenarios" / "v3" / f"{split}.jsonl"
        if not scenario_path.is_file():
            raise SystemExit(f"missing scenario file: {scenario_path}")

        call_lines: list[str] = []
        trigger_lines: list[str] = []
        for scenario in load_jsonl(scenario_path):
            for turn in scenario.get("turns", []):
                user = str(turn.get("user") or "")
                try:
                    parsed = oracle.parse_trigger(user)
                except oracle.TriggerParseError as error:
                    trigger_lines.append(
                        json.dumps(
                            {
                                "case_id": scenario["case_id"],
                                "turn": turn["turn"],
                                "split": split,
                                "user": user,
                                "expected_error": {
                                    "code": error.code,
                                    "message": error.message,
                                },
                            },
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                    )
                else:
                    trigger_lines.append(
                        json.dumps(
                            {
                                "case_id": scenario["case_id"],
                                "turn": turn["turn"],
                                "split": split,
                                "user": user,
                                "expected_arguments": parsed,
                            },
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                    )

                call = turn.get("expected_call") or {}
                if call.get("name") != "bioaccumulator_recipe":
                    continue
                arguments = call["arguments"]
                outcome = executor.execute("bioaccumulator_recipe", arguments)
                full = outcome["structured"]
                served = json.loads(outcome["text"])
                served_text = outcome["text"]
                if served_text != canonical_json(served):
                    raise SystemExit(
                        f"MCP server did not return canonical served-view JSON for "
                        f"{scenario['case_id']} turn {turn['turn']}"
                    )
                expected_digest = (turn.get("expected_tool_result") or {}).get("digest_sha256")
                actual_digest = hashlib.sha256(canonical_json(full).encode("utf-8")).hexdigest()
                if expected_digest and actual_digest != expected_digest:
                    raise SystemExit(
                        f"oracle digest mismatch for {scenario['case_id']} turn "
                        f"{turn['turn']}: expected {expected_digest}, got {actual_digest}"
                    )
                call_lines.append(
                    json.dumps(
                        {
                            "case_id": scenario["case_id"],
                            "turn": turn["turn"],
                            "split": split,
                            "user": user,
                            "arguments": arguments,
                            "expected": full,
                            "expected_served": served,
                            "expected_served_text": served_text,
                        },
                        ensure_ascii=False,
                        separators=(",", ":"),
                    )
                )

        (args.output / f"{split}.jsonl").write_text(
            "\n".join(call_lines) + ("\n" if call_lines else ""),
            encoding="utf-8",
        )
        (args.output / f"{split}_triggers.jsonl").write_text(
            "\n".join(trigger_lines) + ("\n" if trigger_lines else ""),
            encoding="utf-8",
        )
        print(f"{split}: {len(call_lines)} tool calls, {len(trigger_lines)} trigger turns")

    # Prompt/schema parity fixture: record the runner's exact bytes and hashes.
    import run_hf_gpu_tool_benchmark as runner  # noqa: PLC0415

    runner_tools = runner.load_recipe_tools()
    tool_prompt = runner.serialize_cactus_tools(runner_tools)
    tool_schema_json = json.dumps(
        runner_tools, separators=(",", ":"), ensure_ascii=False
    )
    parity = {
        "runner_profile": runner.TRIGGER_RECIPE_PROFILE,
        "runner_version": runner.RUNNER_VERSION,
        "system_prompt": runner.SYSTEM_PROMPT,
        "system_prompt_sha256": hashlib.sha256(
            runner.SYSTEM_PROMPT.encode("utf-8")
        ).hexdigest(),
        "tool_prompt": tool_prompt,
        "tool_prompt_sha256": hashlib.sha256(tool_prompt.encode("utf-8")).hexdigest(),
        "tool_schema_json": tool_schema_json,
        "tool_schema_sha256": hashlib.sha256(
            tool_schema_json.encode("utf-8")
        ).hexdigest(),
    }
    (args.output / "prompt_parity.json").write_text(
        json.dumps(parity, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "prompt parity: "
        f"system={parity['system_prompt_sha256'][:12]} "
        f"tools={parity['tool_prompt_sha256'][:12]} "
        f"schema={parity['tool_schema_sha256'][:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
