#!/usr/bin/env dart
// Export the app's real recipe-turn message lists and tool catalog.
//
// This is the app side of the #19 prompt-parity check. The Python comparison
// script (`tool/compare_app_prompt_parity.py`) renders this export with the
// benchmark runner's own `cactus_qwen_prompt` and compares it with the prompts
// recorded for candidate 4. The exporter only reads the development split.
//
// Run from `natural_farming_chat/`:
//
//   dart run tool/export_recipe_turn_messages.dart \
//     --scenarios ../../bioaccumulator-benchmark-workspace/scenarios/v3/development.jsonl \
//     --results <seed-42 results.json> --results <seed-43> --results <seed-44> \
//     --output /tmp/issue-19-app-prompt-export.json

import 'dart:convert';
import 'dart:io';

import 'package:cactus/models/types.dart';
import 'package:natural_farming_chat/services/farming_tools.dart';
import 'package:natural_farming_chat/services/recipe_turn.dart';
import 'package:natural_farming_chat/services/tool_result_context.dart';

void main(List<String> argv) {
  final options = _parseArgs(argv);
  final scenariosPath = options['scenarios']?.first;
  final resultsPaths = options['results'] ?? const <String>[];
  final outputPath = options['output']?.first;
  if (scenariosPath == null || resultsPaths.isEmpty || outputPath == null) {
    stderr.writeln(
      'usage: dart run tool/export_recipe_turn_messages.dart '
      '--scenarios <development.jsonl> --results <results.json> '
      '[--results <results.json> ...] --output <export.json>',
    );
    exitCode = 64;
    return;
  }

  final scenarios = _readJsonl(File(scenariosPath));
  final export = <String, dynamic>{
    'schema_version': 'issue_19_app_prompt_export_v1',
    'scenario_path': scenariosPath,
    'scenario_turn_count': scenarios.fold<int>(
      0,
      (total, scenario) => total + (scenario['turns'] as List).length,
    ),
    'app_tools': [for (final tool in farmingToolsCatalog) tool.toJson()],
    'seeds': <Map<String, dynamic>>[],
  };

  for (final resultsPath in resultsPaths) {
    final results = jsonDecode(File(resultsPath).readAsStringSync()) as Map<String, dynamic>;
    final turns = results['turns'] as Map<String, dynamic>;
    final exportedTurns = <Map<String, dynamic>>[];

    for (final scenario in scenarios) {
      final caseId = scenario['case_id'] as String;
      final history = <ChatMessage>[];
      for (final turn in (scenario['turns'] as List).cast<Map<String, dynamic>>()) {
        final key = '$caseId::${turn['turn']}';
        final record = turns[key] as Map<String, dynamic>?;
        if (record == null) {
          throw StateError('$resultsPath is missing development turn $key');
        }

        final expectedHistory = _messageList(record['conversation_before']);
        final historyMatches = _sameMessages(history, expectedHistory);

        final user = record['user'] as String;
        final decisionMessages = buildRecipeDecisionMessages(
          userMessage: user,
          history: history,
        );

        final toolResults = <PromptToolResult>[];
        for (final item in (record['tool_results'] as List? ?? const [])) {
          final toolResult = item as Map<String, dynamic>;
          toolResults.add(
            PromptToolResult(
              toolName: toolResult['tool_name'] as String,
              success: toolResult['success'] as bool? ?? false,
              text:
                  (toolResult['model_result'] as String?) ??
                  (toolResult['result'] as String? ?? ''),
            ),
          );
        }
        final toolContext = formatToolResultsForPrompt(toolResults);
        final recordedContext = record['tool_result_context'] as String?;
        final toolContextMatches = recordedContext == null
            ? toolResults.isEmpty
            : toolContext == recordedContext;

        List<ChatMessage>? instructionMessages;
        final recordedInstruction = record['recipe_instruction_prompt'] as String?;
        if (recordedInstruction != null && recordedInstruction.isNotEmpty) {
          final decision = record['decision'] as Map<String, dynamic>?;
          instructionMessages = buildRecipeInstructionMessages(
            userMessage: user,
            history: history,
            assistantToolCallResponse:
                decision?['native_response'] as String? ?? '',
            toolResultContext: toolContext,
          );
        }

        exportedTurns.add({
          'key': key,
          'case_id': caseId,
          'turn': turn['turn'],
          'user': user,
          'history_match': historyMatches,
          if (!historyMatches)
            'history_expected': [
              for (final message in expectedHistory)
                {'role': message.role, 'content': message.content},
            ],
          'decision_messages': _exportMessages(decisionMessages),
          'tool_context': toolContext,
          'tool_context_match': toolContextMatches,
          'instruction_messages': instructionMessages == null
              ? null
              : _exportMessages(instructionMessages),
          'has_recorded_instruction': recordedInstruction != null,
        });

        history
          ..add(ChatMessage(content: user, role: 'user'))
          ..add(
            ChatMessage(
              content: record['final_answer'] as String? ?? '',
              role: 'assistant',
            ),
          );
      }
    }

    export['seeds'].add({
      'results_path': resultsPath,
      'turn_count': exportedTurns.length,
      'turns': exportedTurns,
    });
  }

  File(outputPath).writeAsStringSync(jsonEncode(export));
  stdout.writeln(
    'exported ${export['scenario_turn_count']} development turns '
    'for ${resultsPaths.length} seed result file(s) to $outputPath',
  );
}

Map<String, List<String>> _parseArgs(List<String> argv) {
  final options = <String, List<String>>{};
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (!arg.startsWith('--')) {
      throw ArgumentError('unexpected argument: $arg');
    }
    final name = arg.substring(2);
    if (i + 1 >= argv.length) {
      throw ArgumentError('missing value for --$name');
    }
    options.putIfAbsent(name, () => <String>[]).add(argv[++i]);
  }
  return options;
}

List<Map<String, dynamic>> _readJsonl(File file) {
  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
}

List<ChatMessage> _messageList(dynamic raw) {
  return [
    for (final item in (raw as List? ?? const []))
      ChatMessage(
        role: (item as Map<String, dynamic>)['role'] as String,
        content: item['content'] as String,
      ),
  ];
}

bool _sameMessages(List<ChatMessage> actual, List<ChatMessage> expected) {
  if (actual.length != expected.length) return false;
  for (var i = 0; i < actual.length; i++) {
    if (actual[i].role != expected[i].role ||
        actual[i].content != expected[i].content) {
      return false;
    }
  }
  return true;
}

List<Map<String, String>> _exportMessages(List<ChatMessage> messages) {
  return [
    for (final message in messages)
      {'role': message.role, 'content': message.content},
  ];
}
