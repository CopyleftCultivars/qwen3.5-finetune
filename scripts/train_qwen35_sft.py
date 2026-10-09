#!/usr/bin/env python3
"""BF16 LoRA SFT for Qwen3.5-2B using the rationale distillation corpus."""
from __future__ import annotations

import argparse
import json
import os
import time
from collections import Counter
from pathlib import Path
from typing import Any

os.environ.setdefault("UNSLOTH_RETURN_LOGITS", "1")

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TARGET_MODULES = (
    "in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a", "out_proj",
    "q_proj", "k_proj", "v_proj", "o_proj",
    "gate_proj", "up_proj", "down_proj",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="Qwen/Qwen3.5-2B")
    parser.add_argument("--train-data", type=Path, default=ROOT / "data/train_distill.jsonl")
    parser.add_argument("--val-data", type=Path, default=ROOT / "data/val_distill.jsonl")
    parser.add_argument("--output-dir", type=Path,
                        default=ROOT / "outputs/lora-adapter-qwen35-distill")
    parser.add_argument("--epochs", type=float, default=4)
    parser.add_argument("--max-steps", type=int, default=-1,
                        help="Optional step cap; -1 trains for all epochs")
    parser.add_argument("--lr", type=float, default=5e-5)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--grad-accum", type=int, default=8)
    parser.add_argument("--max-seq-len", type=int, default=2048)
    parser.add_argument("--lora-r", type=int, default=32)
    parser.add_argument("--lora-alpha", type=int, default=64)
    parser.add_argument("--lora-dropout", type=float, default=0.025)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--run-name", default="qwen35-2b-distill-rationale")
    parser.add_argument("--eval-strategy", choices=("no", "steps", "epoch"), default="no")
    parser.add_argument(
        "--fail-on-truncation",
        action="store_true",
        help="Fail if any rendered example exceeds --max-seq-len instead of silently truncating its target.",
    )
    parser.add_argument("--wandb", action="store_true")
    return parser.parse_args()


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise FileNotFoundError(f"Dataset does not exist: {path}")
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                row = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if "messages" in row:
                messages = row["messages"]
                if not isinstance(messages, list) or len(messages) < 2:
                    raise ValueError(f"{path}:{line_number}: messages must have at least two turns")
                for message in messages:
                    if (not isinstance(message, dict)
                            or message.get("role") not in {"system", "user", "assistant"}
                            or not isinstance(message.get("content"), str)
                            or not message["content"].strip()):
                        raise ValueError(f"{path}:{line_number}: malformed chat message")
                if messages[-1]["role"] != "assistant":
                    raise ValueError(f"{path}:{line_number}: final message must be assistant")
            elif (not isinstance(row.get("instruction"), str)
                  or not row["instruction"].strip()
                  or not isinstance(row.get("output"), str)
                  or not row["output"].strip()):
                raise ValueError(
                    f"{path}:{line_number}: expected non-empty instruction/output or messages"
                )
            rows.append(row)
    if not rows:
        raise ValueError(f"Dataset is empty: {path}")
    return rows


def messages_for(row: dict[str, Any]) -> list[dict[str, str]]:
    if "messages" in row:
        return row["messages"]
    return [
        {"role": "user", "content": row["instruction"].strip()},
        {"role": "assistant", "content": row["output"].strip()},
    ]


def render_chat(row: dict[str, Any]) -> str:
    return "\n".join(
        f"<|im_start|>{message['role']}\n{message['content'].strip()}<|im_end|>"
        for message in messages_for(row)
    )


def build_dataset(
    rows: list[dict[str, Any]], tokenizer, max_seq_len: int, fail_on_truncation: bool
):
    from datasets import Dataset

    texts = [render_chat(row) for row in rows]
    lengths: list[int] = []
    for start in range(0, len(texts), 32):
        encoded = tokenizer(texts[start:start + 32], truncation=False, padding=False)
        lengths.extend(len(input_ids) for input_ids in encoded["input_ids"])
    truncated = sum(length > max_seq_len for length in lengths)
    if fail_on_truncation and truncated:
        longest = max(lengths, default=0)
        raise ValueError(
            f"{truncated} rendered examples exceed max_seq_len={max_seq_len} "
            f"(longest={longest}); increase the context or shorten those examples"
        )

    dataset = Dataset.from_dict({"text": texts})

    def tokenize(batch: dict[str, list[str]]) -> dict[str, Any]:
        return tokenizer(batch["text"], truncation=True, max_length=max_seq_len, padding=False)

    tokenized = dataset.map(tokenize, batched=True, remove_columns=["text"])
    return tokenized, {
        "rows": len(texts),
        "max_input_tokens": max(lengths, default=0),
        "rows_over_max_seq_len": truncated,
    }


def latest_checkpoint(output_dir: Path) -> str | None:
    checkpoints: list[tuple[int, Path]] = []
    for path in output_dir.glob("checkpoint-*"):
        try:
            step = int(path.name.removeprefix("checkpoint-"))
        except ValueError:
            continue
        checkpoints.append((step, path))
    return str(max(checkpoints)[1]) if checkpoints else None


