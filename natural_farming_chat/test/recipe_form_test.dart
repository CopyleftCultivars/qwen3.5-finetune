import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/recipe_form.dart';
import 'package:natural_farming_chat/services/recipe_form_evaluator.dart';
import 'package:natural_farming_chat/services/recipe_tool_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecipeToolService service;

  setUpAll(() async {
    service = RecipeToolService();
    await service.initialize();
  });

  test('public resolvers return exactly what the tool accepts', () {
    final banana = service.resolvePlant('Banana');
    expect(banana.plant, isNotNull);
    expect(banana.plant!['common_name'], 'Banana');
    expect(banana.suggestions, isEmpty);

    final ambiguous = service.resolvePlant('Clover');
    expect(ambiguous.plant, isNull);
    expect(ambiguous.suggestions, containsAll(<String>['Clove', 'Red Clover']));

    final unknown = service.resolvePlant('Kumquat');
    expect(unknown.plant, isNull);
    expect(unknown.suggestions, isEmpty);

    final onion = service.resolveCrop('Onion');
    expect(onion, isNotNull);
    expect(onion!['Crop'], 'Onion');
    expect(service.resolveCrop('Kumquat'), isNull);
  });

  test('form builds the canonical trigger and trained tool-call bytes', () {
    expect(
      buildRecipeTriggerText(
        candidatePlant: 'Banana',
        crop: 'Onion',
        quantity: 2,
      ),
      'Bioaccumulator recipe: Banana for my Onion, 2 m2',
    );
    expect(
      buildRecipeToolCallResponse(
        candidatePlant: 'Banana',
        crop: 'Onion',
        quantity: 2,
      ),
      '<tool_call>\n'
      '{"name": "bioaccumulator_recipe", "arguments": '
      '{"candidate_plant": "Banana", "crop": "Onion", '
      '"quantity": 2.0, "unit": "m2"}}\n'
      '</tool_call>',
    );
  });

  test('live evaluation is deterministic and reports the tool error', () {
    final ok = evaluateRecipeForm(
      service: service,
      candidatePlant: 'Banana',
      crop: 'Onion',
      areaText: '2',
    );
    expect(ok.status, RecipeFormStatus.ok);
    expect(ok.result!['status'], 'ok');
    expect(ok.computable, isTrue);
    expect(ok.summary, contains('Computable'));

    final notOffered = evaluateRecipeForm(
      service: service,
      candidatePlant: 'Okra',
      crop: 'Snap Peas',
      areaText: '25',
    );
    expect(notOffered.status, RecipeFormStatus.toolError);
    expect(notOffered.errorCode, 'candidate_not_offered_for_recipe');
    expect(notOffered.summary, contains('candidate_not_offered_for_recipe'));

    final ambiguous = evaluateRecipeForm(
      service: service,
      candidatePlant: 'Clover',
      crop: 'Kale',
      areaText: '25',
    );
    expect(ambiguous.status, RecipeFormStatus.ambiguousPlant);
    expect(ambiguous.canSubmit, isFalse);
    expect(ambiguous.plantSuggestions, isNotEmpty);

    final invalidArea = evaluateRecipeForm(
      service: service,
      candidatePlant: 'Banana',
      crop: 'Onion',
      areaText: '0',
    );
    expect(invalidArea.status, RecipeFormStatus.invalidArea);
    expect(invalidArea.canSubmit, isFalse);
  });

  test('location only ranks suggestions and is not a tool argument', () {
    expect(
      rankPlantSuggestionsByLocation(
        const ['Clove', 'Red Clover'],
        const {'red clover'},
      ),
      const ['Red Clover', 'Clove'],
    );
  });

  test(
    'form UI validates with the resolver and continues via the session API',
    () {
      final form = File('lib/widgets/recipe_form_tab.dart').readAsStringSync();
      expect(form, contains('resolvePlant'));
      expect(form, contains('resolveCrop'));
      expect(form, contains('evaluateRecipeForm'));
      expect(form, contains('Continue chat?'));
      expect(form, isNot(contains('generateCompletionWithTools')));

      // UI hint text must not carry example catalog values.
      for (final example in [
        'banana',
        'onion',
        'stinging nettle',
        '25 m2',
        'bioaccumulator recipe:',
      ]) {
        expect(form.toLowerCase(), isNot(contains(example)));
      }

      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('createSessionFromRecipe'));
      expect(main, contains('RecipeFormTab'));
      expect(main, contains('buildRecipeInstructionMessages'));
    },
  );
}
