# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Add a local 210-item ladder scorer and a Cactus CQ conversion launcher for the combined adapter (#5, #6)

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
