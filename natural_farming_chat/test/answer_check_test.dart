// Replays the Python goldens (scripts/generate_answer_check_goldens.py) against the Dart answer check.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/answer_check.dart';

void main() {
  final goldens = jsonDecode(File('test/fixtures/answer_check_goldens.json').readAsStringSync()) as Map<String, dynamic>;
  final views = (goldens['served_views'] as Map).cast<String, dynamic>();
  final cases = (goldens['cases'] as List).cast<Map<String, dynamic>>();

  test('the golden file covers every finding kind, a repair and an error result', () {
    final kinds = <String>{
      for (final c in cases) for (final f in (c['check']['findings'] as List)) f['kind'] as String,
    };
    expect(kinds, {'volume_mismatch', 'volume_missing', 'amount_missing', 'assumption_missing'});
    expect(cases.any((c) => (c['repair'] as Map)['changed'] == true), isTrue);
    expect(cases.any((c) => (c['check'] as Map).containsKey('skipped')), isTrue);
    expect(cases.length, greaterThan(150));
  });

  test('every golden case: report and repair match the Python reference', () {
    for (final c in cases) {
      final served = Map<String, dynamic>.from(views[c['result']] as Map);
      final answer = c['answer'] as String;
      final report = checkAnswer(answer, served);
      expect(jsonEncode(_sorted(report)), jsonEncode(_sorted(c['check'])), reason: '${c['name']}: check');
      final fixed = repairAnswer(answer, served);
      final expected = c['repair'] as Map<String, dynamic>;
      for (final key in ['answer', 'changed', 'unit_fixes', 'appended']) {
        expect(jsonEncode(_sorted(fixed[key])), jsonEncode(_sorted(expected[key])), reason: '${c['name']}: repair.$key');
      }
    }
  });

  test('the fixed messages name kinds and never a value', () {
    for (final message in findingMessages.values) {
      expect(RegExp(r'\d').hasMatch(message), isFalse, reason: message);
    }
  });

  test('repair is idempotent on every golden answer', () {
    for (final c in cases) {
      final served = Map<String, dynamic>.from(views[c['result']] as Map);
      final once = repairAnswer(c['answer'] as String, served)['answer'] as String;
      expect(repairAnswer(once, served)['answer'], once, reason: c['name'] as String);
    }
  });

  test('findingKinds lists kinds once, in order, without text', () {
    final served = Map<String, dynamic>.from(views.values.first as Map);
    expect(findingKinds(checkAnswer('nothing', served)), 'amount_missing,volume_missing,assumption_missing');
    expect(findingKinds({'findings': <dynamic>[]}), 'none');
  });
}

dynamic _sorted(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return [for (final v in value) _sorted(v)];
  return value;
}
