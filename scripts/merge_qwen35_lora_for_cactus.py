#!/usr/bin/env python3
"""Merge the trained Qwen3.5 LoRA into BF16 weights for Cactus conversion."""
from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="Qwen/Qwen3.5-2B")
    parser.add_argument("--adapter", type=Path,
                        default=ROOT / "outputs/lora-adapter-qwen35-combined/final")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "outputs/qwen35-combined-merged")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not (args.adapter / "adapter_config.json").is_file():
        raise FileNotFoundError(f"LoRA adapter is missing: {args.adapter}")
    if args.output.exists():
        raise FileExistsError(f"Merged model output already exists: {args.output}")

    import torch
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoProcessor

    base = AutoModelForCausalLM.from_pretrained(
        args.model,
        dtype=torch.bfloat16,
        device_map="auto",
        local_files_only=True,
        trust_remote_code=True,
    )
    adapted = PeftModel.from_pretrained(
        base,
        str(args.adapter),
        local_files_only=True,
    )
    merged = adapted.merge_and_unload(safe_merge=True)

    args.output.mkdir(parents=True)
    merged.save_pretrained(
        str(args.output),
        safe_serialization=True,
        max_shard_size="2GB",
    )
    processor = AutoProcessor.from_pretrained(
        str(args.adapter), local_files_only=True, trust_remote_code=True
    )
    processor.save_pretrained(str(args.output))
    print(f"merged adapter saved to {args.output.resolve()}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
