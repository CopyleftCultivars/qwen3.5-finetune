import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cactus/cactus.dart' show ToolCall;
import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/calculator_service.dart';
import 'package:natural_farming_chat/services/fertilizer_formulation_service.dart';
import 'package:natural_farming_chat/services/plant_lookup_service.dart';
import 'package:natural_farming_chat/services/recipe_tool_service.dart';
import 'package:natural_farming_chat/services/region_plant_service.dart';
import 'package:natural_farming_chat/services/tool_executor.dart';

/// Golden-fixture conformance: every `bioaccumulator_recipe` tool call in the
/// bioaccumulator v3 development and validation scenarios must match the
/// reference MCP server's full result and compact served view.
///
/// The test split is deliberately absent: the fixture generator only reads
/// `development.jsonl` and `validation.jsonl`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecipeToolService service;

  setUpAll(() async {
    service = RecipeToolService();
    await service.initialize();
  });

  for (final split in const ['development', 'validation']) {
    group(split, () {
      final calls = _readJsonl('test/fixtures/recipe_tool_v3/$split.jsonl');

      test('${calls.length} recipe tool calls match the oracle', () {
        for (final fixture in calls) {
          final arguments = fixture['arguments'] as Map<String, dynamic>;
          final actual = service.calculate(arguments);
          expect(
            _differences(actual, fixture['expected']),
            isEmpty,
            reason: '${fixture['case_id']} turn ${fixture['turn']}',
          );
          final served = service.servedView(actual);
          expect(
            _differences(served, fixture['expected_served']),
            isEmpty,
            reason: '${fixture['case_id']} turn ${fixture['turn']} served view',
          );
        }
      });

      test('served-view bytes match the MCP server', () {
        for (final fixture in calls) {
          final actual = service.calculate(
            fixture['arguments'] as Map<String, dynamic>,
          );
          final servedText = canonicalJson(service.servedView(actual));
          expect(
            servedText,
            fixture['expected_served_text'],
            reason: '${fixture['case_id']} turn ${fixture['turn']}',
          );
        }
      });

      test('full-result canonical bytes match the oracle', () {
        for (final fixture in calls) {
          final actual = service.calculate(
            fixture['arguments'] as Map<String, dynamic>,
          );
          expect(
            canonicalJson(actual),
            canonicalJson(fixture['expected']),
            reason: '${fixture['case_id']} turn ${fixture['turn']}',
          );
        }
      });
    });
  }

  test(
    'tool executor dispatches the recipe tool with Cactus string arguments',
    () async {
      final plantLookup = PlantLookupService();
      final executor = ToolExecutor(
        plantLookupService: plantLookup,
        calculatorService: CalculatorService(),
        formulationService: FertilizerFormulationService(
          regionService: RegionPlantService(),
          plantLookupService: plantLookup,
        ),
        recipeToolService: service,
      );
      final arguments = <String, String>{
        'candidate_plant': 'Stinging Nettle',
        'crop': 'Tomato',
        'quantity': '25',
        'unit': 'm2',
      };
      final result = await executor.execute(
        ToolCall(name: 'bioaccumulator_recipe', arguments: arguments),
      );

      final full = service.calculate({
        'candidate_plant': 'Stinging Nettle',
        'crop': 'Tomato',
        'quantity': 25,
        'unit': 'm2',
      });
      expect(result.success, isTrue);
      expect(result.result, canonicalJson(service.servedView(full)));
      expect(canonicalJson(result.data), canonicalJson(full));
    },
  );
}

List<Map<String, dynamic>> _readJsonl(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      'missing fixture $path; run tool/generate_recipe_tool_goldens.py',
    );
  }
  return file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
}

/// Recursive comparison. Numbers use the port spec's 1e-6 relative tolerance;
/// every string, boolean, null and list ordering must be exact.
List<String> _differences(
  dynamic actual,
  dynamic expected, [
  String path = r'$',
]) {
  final problems = <String>[];
  if (actual is num && expected is num) {
    final tolerance =
        1e-6 * math.max(1.0, math.max(actual.abs(), expected.abs()));
    if ((actual.toDouble() - expected.toDouble()).abs() > tolerance) {
      problems.add('$path: $actual != $expected');
    }
    return problems;
  }
  if (actual is Map && expected is Map) {
    final actualKeys = actual.keys.map((key) => key.toString()).toSet();
    final expectedKeys = expected.keys.map((key) => key.toString()).toSet();
    for (final key in expectedKeys.difference(actualKeys)) {
      problems.add('$path.$key: missing');
    }
    for (final key in actualKeys.difference(expectedKeys)) {
      problems.add('$path.$key: unexpected');
    }
    for (final key in actualKeys.intersection(expectedKeys)) {
      problems.addAll(_differences(actual[key], expected[key], '$path.$key'));
    }
    return problems;
  }
  if (actual is List && expected is List) {
    if (actual.length != expected.length) {
      problems.add('$path: list length ${actual.length} != ${expected.length}');
      return problems;
    }
    for (var i = 0; i < actual.length; i++) {
      problems.addAll(_differences(actual[i], expected[i], '$path[$i]'));
    }
    return problems;
  }
  if (actual != expected) {
    problems.add('$path: $actual != $expected');
  }
  return problems;
}
