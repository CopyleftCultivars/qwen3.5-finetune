# Recipe form tab (issue #20)

Date: 2026-10-21  
Branch: `issue-20-recipe-form` (from `main` @ `bc2aca3`, which includes #19
and #21)  
Reference: `../bioaccumulator-benchmark-workspace` (read-only, development data
only)

## What landed

* `lib/widgets/recipe_form_tab.dart` — a second tab beside Chat:
  * crop (required), candidate plant (required), area in m2 (required, > 0)
    and an optional location;
  * every name field is checked instantly against the recipe tool's own
    resolvers, with no model call. A resolved name shows its catalog match; an
    ambiguous candidate plant shows the tool's own suggestions; an unknown name
    says so;
  * the optional location is not a tool argument. It only moves suggestions
    whose common/scientific name appears in the matching
    `Locally_Growing_Plants_by_Region.json` entries ahead of the rest;
  * as soon as both names and the area resolve, the deterministic recipe tool
    runs live. The panel shows either `Computable: …`, the tool's own
    `error.code` and message (for example
    `candidate_not_offered_for_recipe`), or that the nutrition result exists but
    no standard booster batch is computable;
  * Submit builds the canonical trigger, dispatches
    `bioaccumulator_recipe` through the same `ToolExecutor` as chat, and renders
    the result as a chat-style user/assistant pair. The deterministic card is
    always available under `Show full recipe`; in QUICK mode the model's
    instruction pass is shown as well. DETAILED mode makes no model call;
  * `Continue chat?` calls `SessionStore.createSessionFromRecipe` with the
    trigger, the reply and the full recipe JSON, then switches to the Chat tab
    with that new session active.
* `lib/services/recipe_form.dart` — pure form builders:
  * `buildRecipeTriggerText` for the canonical
    `Bioaccumulator recipe: <candidate plant> for my <crop>, <area> m2` text;
  * `buildRecipeToolCallResponse` for the exact trained `<tool_call>` bytes
    (key order, spacing and whole-number `2.0` formatting);
  * the shared deterministic DETAILED summary (moved out of `main.dart`
    unchanged) and suggestion ranking.
* `lib/services/recipe_form_evaluator.dart` — the live pre-submit evaluation.
  It uses `RecipeToolService.resolveCrop`/`resolvePlant` and then
  `RecipeToolService.calculate`; it never touches `ModelService`.
* `lib/services/recipe_tool_service.dart` — the two existing private resolvers
  are now public (`resolveCrop`, `resolvePlant`) with unchanged matching
  behaviour, so the UI and the tool cannot disagree about what is supported.
* `lib/services/region_plant_service.dart` —
  `plantNameTermsForLocation` exposes the regional plant names used to rank
  form suggestions. No existing lookup changed.
* `lib/main.dart` — a `Chat` / `Recipe form` `TabBar`; the only new model entry
  point is `_generateFormRecipeInstructions`, which builds
  `[system, user, assistant tool call, tool served view]` with empty history and
  the same six tools. The chat path still decides every tool call itself.

## Prompt parity: form path

`tool/export_recipe_form_messages.dart` exports the app's real form messages for
the v3 **development** split; `tool/compare_form_prompt_parity.py` renders them
with the runner's own `cactus_qwen_prompt` and compares them with the candidate-4
`issue_64_ckpt423_seed_{42,43,44}` records. The test split is never read.

Selection: a single-turn call scenario where the form's canonical trigger equals
the recorded user text (an exact-template trigger), and candidate 4 produced the
expected `bioaccumulator_recipe` call on all three seeds.

* 18 single-turn trigger scenarios were called correctly on every seed.
* 14 are exact-template triggers; 4 use the accepted unit aliases (`m²`,
  `sq m`, `square metres`, `square meters`) and are reported separately because
  the form canonicalizes the unit to `m2` and therefore intentionally produces
  different user bytes from those recorded alias prompts.
* For the 14 exact cases × 3 seeds = 42 turns:
  * synthesized assistant `<tool_call>` text: **42/42** byte-identical to
    `decision.native_response`;
  * full instruction prompt: **42/42** byte-identical to
    `recipe_instruction_prompt`;
  * tool context: **42/42** byte-identical to `tool_result_context`.
* The app's six-tool schema still equals the runner's schema.

Evidence: `docs/issue-20-form-prompt-parity-2026-10-21.json`.

## Behavior preserved

* The existing chat parity script still reports 120/120 decision prompts,
  80/80 instruction prompts, 80/80 tool contexts and 120/120 histories across
  the three candidate-4 seeds.
* The 56 recipe tool conformance goldens (28 development + 28 validation) and
  the session store tests pass unchanged.
* The chat trigger still has no prefix pre-router; the form is a separate
  explicit mode.

## Verification

Commands run from `natural_farming_chat/` unless noted:

```text
flutter analyze
flutter test                                     # 71 tests passed
/home/goya/anaconda3/envs/clc_local/bin/python tool/compare_app_prompt_parity.py
# decision 120/120, instruction 80/80, tool contexts 80/80, histories 120/120
/home/goya/anaconda3/envs/clc_local/bin/python tool/compare_form_prompt_parity.py
# assistant 42/42, instruction 42/42, tool contexts 42/42
cd .. && /home/goya/storage/CopyLeftCultivars/finetune-gemma4/.venv/bin/python \
  -m unittest discover -s tests                  # 67 tests passed
```

`flutter analyze` reports only the pre-existing `avoid_print` infos in the app
and the pre-existing unresolved example-app imports under
`packages/cactus/example/`; the new files add no findings.

No GPU was used, no file under `outputs/` or `vendor/` was touched, and the
read-only reference workspace was never written. One debug APK build
(`flutter build apk --debug --flavor qwen35 --target-platform android-arm64`)
produced `build/app/outputs/flutter-apk/app-qwen35-debug.apk`; Gradle was
stopped afterwards.
