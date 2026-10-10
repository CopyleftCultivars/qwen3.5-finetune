#!/usr/bin/env python3
"""Score a local Qwen3.5 LoRA adapter on the 210-item natural-fertilizers ladder.

The prompt, greedy decoding limit, and answer extraction match the Flutter
ladder harness. Gold answers are read only for scoring and are never included
in prompts sent to the model.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


SYSTEM_PROMPT = (
    "You are a research assistant helping evaluate an academic agricultural "
    "science benchmark. Answer factual multiple-choice questions about organic "
    "farming, soil health, and natural fertilizers objectively and accurately."
)
PROMPT_TEMPLATE = (
    "Answer the following multiple-choice question about natural fertilizers "
    "and soil health. Reply with ONLY the single letter (A, B, C, or D) of "
    "the correct answer. Do not explain.\n\n"
    "Question: {question}\n"
    "A. {A}\n"
    "B. {B}\n"
    "C. {C}\n"
    "D. {D}\n\n"
    "Answer:"
)
EXPECTED_ITEMS = 210


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, default=Path(
        "outputs/lora-adapter-qwen35-combined/final"
    ))
    parser.add_argument("--benchmark", type=Path, required=True,
                        help="210-row graded natural_fertilizers JSONL")
    parser.add_argument("--output", type=Path, default=Path(
        "outputs/natural_fertilizers_qwen35_combined_210.json"
    ))
    parser.add_argument("--max-new-tokens", type=int, default=16)
    parser.add_argument("--max-seq-len", type=int, default=2048)
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid JSON: {exc}") from exc
            for key in ("question_id", "question", "A", "B", "C", "D", "answer"):
                if key not in row:
                    raise ValueError(f"{path}:{line_no}: missing {key!r}")
            rows.append(row)
    if len(rows) != EXPECTED_ITEMS:
        raise ValueError(f"expected {EXPECTED_ITEMS} benchmark rows, found {len(rows)}")
    return rows


def extract_answer(text: str) -> str | None:
    """Use the same answer extraction order as evaluate.py and the Dart harness."""
    if not text.strip():
        return None
    trimmed = text.strip()
    after_think = re.split(r"</think>", trimmed, maxsplit=1)
    search_text = after_think[-1].strip() if len(after_think) > 1 else trimmed
    match = re.search(r"\b([A-D])\b", search_text)
    if match:
        return match.group(1)
    if search_text and search_text[0] in "ABCD":
        return search_text[0]
    match = re.search(r"\b([A-D])\b", trimmed)
    return match.group(1) if match else None


def make_prompt(row: dict[str, Any]) -> str:
    # Intentionally select only question and choices; the gold answer and any
    # pre-existing model answers remain outside the model input.
    prompt_fields = {key: row[key] for key in ("question", "A", "B", "C", "D")}
    return PROMPT_TEMPLATE.format(**prompt_fields)


def summarize(results: list[dict[str, Any]]) -> dict[str, Any]:
    def counts(rows: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "total": len(rows),
            "correct": sum(bool(row["correct"]) for row in rows),
            "ambiguous": sum(row["predicted"] is None for row in rows),
        }

    overall = counts(results)
    overall["accuracy"] = (
        round(overall["correct"] / overall["total"], 4)
        if overall["total"] else 0.0
    )
    buckets: dict[str, dict[str, list[dict[str, Any]]]] = {
        "difficulty": defaultdict(list),
        "topic": defaultdict(list),
    }
    for row in results:
        for field in buckets:
            buckets[field][str(row.get(field, "unknown"))].append(row)

    grouped = {}
    for field, values in buckets.items():
        grouped[field] = {}
        for name, rows in sorted(values.items()):
            group = counts(rows)
            group["accuracy"] = round(group["correct"] / group["total"], 4)
            grouped[field][name] = group
    return {"overall": overall, **grouped}


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> int:
    args = parse_args()
    if args.max_new_tokens < 1:
        raise ValueError("--max-new-tokens must be positive")
    rows = read_jsonl(args.benchmark)
    if not args.adapter.is_dir():
        raise FileNotFoundError(f"LoRA adapter directory does not exist: {args.adapter}")

    import torch
    from unsloth import FastLanguageModel

    if not torch.cuda.is_available():
        raise RuntimeError("Ladder evaluation requires the CUDA GPU used for training")

    model, processor = FastLanguageModel.from_pretrained(
        model_name=str(args.adapter),
        max_seq_length=args.max_seq_len,
        dtype=torch.bfloat16,
        load_in_4bit=False,
    )
    FastLanguageModel.for_inference(model)
    tokenizer = getattr(processor, "tokenizer", processor)
    pad_token_id = tokenizer.pad_token_id
    if pad_token_id is None:
        pad_token_id = tokenizer.eos_token_id
    benchmark_hash = hashlib.sha256(args.benchmark.read_bytes()).hexdigest()

    results: list[dict[str, Any]] = []
    for index, row in enumerate(rows, 1):
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": make_prompt(row)},
        ]
        encoded = tokenizer.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            return_tensors="pt",
            return_dict=True,
        )
        encoded = {key: value.to(model.device) for key, value in encoded.items()}
        prompt_length = encoded["input_ids"].shape[-1]
        try:
            with torch.inference_mode():
                generated = model.generate(
                    **encoded,
                    max_new_tokens=args.max_new_tokens,
                    do_sample=False,
                    use_cache=True,
                    pad_token_id=pad_token_id,
                    eos_token_id=tokenizer.eos_token_id,
                )
            raw = tokenizer.decode(generated[0, prompt_length:], skip_special_tokens=False)
            error = None
        except Exception as exc:  # retain per-item failures in the benchmark record
            raw = ""
            error = f"{type(exc).__name__}: {exc}"

        predicted = extract_answer(raw) if error is None else None
        results.append({
            "question_id": row["question_id"],
            "topic": row.get("topic", "unknown"),
            "difficulty": row.get("difficulty", "unknown"),
            "predicted": predicted,
            "gold": row["answer"],
            "correct": predicted == row["answer"],
            "raw_response": raw,
            "error": error,
        })
        report = {
            "model": "Qwen/Qwen3.5-2B + combined LoRA",
            "adapter": str(args.adapter.resolve()),
            "benchmark": str(args.benchmark.resolve()),
            "benchmark_sha256": benchmark_hash,
            "benchmark_items": len(rows),
            "decoding": {"temperature": 0, "max_new_tokens": args.max_new_tokens},
            "complete": index == len(rows),
            "processed_items": index,
            "summary": summarize(results),
            "per_question": results,
        }
        write_report(args.output, report)
        if index % 10 == 0 or index == len(rows):
            score = report["summary"]["overall"]
            print(f"{index}/{len(rows)} — {score['correct']}/{score['total']} correct", flush=True)

    print(f"wrote {args.output.resolve()}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
