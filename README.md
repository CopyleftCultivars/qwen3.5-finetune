# Qwen3.5-2B fine-tuning workspace

This workspace contains the baseline rationale LoRA path and a combined recipe
for rationale data, RLM trajectories, and Cactus-native tool calls. Training
uses the native `Qwen/Qwen3.5-2B` checkpoint with BF16 weights and LoRA
adapters. The model is not loaded in 4-bit.

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

## Build the combined rationale and tool-call corpus

The combined run uses the curated 871-row Qwen3-8B teacher-rationale source in
`data/sources/teacher_distill_qwen3-8b.jsonl`. It does not use the 6,437-row
`train_distill.jsonl` corpus as a substitute; that corpus is a separate
conversation/MCQ mix. The combined builder parses the legacy `thinking` /
`response` markers into Qwen `<think>` blocks and groups answer-order variants
by `_source_question_id` before making its 90/10 split.

The G6 RLM data is rebuilt from the pinned, filtered G5 training-pool
trajectories:

```bash
python3 rlm_slice/build_g6_sft_dataset.py \
  --input data/sources/g5_trajectories_qwen3-8b_filtered.jsonl \
  --train-out data/sources/g6_rlm_sft_train.jsonl \
  --val-out data/sources/g6_rlm_sft_val.jsonl
python3 scripts/build_combined_qwen35_sft.py
```

G6 examples retain their Python LocalREPL instructions and code blocks. The
G6 `print(context)` action only displays the question supplied to the REPL, so
the builder does not relabel it as a farming lookup. Separate hand-authored
examples teach the two shared domain functions (`bioaccumulator_ratio` and
`regional_recipe_lookup`) using Cactus's Qwen JSON form:

```text
<tool_call>
{"name": "bioaccumulator_ratio", "arguments": {"crop": "Corn", "candidate_plant": "Comfrey"}}
</tool_call>
```

These examples use the argument schemas from `rlm_slice/domain_tools.py`,
include both positive calls and no-call answers, and are not drawn from any
benchmark. Positive training examples are repeated four times so the native
call target is not overwhelmed by the rationale and REPL rows. The manifest
records every source hash, split count, format decision, and the resulting
JSONL hashes in `data/combined_sft_manifest.json`.

The builder reads the pinned rationale source and G6 train/validation splits.
It does not open the sealed freeform test set or benchmark question/answer
files. The G5 source was produced from the training pool with the established
validation/dev hash denylist.

## Train the combined model

```bash
./scripts/run_qwen35_combined_sft.sh
```

The combined recipe uses four epochs, BF16, rank 32 / alpha 64 LoRA, sequence
length 4096, and micro-batch 1 with gradient accumulation 16. It evaluates the
held-out validation mixture each epoch and fails rather than silently
truncating examples that exceed the configured context. The final adapter and
training metrics are written to
`outputs/lora-adapter-qwen35-combined/final/` and
`outputs/lora-adapter-qwen35-combined/training_metrics.json`.
Unsloth's fused cross-entropy logits are chunked to a 0.25 GiB target by default
to keep peak memory manageable on the 12 GB training GPU; set
`UNSLOTH_CE_LOSS_TARGET_GB` before launch to adjust that cap. Validation
computes loss through the same chunked path without retaining full vocabulary
logits.

## Evaluate the combined adapter on the 210-item ladder

After training, score the local HF adapter against the graded 210-row benchmark
with the same system prompt, question prompt, 16-token greedy decode limit, and
answer extraction as the Flutter ladder harness:

```bash
../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python \
  scripts/run_natural_fertilizers_ladder.py \
  --benchmark ../benchmark-workspace/benchmarks/natural_fertilizers/natural_fertilizers_benchmark_v1_graded.jsonl
```

The result is written incrementally to
`outputs/natural_fertilizers_qwen35_combined_210.json`. The gold answer is only
used for scoring and is not included in the model prompt.

## Convert the adapter to Cactus CQ weights

Once training is complete, run the local Cactus converter with the adapter:

```bash
../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python \
  scripts/merge_qwen35_lora_for_cactus.py
QWEN35_MERGED_MODEL_DIR=outputs/qwen35-combined-merged \
  ./scripts/run_cactus_qwen35_combined_convert.sh
```

The command writes INT4 CQ weights and a conversion manifest to
`outputs/qwen35-combined-cactus-cq4/`. The merge runs in the training Python
environment so the Cactus CLI does not need its own `peft` installation. Cactus
uses `--weights-only`: its current local toolchain emits CQ weights while the
graph builder is being rewritten, so this conversion does not produce a
runnable bundle for the Flutter app or Pixel 7.

The completed training, conversion, and ladder results are recorded in
[`results/QWEN35_COMBINED_RUN_2026-10-09.md`](results/QWEN35_COMBINED_RUN_2026-10-09.md).
