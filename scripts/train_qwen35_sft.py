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
os.environ.setdefault("UNSLOTH_CE_LOSS_TARGET_GB", "0.25")

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
    parser.add_argument(
        "--assistant-only-loss",
        action="store_true",
        help=(
            "Mask system, user and history-assistant tokens with label -100. Rows carrying the "
            "#43 target marker (target_turn / messages[i].train) learn only their marked turn; "
            "unmarked rows learn their assistant turns. Off by default to keep the old full-text "
            "recipe reproducible."
        ),
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


def render_chat_with_spans(row: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    """Render a chat row and record where each message lives in the text.

    ``content_start`` is the first character after the ``<|im_start|>role\\n``
    header, so the header stays masked while the content and the closing
    ``<|im_end|>`` are learned.
    """
    parts: list[str] = []
    spans: list[dict[str, Any]] = []
    cursor = 0
    for index, message in enumerate(messages_for(row)):
        header = f"<|im_start|>{message['role']}\n"
        segment = header + message["content"].strip() + "<|im_end|>"
        if parts:
            parts.append("\n")
            cursor += 1
        start = cursor
        parts.append(segment)
        cursor += len(segment)
        spans.append(
            {
                "index": index,
                "role": message["role"],
                "start": start,
                "end": cursor,
                "content_start": start + len(header),
            }
        )
    return "".join(parts), spans


def target_message_indices(row: dict[str, Any]) -> list[int]:
    """Return the assistant turn(s) whose tokens carry loss labels.

    #43 marks the intended target turn with the row-level ``target_turn`` and
    the message-level ``train`` flag. Rows without a marker (the retained
    general farming data) fall back to assistant-only masking of every
    assistant turn.
    """
    messages = messages_for(row)
    marked = [index for index, message in enumerate(messages) if message.get("train") is True]
    target_turn = row.get("target_turn")
    if target_turn is not None:
        if not isinstance(target_turn, int) or not 0 <= target_turn < len(messages):
            raise ValueError(f"target_turn={target_turn!r} is outside the message list")
        if messages[target_turn]["role"] != "assistant":
            raise ValueError(
                f"target_turn={target_turn} points at a {messages[target_turn]['role']} turn"
            )
        if marked and target_turn not in marked:
            raise ValueError(
                f"target_turn={target_turn} is not marked train=true; marked={marked}"
            )
        return [target_turn]
    if marked:
        return marked
    return [index for index, message in enumerate(messages) if message["role"] == "assistant"]


def encode_masked_row(
    row: dict[str, Any], tokenizer, max_seq_len: int, fail_on_truncation: bool
) -> tuple[list[int], list[int]]:
    """Tokenize a row and set ``labels`` to -100 outside the target assistant turn."""
    text, spans = render_chat_with_spans(row)
    encoded = tokenizer(
        text,
        add_special_tokens=False,
        return_offsets_mapping=True,
        truncation=False,
    )
    input_ids = list(encoded["input_ids"])
    offsets = list(encoded["offset_mapping"])
    labels = [-100] * len(input_ids)
    for index in target_message_indices(row):
        span = spans[index]
        for token_index, (offset_start, offset_end) in enumerate(offsets):
            if offset_end > offset_start >= span["content_start"] and offset_end <= span["end"]:
                labels[token_index] = input_ids[token_index]
    if all(label == -100 for label in labels):
        raise ValueError("masked row has no labelled tokens (empty target turn?)")
    if len(input_ids) > max_seq_len:
        if fail_on_truncation:
            raise ValueError(
                f"rendered example has {len(input_ids)} tokens > max_seq_len={max_seq_len}"
            )
        input_ids = input_ids[:max_seq_len]
        labels = labels[:max_seq_len]
        if all(label == -100 for label in labels):
            raise ValueError("truncation removed every labelled token")
    return input_ids, labels


def build_masked_dataset(
    rows: list[dict[str, Any]], tokenizer, max_seq_len: int, fail_on_truncation: bool
):
    """Build a pre-tokenized dataset with assistant-only labels."""
    from datasets import Dataset

    input_ids: list[list[int]] = []
    labels: list[list[int]] = []
    lengths: list[int] = []
    labelled_tokens = 0
    total_tokens = 0
    for row in rows:
        row_ids, row_labels = encode_masked_row(
            row, tokenizer, max_seq_len, fail_on_truncation
        )
        lengths.append(len(row_ids))
        input_ids.append(row_ids)
        labels.append(row_labels)
        labelled_tokens += sum(1 for label in row_labels if label != -100)
        total_tokens += len(row_ids)

    dataset = Dataset.from_dict({"input_ids": input_ids, "labels": labels})
    return dataset, {
        "rows": len(rows),
        "max_input_tokens": max(lengths, default=0),
        "rows_over_max_seq_len": sum(length > max_seq_len for length in lengths),
        "total_tokens": total_tokens,
        "labelled_tokens": labelled_tokens,
        "masked_tokens": total_tokens - labelled_tokens,
        "masked_token_fraction": (
            round((total_tokens - labelled_tokens) / total_tokens, 6) if total_tokens else None
        ),
    }


def verify_masking_example(
    rows: list[dict[str, Any]], tokenizer
) -> dict[str, Any] | None:
    """Decode a marked row's labelled tokens to prove only the target is learned."""
    for row in rows:
        if row.get("target_turn") is None:
            continue
        messages = messages_for(row)
        index = row["target_turn"]
        input_ids, labels = encode_masked_row(row, tokenizer, 10**9, False)
        labelled_ids = [
            token_id
            for token_id, label in zip(input_ids, labels, strict=True)
            if label != -100
        ]
        decoded = tokenizer.decode(labelled_ids, skip_special_tokens=False)
        expected = messages[index]["content"].strip() + "<|im_end|>"
        _, spans = render_chat_with_spans(row)
        target_slice = render_chat(row)
        target_slice = target_slice[spans[index]["content_start"]:spans[index]["end"]]
        return {
            "row_source": row.get("source"),
            "example_id": row.get("example_id"),
            "target_turn": index,
            "target_role": messages[index]["role"],
            "expected_characters": len(expected),
            "decoded_characters": len(decoded),
            "decode_matches_target": decoded == expected,
            "labels_only_inside_target_slice": target_slice in decoded,
            "decoded_excerpt": decoded[:160],
        }
    return None


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

    dataset_builder = build_masked_dataset if args.assistant_only_loss else build_dataset
    train_dataset, train_token_stats = dataset_builder(
        train_rows, tokenizer, args.max_seq_len, args.fail_on_truncation
    )
    val_dataset, val_token_stats = dataset_builder(
        val_rows, tokenizer, args.max_seq_len, args.fail_on_truncation
    )
    print(
        f"tokenized train={len(train_dataset)} validation={len(val_dataset)} "
        f"max_tokens={max(train_token_stats['max_input_tokens'], val_token_stats['max_input_tokens'])} "
        f"truncated={train_token_stats['rows_over_max_seq_len'] + val_token_stats['rows_over_max_seq_len']} "
        f"assistant_only_loss={args.assistant_only_loss}",
        flush=True,
    )
    masking_verification = None
    if args.assistant_only_loss:
        masking_verification = verify_masking_example(train_rows, tokenizer)
        print(
            f"masked_token_fraction(train)={train_token_stats['masked_token_fraction']} "
            f"masked_token_fraction(val)={val_token_stats['masked_token_fraction']}",
            flush=True,
        )
        print(f"masking_verification={json.dumps(masking_verification)}", flush=True)
        if not masking_verification or not masking_verification["decode_matches_target"]:
            raise RuntimeError(
                "assistant-only masking verification failed: labelled tokens do not "
                "match the marked target turn"
            )

    from trl import SFTConfig, SFTTrainer

    class LossOnlySFTTrainer(SFTTrainer):
        def prediction_step(self, model, inputs, prediction_loss_only, ignore_keys=None):
            # Unsloth's VLM prediction hook forces full vocabulary logits on for
            # evaluation. Keep its fused, chunked loss path instead so long
            # validation examples do not allocate the complete logits tensor.
            inputs = self._prepare_inputs(inputs)
            previous_logits_setting = os.environ.get("UNSLOTH_RETURN_LOGITS")
            os.environ["UNSLOTH_RETURN_LOGITS"] = "0"
            try:
                try:
                    num_items_in_batch = self._get_num_items_in_batch(
                        [inputs], self.args.device
                    )
                except (AttributeError, TypeError):
                    num_items_in_batch = None
                with torch.no_grad():
                    with self.compute_loss_context_manager():
                        loss = self.compute_loss(
                            model,
                            inputs,
                            return_outputs=False,
                            num_items_in_batch=num_items_in_batch,
                        )
            finally:
                if previous_logits_setting is None:
                    os.environ.pop("UNSLOTH_RETURN_LOGITS", None)
                else:
                    os.environ["UNSLOTH_RETURN_LOGITS"] = previous_logits_setting
            return loss.detach().mean(), None, None

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
        prediction_loss_only=True,
        optim="adamw_8bit",
        lr_scheduler_type="cosine",
        weight_decay=0.01,
        seed=args.seed,
        report_to="wandb" if args.wandb else "none",
        run_name=args.run_name,
        packing=False,
    )
    trainer = LossOnlySFTTrainer(
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
        "assistant_only_loss": args.assistant_only_loss,
        "masking_verification": masking_verification,
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
