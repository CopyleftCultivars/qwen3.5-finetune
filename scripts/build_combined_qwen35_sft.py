#!/usr/bin/env python3
"""Build rationale + G6 RLM + Cactus-native tool-call SFT splits.

The G6 trajectories use the RLM Python LocalREPL protocol. The Cactus/Qwen
runtime uses JSON inside <tool_call> tags. Keep those protocols under separate
system prompts; do not rewrite REPL code into an unrelated farming function
call. A small, explicit native-call supplement teaches the production format.
"""
from __future__ import annotations

import hashlib
import json
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
DISTILL = ROOT / "data/sources/teacher_distill_qwen3-8b.jsonl"
G6_TRAIN = ROOT / "data/sources/g6_rlm_sft_train.jsonl"
G6_VAL = ROOT / "data/sources/g6_rlm_sft_val.jsonl"
TRAIN_OUT = ROOT / "data/combined_sft_train.jsonl"
VAL_OUT = ROOT / "data/combined_sft_val.jsonl"
MANIFEST_OUT = ROOT / "data/combined_sft_manifest.json"

SEED = 42
TEACHER_TRAIN_FRACTION = 0.9
NATIVE_CALL_REPEATS = 4
LEGACY_RATIONALE = re.compile(
    r"(?:^|\n)\s*thinking\s*\n(.*?)\n\s*response\s*\n([A-D])\s*$",
    re.DOTALL | re.IGNORECASE,
)
RLM_CONTEXT_SUFFIX = re.compile(
    r"\n\nYour context is a str of \d+ total characters\..*$", re.DOTALL
)


# These prompts are hand-authored format demonstrations for the two domain
# functions shared by rlm_slice and natural_farming_chat. They are not drawn
# from any benchmark or evaluation split. First 8 per function are training
# rows; last 2 are validation rows.
BIOACCUMULATOR_DEMOS = [
    ("I grow corn and want to cut comfrey for green manure. Compare comfrey's phosphorus and potassium levels with corn's requirements.", "Corn", "Comfrey"),
    ("Would stinging nettle be useful as a liquid feed for tomatoes? Compare its tissue P and K with the crop's needs.", "Tomato", "Stinging Nettle"),
    ("For lettuce, compare dandelion's phosphorus and potassium content with the crop requirements before I harvest it as green manure.", "Lettuce", "Dandelion"),
    ("Could yarrow be a useful nutrient accumulator for cucumbers? Check its P/K levels against cucumber requirements.", "Cucumber", "Yarrow"),
    ("Compare red clover's phosphorus and potassium with potato requirements to assess it as a green manure.", "Potato", "Red Clover"),
    ("For jalapeno peppers, would alfalfa provide useful phosphorus and potassium? Compare plant tissue with crop needs.", "Jalapeno Peppers", "Alfalfa"),
    ("Is borage a worthwhile nutrient accumulator for rice? Compare its P and K tissue levels with rice requirements.", "Rice", "Borage"),
    ("Check whether alfalfa's mineral content is a good match for wheat's phosphorus and potassium needs.", "Wheat", "Alfalfa"),
    ("Would comfrey be a nutrient-dense green manure for soybeans? Compare its phosphorus and potassium with crop requirements.", "Soybean", "Comfrey"),
    ("Assess stinging nettle as a green manure for pumpkin by comparing its P/K levels with the crop's needs.", "Pumpkin", "Stinging Nettle"),
]

REGIONAL_RECIPE_DEMOS = [
    ("I grow tomatoes in Colombia and have a potassium deficiency. Find local plants and KNF/JADAM recipes that could help.", "Tomato", "Colombia", "potassium deficiency"),
    ("For jalapeno peppers in Mexico with nitrogen deficiency, look up relevant regional plants and natural-farming recipes.", "Jalapeno Peppers", "Mexico", "nitrogen deficiency"),
    ("My corn in Kenya has low phosphorus. Which locally available plants and recipes are relevant?", "Corn", "Kenya", "low phosphorus"),
    ("I am growing lettuce in California. Find regional bioaccumulators and recipes for fungal disease pressure.", "Lettuce", "California", "fungal disease pressure"),
    ("What natural-farming recipes and local plant options fit cucumber production in Indonesia with poor growth?", "Cucumber", "Indonesia", "poor growth"),
    ("For coffee in Colombia during fruiting, find local plant resources and recipes for supporting fruit development.", "Coffee", "Colombia", "fruiting stage nutrient needs"),
    ("I grow kale in Kenya and need organic options for depleted soil. Look up regional plants and KNF/JADAM recipes.", "Kale", "Kenya", "depleted soil"),
    ("Which local plants and natural-farming recipes could help potatoes in Mexico during root development?", "Potato", "Mexico", "root development"),
    ("Find regionally useful plants and recipes for rice growers in Bangladesh dealing with leaf yellowing.", "Rice", "Bangladesh", "leaf yellowing"),
    ("For alfalfa in California, look up local bioaccumulators and recipes that support soil fertility.", "Alfalfa", "California", "soil fertility"),
]

