# Recipe tool in the app (issue #19)

Date: 2026-10-19  
Branch: `issue-19-recipe-tool-app` (from `main` @ `13be51c`)  
Reference: `../bioaccumulator-benchmark-workspace` (read-only)

## What landed

* `lib/services/recipe_tool_service.dart` — a deterministic Dart port of
  `recipe_tool_oracle.py`:
  * the full `recipe-tool-result-v2` JSON (ratios, nutrition track, booster
    track, assumptions, warnings);
  * the compact `recipe_tool_served_view_v1` projection (three significant
    figures) that the model reads in QUICK mode;
  * `parse_trigger` with the oracle's exact regex, unit aliases,
    `unsupported_unit` / `trigger_not_matched` semantics and error text.
* `lib/services/recipe_prompt.dart` — the runner's `trigger_recipe_v1` system
  prompt and six-tool catalog, including the `bioaccumulator_recipe` definition
  from the #57 serving protocol. No description or error text carries an
  example value.
* `lib/services/farming_tools.dart` — the same six tools in runner order in a
  Flutter-free file, so the parity exporter loads the catalog the app actually
  sends.
* `lib/services/recipe_turn.dart` — pure builders for the decision and
  instruction message lists:
  * decision: `[system, *history, user]`;
  * instruction: `[system, *history, user, assistant tool call, tool served view]`.
* `lib/services/tool_result_context.dart` — `formatToolResultsForPrompt`, a
  byte-for-byte mirror of the runner's `tool_result_context`, shared by
  `ToolExecutor` and the parity exporter.
* `lib/services/tool_executor.dart` — registers `bioaccumulator_recipe`; the
  model-facing `result` is the canonical served view and the full result rides
  in `ToolResult.data` for the card.
* `lib/main.dart` + `lib/widgets/recipe_card.dart`:
  * fixed-phrase in-chat hint: `Bioaccumulator recipe: <candidate plant> for my
    <crop>, <area> m2`;
  * QUICK / DETAILED selector;
  * every chat message goes through the model with all six tools — there is no
    trigger-prefix pre-router;
  * QUICK executes the model-requested tool, gives the model only the served
    view in a runner-faithful instruction turn, and shows its instructions;
  * DETAILED still lets the model decide, then renders the full result
    deterministically without the instruction pass;
  * both modes expose `Show full recipe`, which displays all amounts, steps,
    assumptions and sources.
* Bundled contract data (verbatim copies under `assets/recipe_tool/`): #55
  mapping + approved derivations, approved dosing constants, approved trigger
  proposal, and the three v2/v1 JSON schemas.
* Configurable Qwen3.5 bundle: `ModelService.configureQwen35Model(slug)` (and
  the persisted `qwen35_model_slug` preference). The default remains the current
  `qwen35-recipe-v5-cactus-cq4-hessian` (candidate 4's Hessian-calibrated
  CQ4 bundle); override with `configureQwen35Model(slug)` /
  `resetQwen35Model()` and the persisted `qwen35_model_slug` preference.

## Operator changes A–F

### (A) The model decides; no chat prefix router

