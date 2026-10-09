#!/usr/bin/env python3
"""Rebuild the frozen rationale SFT splits from the pinned source corpora."""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONVERSATIONS = ROOT / "data/sources/gemma4/hf_dataset/train.jsonl"
TEACHER_RATIONALES = ROOT / "data/sources/teacher_distill_qwen3-8b.jsonl"
PREPARE = ROOT / "prepare_dataset_v3.py"
DATA_DIR = ROOT / "data"
THINK_BLOCK = re.compile(r"<think>(.*?)</think>", re.DOTALL)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def count_rows(path: Path) -> int:
    with path.open(encoding="utf-8") as handle:
        return sum(1 for line in handle if line.strip())


def count_rationale_rows(path: Path) -> tuple[int, int]:
    total = 0
    nonempty = 0
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            row = json.loads(line)
            match = THINK_BLOCK.search(str(row.get("output", "")))
            if match:
                total += 1
                nonempty += bool(match.group(1).strip())
    return total, nonempty


def main() -> int:
    for path in (CONVERSATIONS, TEACHER_RATIONALES, PREPARE):
        if not path.is_file():
            raise FileNotFoundError(f"Required corpus input is missing: {path}")

    command = [
        sys.executable,
        str(PREPARE),
        "--conversations", str(CONVERSATIONS),
        "--qmd-mcq", str(TEACHER_RATIONALES),
        "--output-dir", str(DATA_DIR),
        "--suffix", "_distill",
        "--split", "0.9",
        "--seed", "42",
        "--min-output-chars", "10",
        "--max-total-chars", "8192",
        "--sft-format", "bare-letter",
    ]
    subprocess.run(command, cwd=ROOT, check=True)

    train_path = DATA_DIR / "train_distill.jsonl"
    val_path = DATA_DIR / "val_distill.jsonl"
    train_think, train_rationales = count_rationale_rows(train_path)
    val_think, val_rationales = count_rationale_rows(val_path)
    if train_rationales == 0 or val_rationales == 0:
        raise RuntimeError(
            "The generated splits contain no non-empty teacher rationale blocks; "
            "check the teacher-source marker parser before training"
        )
    manifest = {
        "format": "qwen35_distill_corpus_v1",
        "provenance": (
            "Adapted from qwen3-finetune's F6/F7 rationale corpus. Its curated "
            "teacher source uses legacy thinking/response markers; this builder "
            "preserves those teacher rationales as <think> blocks."
        ),
        "source": {
            "conversation_file": str(CONVERSATIONS.relative_to(ROOT)),
            "conversation_rows": count_rows(CONVERSATIONS),
            "conversation_sha256": sha256(CONVERSATIONS),
            "teacher_rationale_file": str(TEACHER_RATIONALES.relative_to(ROOT)),
            "teacher_rationale_rows": count_rows(TEACHER_RATIONALES),
            "teacher_rationale_sha256": sha256(TEACHER_RATIONALES),
        },
        "builder": {
            "script": str(PREPARE.relative_to(ROOT)),
            "split": 0.9,
            "seed": 42,
            "minimum_output_chars": 10,
            "maximum_instruction_plus_output_chars": 8192,
            "sft_format": "bare-letter",
        },
        "train": {
            "file": str(train_path.relative_to(ROOT)),
            "rows": count_rows(train_path),
            "sha256": sha256(train_path),
            "think_rows": train_think,
            "nonempty_rationale_rows": train_rationales,
        },
        "validation": {
            "file": str(val_path.relative_to(ROOT)),
            "rows": count_rows(val_path),
            "sha256": sha256(val_path),
            "think_rows": val_think,
            "nonempty_rationale_rows": val_rationales,
        },
    }
    manifest_path = DATA_DIR / "distill_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    print(f"wrote {manifest_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