NO_CALL_DEMOS = [
    ("In general, why do earthworms improve soil structure?", "Earthworms create channels and casts that improve aeration, water movement, aggregation, and nutrient cycling."),
    ("What is the difference between compost and mulch?", "Compost is decomposed organic matter used to add nutrients and improve soil. Mulch is a surface cover that protects soil, conserves moisture, and suppresses weeds; some mulches break down and add organic matter."),
    ("How do cover crops help reduce erosion?", "Cover crops protect bare soil from raindrop impact, slow runoff, and hold soil with their roots. Their residues also improve soil structure over time."),
    ("Why can legumes add nitrogen to a farming system?", "Legumes form partnerships with nitrogen-fixing bacteria in root nodules. The bacteria convert atmospheric nitrogen into forms the plant can use; some nitrogen remains in residues after the crop is cut."),
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise FileNotFoundError(f"Required source is missing: {path}")
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(row, dict):
                raise ValueError(f"{path}:{line_number}: expected an object")
            rows.append(row)
    return rows


def normalize_question(text: str) -> str:
    text = RLM_CONTEXT_SUFFIX.sub("", text).lower()
    return re.sub(r"\W+", " ", text).strip()


def split_teacher_rows(
    rows: list[dict[str, Any]], seed: int = SEED
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, int]]:
    """Split by source question ID so answer-order variants cannot cross sets."""
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for index, row in enumerate(rows):
        instruction = row.get("instruction")
        match = LEGACY_RATIONALE.search(str(row.get("output", "")))
        if not isinstance(instruction, str) or not instruction.strip() or not match:
            raise ValueError(f"teacher rationale row {index} is malformed")
        group = str(row.get("_source_question_id") or hashlib.sha256(instruction.encode()).hexdigest())
        groups[group].append(row)

    keys = list(groups)
    random.Random(seed).shuffle(keys)
    split_at = int(len(keys) * TEACHER_TRAIN_FRACTION)
    train_keys, val_keys = set(keys[:split_at]), set(keys[split_at:])
    if train_keys & val_keys:
        raise AssertionError("teacher source question IDs crossed the train/validation split")

    def convert(group_keys: set[str]) -> list[dict[str, Any]]:
        converted = []
        for key in keys:
            if key not in group_keys:
                continue
            for row in groups[key]:
                match = LEGACY_RATIONALE.search(row["output"])
                assert match is not None
                converted.append({
                    "source": "teacher_distill_qwen3-8b",
                    "source_question_id": str(row.get("_source_question_id", key)),
                    "messages": [
                        {"role": "user", "content": row["instruction"].strip()},
                        {
                            "role": "assistant",
                            "content": f"<think>\n{match.group(1).strip()}\n</think>\n\n{match.group(2)}",
                        },
                    ],
                })
        return converted

    return convert(train_keys), convert(val_keys), {
        "rows": len(rows),
        "source_question_groups": len(groups),
        "train_rows": sum(len(groups[key]) for key in train_keys),
        "validation_rows": sum(len(groups[key]) for key in val_keys),
        "train_groups": len(train_keys),
        "validation_groups": len(val_keys),
    }


def validate_messages(row: dict[str, Any], where: str) -> None:
    messages = row.get("messages")
    if not isinstance(messages, list) or len(messages) < 2:
        raise ValueError(f"{where}: messages must contain at least two turns")
    for message in messages:
        if (
            not isinstance(message, dict)
            or message.get("role") not in {"system", "user", "assistant"}
            or not isinstance(message.get("content"), str)
            or not message["content"].strip()
        ):
            raise ValueError(f"{where}: malformed chat message")
    if messages[-1]["role"] != "assistant":
        raise ValueError(f"{where}: final turn must be assistant")


