# Per-session memory and session management (issue #21)

Date: 2026-10-19  
Branch: `issue-21-session-memory` (from `main` @ `81e654c`, which includes
#19)  
Owner work: `wip/owner-natural-farming-chat-2026-10-19` @ `43d7ed8`

## What landed

* `lib/models/chat_session.dart` — `ChatSession` (id, title, timestamps and
  its own message list) and `ChatMessage` (moved out of `main.dart`, still
  exported from `main.dart` for existing imports). A message keeps its
  deterministic recipe-tool JSON for the `Show full recipe` card.
* `lib/services/session_store.dart` — local session persistence: create,
  switch, rename, delete, save, restore the last active session, and migrate
  the old single `chat_history` value once.
* `lib/services/conversation_history.dart` — the #19 history rules extracted
  unchanged into `buildSessionConversationHistory`, now applied to exactly one
  session's messages.
* `lib/main.dart` — the drawer is a session switcher (`New chat`, active
  session highlighted, per-session `Rename` / `Delete`); the AppBar shows the
  active session title; the active session's messages are the only list the
  chat screen reads or writes.
* `test/session_store_test.dart` — lifecycle, reload persistence, recipe
  continuation, history isolation and legacy migration.

## Merge of the owner's memory work

The branch was created from `main` @ `81e654c` and the owner's branch was
merged with a real merge commit (`--no-ff`). The owner's commit `43d7ed8` and
its authorship are unchanged; no rebase, amend or force operation was used.

The only conflict was `pubspec.lock`. It was resolved by keeping the owner's
`memlocal` path dependency and running `flutter pub get`, which resolved the
lock against this host's Flutter 3.38.8 toolchain. That pinned six transitive
packages (`characters`, `matcher`, `material_color_utilities`, `meta`,
`test_api`, `vector_math`) and the SDK constraint to versions compatible with
the installed SDK and `memlocal`'s constraints. `main.dart` and
`analysis_options.yaml` auto-merged.

`lib/services/memory_service.dart` is included exactly as the owner wrote it.
Its keyword (`memlocal`) flavor is still selected by `createMemoryService` and
initialized after the chat model, with a caught failure leaving chat usable.
**No recall result is added to any model prompt, tool prompt or history in
#21.** That remains the opt-in #22 change.

The `memlocal` dependency is
`/home/goya/agent-workspace/memlocal_core/flutter` (a Rust FFI plugin). The
Android debug build compiled the plugin for `aarch64-linux-android`,
`i686-linux-android` and `x86_64-linux-android` and produced
`build/app/outputs/flutter-apk/app-qwen35-debug.apk`, so no native-build
workaround or dependency drop was needed. `memlocal_core` itself was only
read.

## Design: storage schema

Sessions are persisted locally in `SharedPreferences` under one versioned
envelope:

```json
{
  "schema_version": "chat_sessions_v1",
  "sessions": [
    {
      "id": "session-<microseconds>-<counter>",
      "title": "Tomato planning",
      "createdAt": "2026-10-19T...",
      "updatedAt": "2026-10-19T...",
      "messages": [
        {
          "content": "...",
          "isUser": true,
          "timestamp": "2026-10-19T...",
          "recipe": {"status": "ok", "...": "..."}
        }
      ]
    }
  ]
}
```

`active_chat_session_id` stores the last active session and is restored on
launch. Keys written before #21 (`chat_history`) are converted once into an
`Earlier chat` session and removed, so existing conversations are not lost.
Sessions are listed newest-activity-first.

SharedPreferences is reused instead of adding entities to ObjectBox because
the existing ObjectBox database is the read-only RAG database whose schema is
kept byte-compatible with the Cactus reference implementation. Regenerating
that model for chat rows would risk the portability guarantee, while session
JSON is small and already fits the app's persistence layer. The store API is
isolated, so a later move to ObjectBox or SQLite does not change the UI or
`#20` integration.

## Design: UI flow

* The drawer lists sessions, highlighting the active one and showing its
  message count. `New chat` creates an empty session and adds the same
  UI-only welcome message as first launch.
* Tapping a session saves nothing implicitly that was not already saved on the
  previous turn; it switches the active id, reloads that session's own message
  list, and persists the selection.
* Each row's overflow menu offers `Rename` and `Delete`. Rename rejects an
  empty title. Delete asks for confirmation; deleting the active session
  selects the most recent remaining one, and deleting the last session creates
  a fresh empty session so the app always has an active chat.
* Session controls are disabled while a model turn is in flight, so a reply
  cannot land in a different session.
* `Clear Current Chat` only clears the active session.
* Recipe cards survive switching and relaunch because the recipe JSON is part
  of each persisted assistant message.

## Design: history and the #20 API

`buildSessionConversationHistory` is byte-for-byte the #19 rule: every message
in order as `user` or `assistant`, no truncation, excluding only the leading
UI-only welcome message. Because `_messages` is the active session's list and
never a merged list, a model turn cannot see another session's turns.

For #20's `Continue chat?`, `SessionStore.createSessionFromRecipe` creates and
activates a new session containing exactly two turns: the user recipe message
and the assistant reply carrying the full deterministic recipe JSON:

```dart
final session = await sessionStore.createSessionFromRecipe(
  userMessage: recipeUserMessage,
  assistantReply: replyText,
  recipe: recipeResult,
  title: 'Tomato + nettle',
);
```

The first turn is a user turn, so the welcome-exclusion rule does not drop it.
The new session is persisted before the call returns.

## Deferred to #22

* Injecting `MemoryService.recall` into the system/history/user prompt.
* Writing chat turns or user-approved facts into `MemoryService.add`.
* Memory list/delete/clear screens (the owner's service intentionally throws
  `UnsupportedError` for these until `memlocal_core` #4 provides the FFI
  operations; no semantics were changed here).
* Cross-session or global memory. #21 context is strictly local to the active
  session.

## Checks run

* `flutter analyze` — 123 total findings, of which 18 are the pre-existing
  `packages/cactus/example` errors/infos; the remaining 105 are identical, by
  message and file, to a detached `main` worktree at `81e654c`. No finding is
  new.
* `flutter test` — 66 tests pass, including the owner's
  `memory_service_test.dart`, the new session/history tests, and all #19
  recipe tests.
* `/home/goya/storage/CopyLeftCultivars/finetune-gemma4/.venv/bin/python -m
  unittest discover -s tests` — 66 tests pass.
* `/home/goya/anaconda3/envs/clc_local/bin/python
  natural_farming_chat/tool/compare_app_prompt_parity.py` — 120/120 decision
  prompts, 80/80 instruction prompts, 80/80 tool contexts and 120/120
  histories exact; app tools equal the runner tools.
* `flutter build apk --debug --flavor qwen35 --target-platform android-arm64`
  — built the debug APK with the `memlocal` Rust FFI plugin; `./gradlew
  --stop` was run afterwards.

No GPU was used. `outputs/`, `vendor/`, the reference workspace and
`/home/goya/agent-workspace/memlocal_core` were not modified.
