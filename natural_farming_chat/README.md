# Natural Farming Chat

Flutter application using the local Cactus plugin in `packages/cactus`. It runs a fine-tuned Qwen3.5-2B recipe model on the phone and answers bioaccumulator recipe requests through a deterministic recipe tool.

## What the app does with a message

`lib/main.dart` sends each message through one pipeline (all pure-Dart modules in `lib/services`, each with golden tests generated from the Python references in the bioaccumulator-benchmark repo):

1. **Turn limit** (`turn_limit.dart`): sending stops at 20 finished turns, or when the last decision prompt was above 4,096 tokens. A "New chat" button replaces the text field.
2. **Routed history** (`routed_history.dart`): a trigger message is decided with an empty history; a bare area after a missing-area refusal is rebuilt into the trigger message; every other message sees a compact ledger of earlier recipe results.
3. **Decision** by the model, with all six tools.
4. **Argument guard** (`argument_grounding.dart`, `guard_aliases.dart`): a recipe call whose plant, crop or area was not in the conversation does not run.
5. **Tool executor**, then the model writes the instructions.
6. **Answer check** (`answer_check.dart`): unit slips and missing assumption sentences are repaired from the tool result.

Logs carry counts and kinds only, never message text.

## Build and install

There is one Android flavor, `qwen35`, installed as `com.copyleftcultivars.natural_farming_chat.qwen35`. Both flows run `flutter test` first (skip with `--skip-tests`).

```sh
tool/stage_model.sh                  # once per device: push the model bundle to /data/local/tmp
tool/build_debug.sh   --install      # debug build (used by the benchmark harness)
tool/build_release.sh --install      # release build (AOT, use this on a phone)
```

`--device SERIAL` (or `ANDROID_SERIAL`) picks the phone. On first launch the app copies the staged bundle into its private storage (a few minutes). The release build is still signed with the debug key; a store release needs a real keystore (`android/app/build.gradle.kts`). There is no CI.

## Tests

`flutter test` runs the unit tests, including the golden files under `test/fixtures`. The on-device benchmark harness lives in the bioaccumulator-benchmark repo; it copies its own `integration_test` files into a disposable copy of this app.

Restore point before the pipeline was added: git tag `pre-pipeline-2026-11-04`.