def load_rlm(path: Path, expected_rows: int, split: str) -> list[dict[str, Any]]:
    rows = read_jsonl(path)
    if len(rows) != expected_rows:
        raise ValueError(f"{path}: expected {expected_rows} rows, found {len(rows)}")
    out = []
    for index, source in enumerate(rows):
        validate_messages(source, f"{path}:{index + 1}")
        out.append({
            "source": f"g6_rlm_{split}",
            "question_id": source.get("question_id"),
            "messages": source["messages"],
        })
    return out


def cactus_tool_prompt() -> str:
    # Mirror cactus-engine/src/chat_tools.h::serialize_tools_qwen. These are
    # the two domain schemas used by rlm_slice Arm T and the Dart app.
    from rlm_slice.domain_tools import TOOL_DEFINITIONS

    tool_objects = [
        {"type": "function", "function": tool}
        for tool in TOOL_DEFINITIONS
    ]
    tool_json = "\n".join(json.dumps(tool, ensure_ascii=False) for tool in tool_objects)
    return (
        "# Tools\n\n"
        "You may call one or more functions to assist with the user query.\n\n"
        "You are provided with function signatures within <tools></tools> XML tags:\n"
        "<tools>\n"
        f"{tool_json}\n"
        "</tools>\n\n"
        "For each function call, return a json object with function name and "
        "arguments within <tool_call></tool_call> XML tags:\n"
        "<tool_call>\n"
        '{"name": <function-name>, "arguments": <args-json-object>}\n'
        "</tool_call>"
    )


