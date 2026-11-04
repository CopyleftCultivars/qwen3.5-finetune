// Replays the Python goldens (scripts/generate_routed_history_goldens.py) against the Dart port.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/models/chat_session.dart';
import 'package:natural_farming_chat/services/recipe_tool_service.dart';
import 'package:natural_farming_chat/services/routed_history.dart';

Map<String, dynamic> loadGoldens() => jsonDecode(
      File('test/fixtures/routed_history_goldens.json').readAsStringSync(),
    ) as Map<String, dynamic>;

List<ChatMessage> messagesOf(List<dynamic> raw) => [
      for (final item in raw)
        ChatMessage(
          content: (item as Map)['content'] as String,
          isUser: item['isUser'] as bool,
          recipe: item['recipe'] == null
              ? null
              : Map<String, dynamic>.from(item['recipe'] as Map),
        ),
    ];

/// The recipe held in a golden message is already a served view.
Map<String, dynamic> identityView(Map<String, dynamic> recipe) => recipe;

final RecipeToolService parser = RecipeToolService();

String? triggerCode(String text) {
  try {
    parser.parseTrigger(text);
  } on RecipeTriggerException catch (error) {
    return error.code;
  }
  return null;
}

List<Map<String, String>> plain(List<dynamic> history) => [
      for (final m in history)
        {'role': (m as dynamic).role as String, 'content': m.content as String},
    ];

List<Map<String, String>> expectedOf(List<dynamic> raw) => [
      for (final m in raw)
        {
          'role': (m as Map)['role'] as String,
          'content': m['content'] as String,
        },
    ];

void main() {
  final goldens = loadGoldens();

  test('formatG matches Python %g', () {
    for (final raw in goldens['format_g'] as List) {
      final row = raw as Map<String, dynamic>;
      expect(formatG((row['value'] as num).toDouble()), row['text'],
          reason: 'value ${row['value']}');
    }
  });

  test('ledger messages match context_ledger v1.1', () {
    for (final raw in goldens['ledger_cases'] as List) {
      final row = raw as Map<String, dynamic>;
      final ledger = buildLedger(messagesOf(row['messages'] as List), identityView);
      expect(plain(renderLedgerMessages(ledger)), expectedOf(row['expected'] as List),
          reason: row['name'] as String);
    }
  });

  test('routing matches the Python reference', () {
    for (final raw in goldens['route_cases'] as List) {
      final row = raw as Map<String, dynamic>;
      final routed = routeTurn(
        messages: messagesOf(row['messages'] as List),
        text: row['text'] as String,
        servedView: identityView,
        triggerCode: triggerCode,
      );
      final name = row['name'] as String;
      expect(routed.route, row['expected_route'], reason: name);
      expect(routed.question, row['expected_question'], reason: name);
      expect(plain(routed.history), expectedOf(row['expected_history'] as List), reason: name);
    }
  });

  test('followup fill matches followup_fill_v1', () {
    for (final raw in goldens['fill_cases'] as List) {
      final row = raw as Map<String, dynamic>;
      final message = followupFill(
        previousUser: row['previous'] as String?,
        previousEndedWithoutRecipe: row['ended'] as bool,
        text: row['text'] as String,
        triggerCode: triggerCode,
      );
      expect(message != null, row['filled'], reason: jsonEncode(row));
      if (message != null) expect(message, row['message'], reason: jsonEncode(row));
    }
  });

  test('audit never carries message text', () {
    final routed = routeTurn(
      messages: messagesOf([
        {'content': 'a private note', 'isUser': true},
        {'content': 'reply', 'isUser': false},
      ]),
      text: 'another message',
      servedView: identityView,
      triggerCode: triggerCode,
    );
    expect(routed.route, 'ledger');
    expect(routed.audit, {'ledger_entries': 0, 'notes': 1});
  });
}
