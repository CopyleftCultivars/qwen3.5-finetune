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

  test('chat never pre-routes the trigger prefix or shrinks history', () {
    final source = File('lib/main.dart').readAsStringSync();

    // (A) The model decides: no prefix pre-router in chat.
    expect(source, isNot(contains('hasTriggerPrefix')));
    expect(source, isNot(contains('_handleRecipeTrigger')));
    expect(source, isNot(contains('parseTrigger')));

    // (C) The full six-tool catalog is passed explicitly, so _routeTools
    // cannot reduce it on the phone.
    expect(source, contains('generateCompletionWithTools('));
    expect(source, contains('tools: ModelService.farmingTools'));

    // (D) Full history, no character-budget truncation.
    expect(source, isNot(contains('maxChars')));
  });
}