`_sendMessage` no longer inspects the text. It builds history, adds the user
message, and calls `_generateWithTools`, which always invokes
`generateCompletionWithTools` with the six tools. A
`bioaccumulator_recipe` call is executed by `ToolExecutor`. `parseTrigger`
remains available for the in-chat hint and the future form tab (#20) but is not
used to route chat messages. A regression test reads `lib/main.dart` and fails
if `hasTriggerPrefix`, `_handleRecipeTrigger` or `parseTrigger` reappears.

### (B) Runner-faithful instruction turn

After a recipe call, the app builds:

```text
[system: recipeSystemPrompt,
 *history,
 user,
 assistant: model's raw native response (the <tool_call> text),
 tool: tool_result_context(all executed results)]
```

and passes the same six tools. Cactus renders this through
`Tokenizer::format_qwen_style`
(`vendor/cactus-sdk/cactus-engine/src/tokenizer.cpp:621-695`):

* the six-tool block is appended to the system message;
* the assistant content is emitted verbatim (no `tool_calls` field is needed;
  the app carries the model's raw `<tool_call>` text exactly as the runner
  stores `native_response`);
* role `tool` becomes
  `<|im_start|>user\n<tool_response>\n…\n</tool_response><|im_end|>\n`;
* the generation boundary is
  `<|im_start|>assistant\n<think>\n\n</think>\n\n`, the deployed
  `runner_default` prefix candidate 4 was trained and gated on.

That is byte-identical to `run_hf_gpu_tool_benchmark.cactus_qwen_prompt` with
the default assistant prefix for these message shapes. The only known gap is a
model-output edge case, not prompt construction: if a raw native response
itself contained a `<think>…</think>` block, the engine would parse and
re-render it as a think block, while the runner inserts the raw text verbatim.
Candidate 4's recorded recipe tool calls contain no think block. The UI welcome
message is also excluded from history because the runner has no equivalent
turn.

### (C) All six tools, no embedding routing

The chat path passes `tools: ModelService.farmingTools` explicitly, so
`generateCompletionWithTools` never calls `_routeTools`; the embedding router
cannot reduce the catalog to two tools on the phone. The order is the trained
order: `npk_lookup`, `calculate`, `local_fertilizer_plants`,
`bioaccumulator_ratio`, `regional_recipe_lookup`, `bioaccumulator_recipe`.

### (D) Full runner history

`_buildConversationHistory` now emits every earlier turn (`user`, then the full
assistant final answer) in order, with no 800/2000-character budget. The
welcome message is the only omission. History is built before the current user
message is appended, so the current turn is not duplicated.

### (E) Prompt parity against the #64 records

`tool/export_recipe_turn_messages.dart` (pure Dart, run with `dart run`) builds
the app's real message lists and exports the real tool catalog for every v3
**development** turn. `tool/compare_app_prompt_parity.py` renders that export
with the runner's own `cactus_qwen_prompt` (default `runner_default` prefix) and
compares it with the `decision_prompt` and `recipe_instruction_prompt` recorded
for candidate 4 (`issue_64_ckpt423_seed_{42,43,44}`). The script reads the
development split only; it never opens the test split and writes nothing in the
reference workspace. The committed summary is
`docs/issue-19-prompt-parity-2026-10-19.json`.

| artifact | exact matches |
|---|---|
| decision prompts, seed 42 / 43 / 44 | 40/40, 40/40, 40/40 → **120/120** |
| instruction prompts, seed 42 / 43 / 44 | 27/27, 26/26, 27/27 → **80/80** |
| tool-result contexts | **80/80** |
| reconstructed histories | **120/120** |
| app tool schema vs runner schema | **identical** (`sha256 cd6e6b85…`) |
| app tool prompt vs runner prompt | **identical** (`sha256 216c4e45…`) |

There are no mismatches. Seed 43 made 26 recipe tool calls across its 40
development turns (one turn had no call), hence 26 recorded instruction prompts;
seeds 42 and 44 made 27 each. The exporter uses the model's recorded native
tool-call text as the assistant turn and the recorded executed tool results for
the tool turn.

### (F) `pubspec.lock`

`natural_farming_chat/pubspec.lock` is restored to `main`'s version. #19 adds
only assets and Dart source, no dependencies.

## Conformance

Fixtures were generated by
`tool/generate_recipe_tool_goldens.py`, which runs the reference MCP server's
`ToolExecutor` over every `bioaccumulator_recipe` call in
`scenarios/v3/development.jsonl` (28) and `scenarios/v3/validation.jsonl` (28),
and records the full result plus the served view. The generator also asserts
each full result's canonical sha256 against the scenario's frozen
`digest_sha256`. It never opens the `test` split.

`flutter test` asserts, for all 56 calls:

* every full-result value (numbers within the port's 1e-6 relative tolerance);
* canonical full-result bytes equal the oracle's;
* served-view canonical bytes equal the MCP server's `content[0].text`.

The trigger parser is checked against all 80 development/validation turns,
including the `no_call` turns' `trigger_not_matched` / `unsupported_unit` errors.

## Prompt pins

`test/recipe_prompt_parity_test.dart` compares the app constants to a fixture
generated from `run_hf_gpu_tool_benchmark.py`:

| artifact | sha256 |
|---|---|
| system prompt | `9da18292abc6eacc36f86ce88bf9b23b1e5e4731d7cb10c5c76d00d30143fe69` |
| six-tool prompt block (`runner_default`) | `216c4e45ce4cf59bac354f3ae85cb039a46870fdce4f3eafbeaf79e91676373d` |
| tool schema JSON | `cd6e6b850f5160a6ff2e04dc8fd5a68003ed5d5949fc4bb7a69d84d15bbff0c0` |

These equal the runner's `CACTUS_SYSTEM_PROMPT_SHA256`,
`RECIPE_TOOL_PROMPT_SHA256` and `RECIPE_TOOL_SCHEMA_SHA256`. The assistant
generation prefix stays Cactus's deployed `runner_default` path (empty think
block); the app does not override it.

## Checks run

* `flutter analyze` — 105 non-package findings, all pre-existing categories:
  61 `avoid_print`, 42 `prefer_interpolation_to_compose_strings`, and 2
  `dead_code` warnings in
  `integration_test/ladder_benchmark_multitool_test.dart`. `main` has 108 of
  the same categories (64 + 42 + 2). No error or warning is new, and this
  branch has three fewer `avoid_print` infos because the removed pre-router
  debug prints are gone. A detached `main` worktree was analyzed to confirm
  the comparison directly.
* `flutter test` — 58 tests pass (52 before, plus 6 turn/parity regression
  tests).
* `/home/goya/storage/CopyLeftCultivars/finetune-gemma4/.venv/bin/python -m
  unittest discover -s tests` — 66 tests pass.
* `/home/goya/anaconda3/envs/clc_local/bin/python
  natural_farming_chat/tool/compare_app_prompt_parity.py` — 120/120 decision
  prompts, 80/80 instruction prompts, 80/80 tool contexts, 120/120 histories,
  zero mismatches.
* `flutter build apk --debug --flavor qwen35` — built
  `build/app/outputs/flutter-apk/app-qwen35-debug.apk`.

No GPU was used, and `outputs/`, `vendor/` and the reference workspace were not
modified. No phone is attached to this host, so on-device checks remain out of
scope.
