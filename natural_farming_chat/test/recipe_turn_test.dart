import 'dart:io';

import 'package:cactus/models/types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/farming_tools.dart';
import 'package:natural_farming_chat/services/recipe_prompt.dart';
import 'package:natural_farming_chat/services/recipe_turn.dart';
import 'package:natural_farming_chat/services/tool_result_context.dart';

void main() {
  test('the chat catalog is the six trained tools in runner order', () {
    expect(
      farmingToolsCatalog.map((tool) => tool.name).toList(),
      [
        'npk_lookup',
        'calculate',
        'local_fertilizer_plants',
        'bioaccumulator_ratio',
        'regional_recipe_lookup',
        'bioaccumulator_recipe',
      ],
    );
    expect(serializeCactusTools(farmingToolsCatalog), isNotEmpty);
  });

  group('recipe turn messages', () {
    final history = [
      ChatMessage(content: 'Earlier question', role: 'user'),
      ChatMessage(content: 'Earlier answer', role: 'assistant'),
    ];

    test('decision messages are system, history, user', () {
      final messages = buildRecipeDecisionMessages(
        userMessage: 'Bioaccumulator recipe: Banana for my Onion, 2 m2',
        history: history,
      );

      expect(messages.map((message) => message.role).toList(), [
        'system',
        'user',
        'assistant',
        'user',
      ]);
      expect(messages.first.content, recipeSystemPrompt);
      expect(messages.last.content, contains('Banana'));
    });

    test('instruction messages append the native tool call and tool result', () {
      final toolContext =
          'Tool Results:\n--- bioaccumulator_recipe ---\n'
          '{"status":"ok","served_view_version":"recipe_tool_served_view_v1"}'
          '\n\n';
      final messages = buildRecipeInstructionMessages(
        userMessage: 'Bioaccumulator recipe: Banana for my Onion, 2 m2',
        history: history,
        assistantToolCallResponse:
            '<tool_call>\n{"name": "bioaccumulator_recipe"}\n</tool_call>',
        toolResultContext: toolContext,
      );

      expect(messages.map((message) => message.role).toList(), [
        'system',
        'user',
        'assistant',
        'user',
        'assistant',
        'tool',
      ]);
      expect(messages[messages.length - 2].content, contains('<tool_call>'));
      expect(messages.last.content, toolContext);
    });
  });

  group('tool result context', () {
    test('matches the runner format for a successful result', () {
      expect(
        formatToolResultsForPrompt(const [
          PromptToolResult(
            toolName: 'bioaccumulator_recipe',
            success: true,
            text: '{"status":"ok"}',
          ),
        ]),
        'Tool Results:\n'
        '--- bioaccumulator_recipe ---\n'
        '{"status":"ok"}\n'
        '\n',
      );
    });

    test('matches the runner format for errors and multiple results', () {
      expect(
        formatToolResultsForPrompt(const [
          PromptToolResult(toolName: 'calculate', success: true, text: '4'),
          PromptToolResult(toolName: 'npk_lookup', success: false, text: 'bad'),
        ]),
        'Tool Results:\n'
        '--- calculate ---\n'
        '4\n'
        '\n'
        '--- npk_lookup ---\n'
        'Error: bad\n'
        '\n',
      );
    });
  });

  test('chat never pre-routes the tool decision; it only routes the history (#116)', () {
    final source = File('lib/main.dart').readAsStringSync();

    // (A) The model still decides whether to call: no prefix pre-router that
    // runs the recipe in chat. The trigger parser is used once, through
    // _triggerCode, only to choose the history (routeTurn).
    expect(source, isNot(contains('hasTriggerPrefix')));
    expect(source, isNot(contains('_handleRecipeTrigger')));
    expect('parseTrigger('.allMatches(source).length, 1);
    expect(source, contains('routeTurn('));

    // (C) The full six-tool catalog is passed explicitly, so _routeTools
    // cannot reduce it on the phone.
    expect(source, contains('generateCompletionWithTools('));
    expect(source, contains('tools: ModelService.farmingTools'));

    // (D) No character-budget truncation.
    expect(source, isNot(contains('maxChars')));
  });

  test('the send path runs the shared guard, answer check and turn limit (#119)', () {
    final source = File('lib/main.dart').readAsStringSync();

    // The guard sits between the decision and the executor, with the alias
    // groups built from the bundled catalogs; a blocked call never runs.
    expect(source, contains('grounding.applyGuard('));
    expect(source, contains('loadGuardAliasGroups()'));
    expect(source.indexOf('grounding.applyGuard('), lessThan(source.indexOf('_toolExecutor.executeAll(')));

    // The answer check repairs the instruction text of a recipe turn only.
    expect(source, contains('repairAnswer('));
    expect(source.indexOf('instructions.response.trim()'), lessThan(source.indexOf('repairAnswer(')));

    // The turn limit stops sending before any routing or model call.
    expect(source, contains('turnLimitStatus('));
    expect(source.indexOf('_turnLimitStatus().stopped'), lessThan(source.indexOf('routeTurn(')));

    // Logs carry counts and kinds only, never message text or argument values.
    expect(source, contains('[ARGUMENT_GUARD]'));
    expect(source, contains('[ANSWER_CHECK]'));
    expect(source, contains('_turnLimitStatus().logLine'));
  });
}
