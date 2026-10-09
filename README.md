# Qwen3.5-2B fine-tuning workspace

This workspace contains the baseline LoRA training path and the rationale
distillation corpus used before adding RLM tool-call trajectories. Training uses
the native `Qwen/Qwen3.5-2B` checkpoint with BF16 weights and LoRA adapters.
The model is not loaded in 4-bit.

## Training environment

Reuse the existing isolated Transformers 5 environment when the sibling
`localllm-qwen3.5` checkout is available:

```bash
./scripts/run_qwen35_sft.sh
```

By default the launcher uses
`../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python`. On this
machine that environment provides Transformers 5.5.0 and uses the
`qwen3-train` Conda environment for shared packages such as Unsloth 2026.6.9,
PyTorch 2.10, and TRL 0.24.0. Set `QWEN35_PYTHON` to select another compatible
Python executable.

If that environment is unavailable, install a CUDA-matched PyTorch build first,
then install `requirements-training.txt`. Qwen3.5 requires Transformers 5.2.0 or
newer. Training stops when CUDA or BF16 support is unavailable; it does not
switch to FP16. Unsloth keeps selected Qwen3.5 Gated DeltaNet layers in FP32 to
avoid unstable FP16 gradient norms.

## Train the rationale baseline

```bash
./scripts/run_qwen35_sft.sh \
  --model Qwen/Qwen3.5-2B \
  --train-data data/train_distill.jsonl \
  --val-data data/val_distill.jsonl \
  --output-dir outputs/lora-adapter-qwen35-distill
```

The default recipe preserves the established rationale SFT settings: four
epochs, learning rate `5e-5`, rank 32 / alpha 64 LoRA, sequence length 2048,
and effective batch size 16 (micro-batch 2 with accumulation 8). The expanded
Qwen3.5 target set includes Gated DeltaNet, full-attention, and MLP projections.
`adamw_8bit` applies to optimizer state only; the model weights remain BF16.
Budget about 5 GB for the BF16 model weights alone; optimizer state and training
activations require additional GPU memory.
The script writes checkpoints, a final adapter, and training metrics under the
ignored `outputs/` directory.

## Rebuild the rationale data

```bash
python3 scripts/build_distill_corpus.py
```

This runs the copied `prepare_dataset_v3.py` pipeline with only the pinned
conversation corpus and the already-cleaned teacher rationale source. It uses a
90/10 split, seed 42, and the bare-letter rationale format. The full source and
prepared splits are checked in so data generation does not depend on network
access or another checkout.

The teacher rationale file is the post-filter source from the earlier Qwen3
distillation work. That upstream stage removed benchmark and sealed evaluation
overlaps before producing this file. It stores rationale text between legacy
`thinking` / `response` markers, while the original split builder only parsed
`<think>` tags. This workspace adapts that parser and preserves the rationale
inside `<think>` blocks when regenerating the corpus. The builder here never
reads evaluation questions, answers, or sealed test files. Dataset provenance,
counts, and SHA-256 hashes are recorded in `data/distill_manifest.json`.

The regenerated split files have different hashes from the earlier workspace
snapshots: those snapshots had empty `<think>` blocks for teacher-generated
MCQs. This port keeps the original item counts and split seed while restoring
the teacher rationale targets.
