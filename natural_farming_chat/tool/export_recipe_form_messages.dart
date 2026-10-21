#!/usr/bin/env dart
// Export the app's real recipe-form message lists for the #20 parity check.
//
// The form path makes no model tool decision: it validates the fields with the
// tool resolvers, builds the canonical trigger, synthesizes the trained
// `<tool_call>` assistant turn, and then runs the QUICK instruction pass with
// `[system, user, assistant tool call, tool served view]` and empty history.
//
// This exporter reads the v3 **development** scenarios and the candidate-4
// `issue_64_ckpt423_seed_{42,43,44}` result files (read-only). It selects every
// single-turn exact-trigger case that candidate 4 called correctly on all three
// seeds. Alias-unit cases are reported separately: the form canonicalizes the
// unit to `m2`, so their user text is intentionally not the recorded alias text.
//
// Run from `natural_farming_chat/`:
//
//   dart run tool/export_recipe_form_messages.dart \
//     --scenarios ../../bioaccumulator-benchmark-workspace/scenarios/v3/development.jsonl \
//     --results <seed-42 results.json> --results <seed-43> --results <seed-44> \
//     --output /tmp/issue-20-form-export.json

import 'dart:convert';
import 'dart:io';

import 'package:cactus/models/types.dart';
import 'package:natural_farming_chat/services/farming_tools.dart';
import 'package:natural_farming_chat/services/recipe_form.dart';
import 'package:natural_farming_chat/services/recipe_turn.dart';
import 'package:natural_farming_chat/services/tool_result_context.dart';

void main(List<String> argv) {
  final options = _parseArgs(argv);
  final scenariosPath = options['scenarios']?.first;
  final resultsPaths = options['results'] ?? const <String>[];
  final outputPath = options['output']?.first;
  if (scenariosPath == null || resultsPaths.isEmpty || outputPath == null) {
    stderr.writeln(
      'usage: dart run tool/export_recipe_form_messages.dart '
      '--scenarios <development.jsonl> --results <results.json> '
      '[--results <results.json> ...] --output <export.json>',
    );
    exitCode = 64;
    return;
  }

  final scenarios = _readJsonl(File(scenariosPath));
  final results = <String, Map<String, dynamic>>{
    for (final path in resultsPaths)
      path: jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
  };

  final singleTurn = <Map<String, dynamic>>[
    for (final scenario in scenarios)
      if ((scenario['turns'] as List).length == 1 &&
          (scenario['turns'] as List).first['expected_action'] == 'call')
        scenario,
  ];

  final calledCorrectlyOnEverySeed = <String>{
    for (final scenario in singleTurn)
      if (results.values.every(
        (result) => _calledCorrectly(
          ((result['turns']
                  as Map<String, dynamic>)['${scenario['case_id']}::1']
              as Map<String, dynamic>),
          scenario,
        ),
      ))
        scenario['case_id'] as String,
  };

  final exactCases = <String>[];
  final aliasCases = <String>[];
  for (final scenario in singleTurn) {
    final caseId = scenario['case_id'] as String;
    if (!calledCorrectlyOnEverySeed.contains(caseId)) continue;
    final args = _expectedArguments(scenario);
    final canonical = buildRecipeTriggerText(
      candidatePlant: args['candidate_plant'] as String,
      crop: args['crop'] as String,
      quantity: (args['quantity'] as num).toDouble(),
    );
    final recordedUser = (scenario['turns'] as List).first['user'] as String;
    (canonical == recordedUser ? exactCases : aliasCases).add(caseId);
  }

  final export = <String, dynamic>{
    'schema_version': 'issue_20_recipe_form_export_v1',
    'scenario_path': scenariosPath,
    'single_turn_call_count': singleTurn.length,
    'called_correctly_on_every_seed_count': calledCorrectlyOnEverySeed.length,
    'exact_trigger_case_ids': exactCases,
    'alias_unit_case_ids': aliasCases,
    'app_tools': [for (final tool in farmingToolsCatalog) tool.toJson()],
    'seeds': <Map<String, dynamic>>[],
  };

  for (final resultsPath in resultsPaths) {
    final recordedTurns =
        results[resultsPath]!['turns'] as Map<String, dynamic>;
    final turns = <Map<String, dynamic>>[];
    for (final caseId in exactCases) {
      final key = '$caseId::1';
      final record = recordedTurns[key] as Map<String, dynamic>;
      final args = _expectedArguments(
        scenarios.firstWhere((scenario) => scenario['case_id'] == caseId),
      );
      final quantity = (args['quantity'] as num).toDouble();
      final userMessage = buildRecipeTriggerText(
        candidatePlant: args['candidate_plant'] as String,
        crop: args['crop'] as String,
        quantity: quantity,
      );
      final assistantToolCall = buildRecipeToolCallResponse(
        candidatePlant: args['candidate_plant'] as String,
        crop: args['crop'] as String,
        quantity: quantity,
      );
      final toolContext = _toolContext(record);
      final instructionMessages = buildRecipeInstructionMessages(
        userMessage: userMessage,
        history: const [],
        assistantToolCallResponse: assistantToolCall,
        toolResultContext: toolContext,
      );

      turns.add({
        'key': key,
        'case_id': caseId,
        'user': userMessage,
        'synthesized_assistant': assistantToolCall,
        'recorded_native_response':
            (record['decision'] as Map<String, dynamic>)['native_response'],
        'tool_context': toolContext,
        'recorded_tool_context': record['tool_result_context'],
        'instruction_messages': _exportMessages(instructionMessages),
        'has_recorded_instruction':
            (record['recipe_instruction_prompt'] as String?)?.isNotEmpty ??
            false,
      });
    }
    export['seeds'].add({
      'results_path': resultsPath,
      'turn_count': turns.length,
      'turns': turns,
    });
  }

  File(outputPath).writeAsStringSync(jsonEncode(export));
  stdout.writeln(
    'exported ${export['seeds'].length} seed(s), '
    '${exactCases.length} exact-trigger case(s), '
    '${aliasCases.length} alias-unit case(s) to $outputPath',
  );
}