def native_tool_demos() -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    prompt = cactus_tool_prompt()
    train: list[dict[str, Any]] = []
    val: list[dict[str, Any]] = []
    call_counts: Counter[str] = Counter()
    call_rows: list[dict[str, Any]] = []

    for index, (user, crop, plant) in enumerate(BIOACCUMULATOR_DEMOS):
        target = {
            "name": "bioaccumulator_ratio",
            "arguments": {"crop": crop, "candidate_plant": plant},
        }
        call_rows.append({
            "example_id": f"bioaccumulator_ratio_{index + 1:02d}",
            "split": "validation" if index >= 8 else "train",
            "tool_name": target["name"],
            "user": user,
            "target": target,
        })

    for index, (user, crop, region, problem) in enumerate(REGIONAL_RECIPE_DEMOS):
        target = {
            "name": "regional_recipe_lookup",
            "arguments": {"crop": crop, "region": region, "problem": problem},
        }
        call_rows.append({
            "example_id": f"regional_recipe_lookup_{index + 1:02d}",
            "split": "validation" if index >= 8 else "train",
            "tool_name": target["name"],
            "user": user,
            "target": target,
        })

    for example in call_rows:
        call = json.dumps(example["target"], ensure_ascii=False)
        messages = [
            {"role": "system", "content": prompt},
            {"role": "user", "content": example["user"]},
            {"role": "assistant", "content": f"<tool_call>\n{call}\n</tool_call>"},
        ]
        row = {
            "source": "cactus_native_tool_demo",
            "example_id": example["example_id"],
            "target_tool": example["tool_name"],
            "messages": messages,
        }
        for _ in range(NATIVE_CALL_REPEATS if example["split"] == "train" else 1):
            (train if example["split"] == "train" else val).append(dict(row))
        call_counts[example["tool_name"]] += 1

    for index, (user, answer) in enumerate(NO_CALL_DEMOS):
        row = {
            "source": "cactus_native_no_call_demo",
            "example_id": f"no_call_{index + 1:02d}",
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": user},
                {"role": "assistant", "content": answer},
            ],
        }
        (val if index == len(NO_CALL_DEMOS) - 1 else train).append(row)

    return train, val, {
        "tool_call_examples_before_weighting": len(call_rows),
        "tool_call_examples_by_name": dict(sorted(call_counts.items())),
        "training_call_repeat_count": NATIVE_CALL_REPEATS,
        "no_call_examples": len(NO_CALL_DEMOS),
        "format": "Cactus Qwen JSON object inside <tool_call>...</tool_call>",
        "source": "hand-authored natural-farming examples; not benchmark questions",
    }


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    teacher_rows = read_jsonl(DISTILL)
    if len(teacher_rows) != 871:
        raise ValueError(f"Expected the curated 871-row teacher corpus, found {len(teacher_rows)}")
    teacher_train, teacher_val, teacher_split = split_teacher_rows(teacher_rows)
    rlm_train = load_rlm(G6_TRAIN, 117, "train")
    rlm_val = load_rlm(G6_VAL, 14, "validation")
    native_train, native_val, native_info = native_tool_demos()

    teacher_ids = {str(row.get("_source_question_id")) for row in teacher_rows}
    rlm_ids = {
        str(row.get("question_id"))
        for row in [*read_jsonl(G6_TRAIN), *read_jsonl(G6_VAL)]
        if row.get("question_id") is not None
    }
    if teacher_ids & rlm_ids:
        raise ValueError("teacher and RLM question IDs overlap")

    teacher_text = {normalize_question(str(row["instruction"])) for row in teacher_rows}
    rlm_text = {
        normalize_question(message["content"])
        for row in [*read_jsonl(G6_TRAIN), *read_jsonl(G6_VAL)]
        for message in row.get("messages", [])
        if message.get("role") == "user"
    }
    overlap = teacher_text & rlm_text
    if overlap:
        raise ValueError(f"teacher and RLM questions overlap ({len(overlap)} exact normalized matches)")

    train_rows = [*teacher_train, *rlm_train, *native_train]
    val_rows = [*teacher_val, *rlm_val, *native_val]
    random.Random(SEED).shuffle(train_rows)
    random.Random(SEED + 1).shuffle(val_rows)
    for split, rows in (("train", train_rows), ("validation", val_rows)):
        for index, row in enumerate(rows, start=1):
            validate_messages(row, f"{split} row {index}")

    write_jsonl(TRAIN_OUT, train_rows)
    write_jsonl(VAL_OUT, val_rows)
    manifest = {
        "format": "qwen35_combined_sft_v1",
        "base_model": "Qwen/Qwen3.5-2B",
        "seed": SEED,
        "teacher_split": {
            "fraction": TEACHER_TRAIN_FRACTION,
            "grouped_by": "_source_question_id (keeps answer-order variants together)",
            **teacher_split,
        },
        "sources": {
            "teacher_rationales": {
                "file": str(DISTILL.relative_to(ROOT)),
                "rows": len(teacher_rows),
                "sha256": sha256(DISTILL),
                "format_conversion": "legacy thinking/response markers to Qwen3 <think> block + bare answer letter",
            },
            "g5_filtered_trajectories": {
                "file": "data/sources/g5_trajectories_qwen3-8b_filtered.jsonl",
                "rows": 131,
                "sha256": sha256(ROOT / "data/sources/g5_trajectories_qwen3-8b_filtered.jsonl"),
                "preparation": "existing G6 builder; filtered train_v3 pool with eval val/dev denylist",
            },
            "g6_rlm_train": {
                "file": str(G6_TRAIN.relative_to(ROOT)),
                "rows": len(rlm_train),
                "sha256": sha256(G6_TRAIN),
                "protocol": "Python LocalREPL code blocks, preserved verbatim",
            },
            "g6_rlm_validation": {
                "file": str(G6_VAL.relative_to(ROOT)),
                "rows": len(rlm_val),
                "sha256": sha256(G6_VAL),
                "protocol": "Python LocalREPL code blocks, preserved verbatim",
            },
            "native_tool_demos": native_info,
        },
        "protocol_decision": (
            "Keep the RLM LocalREPL grammar for RLM-prompted examples. Add separate "
            "Cactus-native examples using the JSON object inside <tool_call> tags, "
            "matching cactus-engine/src/chat_tools.h::serialize_tools_qwen and "
            "extract_qwen_tool_calls. Do not translate print(context) into a farming "
            "function call: in G6 it only prints the question supplied to the REPL."
        ),
        "sealed_eval_policy": (
            "This builder reads only the pinned rationale source and the generated G6 "
            "train/validation splits. It never opens eval_freeform/test.jsonl or "
            "benchmark question/answer files. The G5 source was produced from the "
            "training pool with the existing validation/dev hash denylist."
        ),
        "question_overlap": {"teacher_vs_rlm_exact_normalized": 0},
        "train": {
            "file": str(TRAIN_OUT.relative_to(ROOT)),
            "rows": len(train_rows),
            "rows_by_source": dict(sorted(Counter(row["source"] for row in train_rows).items())),
            "sha256": sha256(TRAIN_OUT),
        },
        "validation": {
            "file": str(VAL_OUT.relative_to(ROOT)),
            "rows": len(val_rows),
            "rows_by_source": dict(sorted(Counter(row["source"] for row in val_rows).items())),
            "sha256": sha256(VAL_OUT),
        },
    }
    MANIFEST_OUT.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    print(f"wrote {TRAIN_OUT.relative_to(ROOT)} and {VAL_OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
