import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/model_service.dart';
import 'package:natural_farming_chat/services/recipe_prompt.dart';
import 'package:natural_farming_chat/services/recipe_tool_service.dart';

/// Proves the app sends the benchmark runner's `trigger_recipe_v1` bytes.
void main() {
  final parity =
      jsonDecode(
            File(
              'test/fixtures/recipe_tool_v3/prompt_parity.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('system prompt is byte-identical to the runner', () {
    expect(recipeSystemPrompt, parity['system_prompt']);
    expect(
      sha256.convert(utf8.encode(recipeSystemPrompt)).toString(),
      parity['system_prompt_sha256'],
    );
    expect(
      parity['system_prompt_sha256'],
      '9da18292abc6eacc36f86ce88bf9b23b1e5e4731d7cb10c5c76d00d30143fe69',
    );
  });

  test('six-tool prompt is byte-identical to the runner', () {
    final tools = ModelService.farmingTools;
    expect(tools.map((tool) => tool.name).toList(), [
      'npk_lookup',
      'calculate',
      'local_fertilizer_plants',
      'bioaccumulator_ratio',
      'regional_recipe_lookup',
      'bioaccumulator_recipe',
    ]);
    expect(serializeCactusTools(tools), parity['tool_prompt']);
    expect(
      sha256.convert(utf8.encode(serializeCactusTools(tools))).toString(),
      parity['tool_prompt_sha256'],
    );
    expect(
      parity['tool_prompt_sha256'],
      '216c4e45ce4cf59bac354f3ae85cb039a46870fdce4f3eafbeaf79e91676373d',
    );
  });

  test('tool schema JSON is byte-identical to the runner', () {
    final schema = serializeToolSchemaJson(ModelService.farmingTools);
    expect(schema, parity['tool_schema_json']);
    expect(
      sha256.convert(utf8.encode(schema)).toString(),
      parity['tool_schema_sha256'],
    );
    expect(
      parity['tool_schema_sha256'],
      'cd6e6b850f5160a6ff2e04dc8fd5a68003ed5d5949fc4bb7a69d84d15bbff0c0',
    );
  });

  test('served tool descriptions name no example entity or value', () {
    final text = serializeCactusTools(ModelService.farmingTools).toLowerCase();
    for (final example in [
      'stinging nettle',
      'tomato',
      '25 m2',
      '25 m²',
      'bioaccumulator recipe:',
    ]) {
      expect(
        text,
        isNot(contains(example)),
        reason: 'example leaked: $example',
      );
    }
  });

  test(
    'trigger parser matches the oracle on every development/validation turn',
    () {
      final service = RecipeToolService();
      // The parser itself does not need the data files.
      for (final split in const ['development', 'validation']) {
        final lines = File(
          'test/fixtures/recipe_tool_v3/${split}_triggers.jsonl',
        ).readAsLinesSync().where((line) => line.trim().isNotEmpty);
        for (final line in lines) {
          final fixture = jsonDecode(line) as Map<String, dynamic>;
          final user = fixture['user'] as String;
          final expectedError =
              fixture['expected_error'] as Map<String, dynamic>?;
          if (expectedError != null) {
            try {
              service.parseTrigger(user);
              fail(
                '${fixture['case_id']} turn ${fixture['turn']} should not parse',
              );
            } on RecipeTriggerException catch (error) {
              expect(error.code, expectedError['code']);
              expect(error.message, expectedError['message']);
            }
          } else {
            final expected =
                fixture['expected_arguments'] as Map<String, dynamic>;
            final actual = service.parseTrigger(user).toArguments();
            expect(actual['candidate_plant'], expected['candidate_plant']);
            expect(actual['crop'], expected['crop']);
            expect(actual['quantity'], expected['quantity']);
            expect(actual['unit'], expected['unit']);
          }
        }
      }
    },
  );
}