Map<String, dynamic> _expectedArguments(Map<String, dynamic> scenario) {
  final turn = (scenario['turns'] as List).first as Map<String, dynamic>;
  final call = turn['expected_call'] as Map<String, dynamic>;
  return call['arguments'] as Map<String, dynamic>;
}

bool _calledCorrectly(
  Map<String, dynamic> record,
  Map<String, dynamic> scenario,
) {
  final expected =
      ((scenario['turns'] as List).first
              as Map<String, dynamic>)['expected_call']
          as Map<String, dynamic>;
  final calls =
      ((record['decision'] as Map<String, dynamic>?)?['tool_calls'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  if (calls.length != 1) return false;
  final call = calls.single;
  if (call['name'] != expected['name']) return false;
  final actual = call['arguments'] as Map<String, dynamic>;
  final accepted = expected['accepted_argument_values'] as Map<String, dynamic>;
  if (actual.keys.length != accepted.keys.length) return false;
  for (final entry in actual.entries) {
    final allowed = accepted[entry.key];
    if (allowed is! List) return false;
    if (entry.value is num) {
      final value = (entry.value as num).toDouble();
      if (!allowed.any(
        (candidate) =>
            candidate is num && (candidate.toDouble() - value).abs() < 1e-9,
      )) {
        return false;
      }
    } else if (!allowed.contains(entry.value)) {
      return false;
    }
  }
  return true;
}

String _toolContext(Map<String, dynamic> record) {
  final results = <PromptToolResult>[];
  for (final raw in (record['tool_results'] as List? ?? const [])) {
    final result = raw as Map<String, dynamic>;
    results.add(
      PromptToolResult(
        toolName: result['tool_name'] as String,
        success: result['success'] as bool? ?? false,
        text:
            (result['model_result'] as String?) ??
            (result['result'] as String? ?? ''),
      ),
    );
  }
  return formatToolResultsForPrompt(results);
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

List<Map<String, String>> _exportMessages(List<ChatMessage> messages) {
  return [
    for (final message in messages)
      {'role': message.role, 'content': message.content},
  ];
}