def main() -> int:
    args = parse_args()
    from importlib.metadata import version as package_version

    from packaging.version import Version
    import torch

    transformers_version = package_version("transformers")
    if Version(transformers_version) < Version("5.2.0"):
        raise RuntimeError(
            f"Qwen3.5 requires Transformers >=5.2.0; found {transformers_version}"
        )
    if not torch.cuda.is_available():
        raise RuntimeError("Qwen3.5-2B LoRA training requires a CUDA GPU")
    if not torch.cuda.is_bf16_supported():
        raise RuntimeError(
            "This recipe requires BF16 support; it intentionally does not fall back to FP16"
        )

    train_rows = load_jsonl(args.train_data)
    val_rows = load_jsonl(args.val_data)
    print(f"train rows={len(train_rows)} validation rows={len(val_rows)}", flush=True)

    from unsloth import FastLanguageModel

    started = time.time()
    model, processor = FastLanguageModel.from_pretrained(
        model_name=args.model,
        max_seq_length=args.max_seq_len,
        dtype=torch.bfloat16,
        load_in_4bit=False,
    )
    tokenizer = getattr(processor, "tokenizer", processor)
    fp16_parameters = [name for name, parameter in model.named_parameters()
                       if parameter.dtype == torch.float16]
    if fp16_parameters:
        example_names = ", ".join(fp16_parameters[:5])
        raise RuntimeError(f"FP16 model parameters are disallowed; found: {example_names}")

    model = FastLanguageModel.get_peft_model(
        model,
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        target_modules=list(DEFAULT_TARGET_MODULES),
        lora_dropout=args.lora_dropout,
        bias="none",
        use_gradient_checkpointing="unsloth",
        random_state=args.seed,
    )
    trainable_params = sum(parameter.numel() for parameter in model.parameters()
                           if parameter.requires_grad)

    eos_token = "<|im_end|>"
    eos_id = tokenizer.convert_tokens_to_ids(eos_token)
    if eos_id is None or eos_id == getattr(tokenizer, "unk_token_id", None):
        raise RuntimeError(f"Tokenizer does not contain required EOS token {eos_token}")
    tokenizer.eos_token = eos_token
    tokenizer.eos_token_id = eos_id

    train_dataset, train_token_stats = build_dataset(
        train_rows, tokenizer, args.max_seq_len, args.fail_on_truncation
    )
    val_dataset, val_token_stats = build_dataset(
        val_rows, tokenizer, args.max_seq_len, args.fail_on_truncation
    )
    print(
        f"tokenized train={len(train_dataset)} validation={len(val_dataset)} "
        f"max_tokens={max(train_token_stats['max_input_tokens'], val_token_stats['max_input_tokens'])} "
        f"truncated={train_token_stats['rows_over_max_seq_len'] + val_token_stats['rows_over_max_seq_len']}",
        flush=True,
    )

    from trl import SFTConfig, SFTTrainer

    training_args = SFTConfig(
        output_dir=str(args.output_dir),
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        warmup_ratio=0.05,
        learning_rate=args.lr,
        bf16=True,
        fp16=False,
        logging_steps=10,
        save_strategy="epoch",
        save_total_limit=2,
        eval_strategy=args.eval_strategy,
        optim="adamw_8bit",
        lr_scheduler_type="cosine",
        weight_decay=0.01,
        seed=args.seed,
        report_to="wandb" if args.wandb else "none",
        run_name=args.run_name,
        packing=False,
    )
    trainer = SFTTrainer(
        model=model,
        processing_class=tokenizer,
        train_dataset=train_dataset,
        eval_dataset=val_dataset,
        args=training_args,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    torch.cuda.reset_peak_memory_stats()
    resume_from = latest_checkpoint(args.output_dir)
    if resume_from:
        print(f"resuming from {resume_from}", flush=True)
    train_result = trainer.train(resume_from_checkpoint=resume_from)
    torch.cuda.synchronize()

    final_dir = args.output_dir / "final"
    final_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(str(final_dir))
    processor.save_pretrained(str(final_dir))

    losses = [entry["loss"] for entry in trainer.state.log_history if "loss" in entry]
    metrics = {
        "base_model": args.model,
        "transformers_version": transformers_version,
        "train_data": str(args.train_data),
        "validation_data": str(args.val_data),
        "train_rows": len(train_rows),
        "validation_rows": len(val_rows),
        "train_rows_by_source": dict(sorted(Counter(row.get("source", "unspecified") for row in train_rows).items())),
        "validation_rows_by_source": dict(sorted(Counter(row.get("source", "unspecified") for row in val_rows).items())),
        "train_token_stats": train_token_stats,
        "validation_token_stats": val_token_stats,
        "dtype": "bfloat16; Unsloth may retain selected Qwen3.5 layers in float32",
        "load_in_4bit": False,
        "target_modules": list(DEFAULT_TARGET_MODULES),
        "trainable_parameters": trainable_params,
        "epochs": args.epochs,
        "evaluation_strategy": args.eval_strategy,
        "batch_size": args.batch_size,
        "gradient_accumulation_steps": args.grad_accum,
        "global_step": trainer.state.global_step,
        "elapsed_seconds": round(time.time() - started, 1),
        "peak_cuda_memory_mib": round(torch.cuda.max_memory_allocated() / 2**20, 1),
        "loss_first": losses[0] if losses else None,
        "loss_last": losses[-1] if losses else None,
        "eval_loss_first": next((entry["eval_loss"] for entry in trainer.state.log_history if "eval_loss" in entry), None),
        "eval_loss_last": next((entry["eval_loss"] for entry in reversed(trainer.state.log_history) if "eval_loss" in entry), None),
        "train_result": str(train_result),
    }
    metrics_path = args.output_dir / "training_metrics.json"
    metrics_path.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metrics, indent=2), flush=True)
    print(f"adapter saved to {final_dir}; metrics saved to {metrics_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
