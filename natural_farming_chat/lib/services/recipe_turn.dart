import 'package:cactus/models/types.dart';

import 'recipe_prompt.dart';

/// Builds the two model turns of the `trigger_recipe_v1` recipe pipeline.
///
/// The runner (`scripts/run_hf_gpu_tool_benchmark.py`) renders:
///
/// * decision: `[system, *history, user]` with the six tools;
/// * instruction: `[system, *history, user, assistant, tool]` with the same
///   six tools, where `assistant` is the model's own native tool-call response
///   and `tool` is the served view inside `tool_result_context`.
///
/// This file is pure Dart so `tool/export_recipe_turn_messages.dart` can export
/// the app's real message lists for prompt-parity checks.
List<ChatMessage> buildRecipeDecisionMessages({
  required String userMessage,
  required List<ChatMessage> history,
}) {
  return [
    ChatMessage(content: recipeSystemPrompt, role: 'system'),
    ...history,
    ChatMessage(content: userMessage, role: 'user'),
  ];
}

List<ChatMessage> buildRecipeInstructionMessages({
  required String userMessage,
  required List<ChatMessage> history,
  required String assistantToolCallResponse,
  required String toolResultContext,
}) {
  return [
    ChatMessage(content: recipeSystemPrompt, role: 'system'),
    ...history,
    ChatMessage(content: userMessage, role: 'user'),
    ChatMessage(content: assistantToolCallResponse, role: 'assistant'),
    ChatMessage(content: toolResultContext, role: 'tool'),
  ];
}
