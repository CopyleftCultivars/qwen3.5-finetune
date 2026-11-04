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
tool/build_debug.sh   --install      # debug build (used by the benchmark harness)
tool/build_release.sh --install      # release build (AOT, use this on a phone)
```

`--device SERIAL` (or `ANDROID_SERIAL`) picks the phone. The release build is still signed with the debug key; a store release needs a real keystore (`android/app/build.gradle.kts`). There is no CI.

## The model

On first launch the app downloads the model (about 1.1 GB, so use Wi-Fi) from Hugging Face and keeps it in its private storage. Nothing else needs installing and no login is needed.

* Model repository: [`CopyleftCultivars/qwen3.5-2b-natural-farming-v5-cactus-cq4`](https://huggingface.co/CopyleftCultivars/qwen3.5-2b-natural-farming-v5-cactus-cq4) (the Cactus CQ4 bundle). The bf16 fine-tune it came from is [`CopyleftCultivars/qwen3.5-2b-natural-farming-v5`](https://huggingface.co/CopyleftCultivars/qwen3.5-2b-natural-farming-v5).
* The app is pinned to one commit of that repository (`hostedQwen35Model` in `lib/services/model_downloader.dart`), so a later push cannot change what a phone gets. To ship a new model: upload it, then change the pinned revision. Phones with the older revision replace their copy on the next launch.
* Every file is checked against the size and hash the repository lists (SHA-256, or the git blob SHA-1 for small files) before it is kept. An interrupted download resumes where it stopped; `config.txt`, the "installed" marker, is fetched last and the folder is moved into place in one step. If the download fails, the loading screen shows the reason and a "Try again" button.

Developer and benchmark phones can skip the download by pushing the bundle to the phone once (`tool/stage_model.sh`, which needs the `outputs/` folders of this repository). Choose the source when building:

```sh
tool/build_release.sh --install --model-source hosted   # always download (what a new user gets)
tool/build_release.sh --install --model-source staged   # only the pushed bundle
tool/build_release.sh --install                         # auto: pushed bundle if complete, else download
```

To test the real download against Hugging Face from a computer (about 1.1 GB):
`HF_NETWORK_TEST=1 flutter test test/model_downloader_network_test.dart`.

## Tests

`flutter test` runs the unit tests, including the golden files under `test/fixtures`. The on-device benchmark harness lives in the bioaccumulator-benchmark repo; it copies its own `integration_test` files into a disposable copy of this app.

Restore point before the pipeline was added: git tag `pre-pipeline-2026-11-04`.
