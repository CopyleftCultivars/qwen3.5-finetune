# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Add the opt-in `--render app_chat_template` trainer mode (#63) so training can match the bytes the deployed app serves: `plain` (the default) is the historic `<|im_start|>{role}\n{content}<|im_end|>` rendering and is byte-for-byte unchanged, while `app_chat_template` renders the assistant generation boundary as `<|im_start|>assistant\n<think>\n\n</think>\n\n{content}<|im_end|>` exactly as Cactus `Tokenizer::format_qwen_style` (`vendor/cactus-sdk/cactus-engine/src/tokenizer.cpp:673-695`) and the Qwen3.5 `chat_template.jinja:147-154`, keeps earlier assistant history plain, never double-prefixes the retention rows that already carry a `<think>` block, and implies assistant-only masking so the empty think block is masked out of the loss (`scripts/train_qwen35_sft.py`; metrics record `render`, `app_chat_template` and the effective `assistant_only_loss`). Add `scripts/run_qwen35_targeted_v5_sft.sh` for the app-rendered corpus `../bioaccumulator-benchmark-workspace/corpus/targeted_v5`. `tests/test_app_chat_template_render.py` pins the renderer (single boundary vs history, no double prefix, unchanged default), the masking (with a deterministic character tokenizer so it runs without `transformers`), the CLI default and the byte-parity of sampled v5 rows against `scripts/run_hf_gpu_tool_benchmark.py::cactus_qwen_prompt(runner_default)` (#63)
- Add a local 210-item ladder scorer and a Cactus CQ conversion launcher for the combined adapter (#5, #6)
- Add flag-gated assistant-only loss masking and the targeted-v2 retrain script for the BF16 candidate; the trainer masks system/user/history tokens, honours the corpus `target_turn`/`messages[i].train` marker, and reports/verifies the masked-token fraction (#44)

### Fixed

### Changed
- Epic: Qwen3.5-2B finetune + tool-calling + on-device benchmark (#1)
- Run 210-item natural_fertilizers ladder benchmark on the new Qwen3.5 model (#6)
- Cactus-convert the trained Qwen3.5-2B LoRA adapter (#5)
- Build combined training recipe: distillation-rationale data + RLM tool-call trajectories (#4)
- Pixel 7 on-device validation of the finetuned Qwen3.5 model (#7)
- Default fused cross-entropy chunks to 0.25 GiB, which completed the four-epoch combined Qwen3.5 run on the 12 GB GPU (#4)
- Port local_fertilizer_plants (full NF-recipe chain) from Dart to Python (#9)
- Harness: capture model-initiated tool calls (Dart + Python, dynamic trigger) (#8)
- Copy over existing rlm_slice and natural_farming_chat implementations (#3)
