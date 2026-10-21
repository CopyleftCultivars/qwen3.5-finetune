import 'dart:convert';

import 'recipe_prompt.dart';

/// Pure builders for the recipe form (#20).
///
/// The form deliberately makes no model tool decision. It validates names with
/// [RecipeToolService.resolvePlant]/[RecipeToolService.resolveCrop], builds the
/// canonical `trigger_recipe_v1` user text, and synthesizes the exact
/// `<tool_call>` assistant turn the trained model emits for that trigger. The
/// only model call in QUICK mode is the instruction pass over
/// `[system, user, assistant tool call, tool served view]`.
///
/// This file stays free of Flutter imports so
/// `tool/export_recipe_form_messages.dart` can export the real form bytes.

/// Render the area as the trigger template does: no redundant decimal point.
String formatRecipeArea(double quantity) {
  if (quantity == quantity.truncateToDouble()) {
    return quantity.toInt().toString();
  }
  final text = quantity.toString();
  if (text.contains('e') || text.contains('E')) {
    // The trigger parser accepts plain decimals, not scientific notation.
    return quantity
        .toStringAsFixed(20)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// The canonical trigger text for a fully resolved form.
String buildRecipeTriggerText({
  required String candidatePlant,
  required String crop,
  required double quantity,
}) {
  return 'Bioaccumulator recipe: ${candidatePlant.trim()} for my '
      '${crop.trim()}, ${formatRecipeArea(quantity)} m2';
}

/// The exact `<tool_call>` text the trained model emits for [trigger].
///
/// Key order, spacing and number formatting are the `targeted_v5` call-target
/// bytes: `candidate_plant`, `crop`, `quantity`, `unit`, with whole-number
/// quantities written with one decimal place (`2.0`).
String buildRecipeToolCallResponse({
  required String candidatePlant,
  required String crop,
  required double quantity,
}) {
  // jsonEncode gives the corpus's number formatting (`2.0`, `2.5`) but compact
  // separators; the trained call targets use a space after `:` and `,`.
  final plantJson = jsonEncode(candidatePlant.trim());
  final cropJson = jsonEncode(crop.trim());
  final quantityJson = jsonEncode(quantity);
  return '<tool_call>\n'
      '{"name": "$recipeToolName", "arguments": {'
      '"candidate_plant": $plantJson, '
      '"crop": $cropJson, '
      '"quantity": $quantityJson, '
      '"unit": "m2"}}\n'
      '</tool_call>';
}

/// Stable ordering for the tool's own plant suggestions.
///
/// A location never changes resolution: it only moves suggestions whose common
/// or scientific name is listed for that region ahead of the rest.
List<String> rankPlantSuggestionsByLocation(
  Iterable<String> suggestions,
  Set<String> regionalNames,
) {
  if (regionalNames.isEmpty) return List<String>.from(suggestions);
  final regional = <String>[];
  final rest = <String>[];
  for (final suggestion in suggestions) {
    final lowered = suggestion.toLowerCase();
    final base = lowered.split(' (').first;
    final inRegion =
        regionalNames.contains(lowered) ||
        regionalNames.contains(base) ||
        regionalNames.any(
          (name) => lowered.contains(name) || base.contains(name),
        );
    (inRegion ? regional : rest).add(suggestion);
  }
  return [...regional, ...rest];
}

/// One-line deterministic DETAILED summary of a full recipe-tool result.
///
/// This is the #19 card summary, reused by the chat and the recipe form so the
/// fallback reply and the card agree.
String buildDeterministicRecipeSummary(Map<String, dynamic> result) {
  if (result['status'] != 'ok') {
    final error = (result['error'] as Map<String, dynamic>?) ?? const {};
    return 'Recipe tool error (${error['code']}): ${error['message']}';
  }
  final candidate = result['candidate_plant'] as Map<String, dynamic>;
  final crop = result['crop'] as Map<String, dynamic>;
  final input = result['input'] as Map<String, dynamic>;
  final nutrition = result['nutrition_track'] as Map<String, dynamic>;
  final nutrients = nutrition['nutrients'] as Map<String, dynamic>;
  final coverageText = ['N', 'P', 'K']
      .where((nutrient) => nutrients[nutrient]['coverage_percent'] != null)
      .map(
        (nutrient) =>
            '$nutrient ${(nutrients[nutrient]['coverage_percent'] as num).toDouble().toStringAsFixed(1)}%',
      )
      .join(', ');
  final recipes =
      ((result['booster_track'] as Map<String, dynamic>)['recipes'] as List)
          .cast<Map<String, dynamic>>();
  final booster = recipes
      .where((recipe) => recipe['computable'] == true)
      .map((recipe) => '${recipe['recipe_abbrev']} (${recipe['recipe_name']})')
      .join(', ');
  return 'Bioaccumulator recipe for ${candidate['common_name']} on '
      '${crop['common_name']}, ${input['quantity']} m2.\n'
      'Nutrition (no overshoot): ${nutrition['sizing_nutrient']} sizing, '
      '${nutrition['sizing_fresh_plant_material_kg']} kg fresh material '
      '(${nutrition['sizing_fresh_plant_material_kg_per_m2']} kg/m2). '
      'Coverage: $coverageText.\n'
      'Booster: ${booster.isEmpty ? 'no standard batch is computable' : booster}.';
}

/// How the form's live pre-submit calculation ended.
enum RecipeFormStatus {
  incomplete,
  unknownCrop,
  unknownPlant,
  ambiguousPlant,
  invalidArea,
  toolError,
  ok,
}

/// The result of validating the form and running the deterministic tool.
class RecipeFormEvaluation {
  final RecipeFormStatus status;

  /// The full `recipe-tool-result-v2` when both names and the area resolved.
  final Map<String, dynamic>? result;

  /// The tool's own ambiguity suggestions, ordered by the optional location.
  final List<String> plantSuggestions;

  /// How many of [plantSuggestions] are listed for the optional location.
  final int regionalSuggestionCount;

  const RecipeFormEvaluation({
    required this.status,
    this.result,
    this.plantSuggestions = const <String>[],
    this.regionalSuggestionCount = 0,
  });

  bool get needsResolvedNames =>
      status == RecipeFormStatus.unknownCrop ||
      status == RecipeFormStatus.unknownPlant ||
      status == RecipeFormStatus.ambiguousPlant;

  /// A resolved pair may still hit a deterministic tool error (for example a
  /// candidate that is not offered for any recipe). That is a valid submission:
  /// the form shows the error as the chat reply and the card shows its details.
  bool get canSubmit =>
      status == RecipeFormStatus.ok || status == RecipeFormStatus.toolError;

  Map<String, dynamic>? get error {
    final value = result?['error'];
    return value is Map<String, dynamic> ? value : null;
  }

  String? get errorCode => error?['code']?.toString();

  String? get errorMessage => error?['message']?.toString();

  List<Map<String, dynamic>> get boosterRecipes {
    final booster = result?['booster_track'];
    if (booster is! Map<String, dynamic>) return const <Map<String, dynamic>>[];
    final recipes = booster['recipes'];
    if (recipes is! List) return const <Map<String, dynamic>>[];
    return recipes.cast<Map<String, dynamic>>();
  }

  List<Map<String, dynamic>> get computableRecipes => [
    for (final recipe in boosterRecipes)
      if (recipe['computable'] == true) recipe,
  ];

  List<String> get nonComputableRecipeAbbrevs => [
    for (final recipe in boosterRecipes)
      if (recipe['computable'] != true) '${recipe['recipe_abbrev']}',
  ];

  bool get computable =>
      status == RecipeFormStatus.ok && computableRecipes.isNotEmpty;

  /// One-line pre-submit status using the tool's own error code and message.
  String get summary {
    switch (status) {
      case RecipeFormStatus.incomplete:
        return 'Fill the crop, candidate plant and area to calculate.';
      case RecipeFormStatus.unknownCrop:
        return 'Unknown crop: the crop catalog has no match.';
      case RecipeFormStatus.unknownPlant:
        return 'Unknown candidate plant: the plant catalog has no match.';
      case RecipeFormStatus.ambiguousPlant:
        return 'Ambiguous candidate plant: choose one of the suggestions.';
      case RecipeFormStatus.invalidArea:
        return 'Area must be a positive number of square metres.';
      case RecipeFormStatus.toolError:
        return 'Tool error $errorCode: $errorMessage';
      case RecipeFormStatus.ok:
        if (computableRecipes.isNotEmpty) {
          final abbreviations = computableRecipes
              .map((recipe) => '${recipe['recipe_abbrev']}')
              .join(', ');
          return 'Computable: $abbreviations standard batch'
              '${computableRecipes.length == 1 ? '' : 'es'}.';
        }
        if (nonComputableRecipeAbbrevs.isNotEmpty) {
          return 'The tool returns a nutrition result, but no standard batch is '
              'computable (${nonComputableRecipeAbbrevs.join(', ')}).';
        }
        return 'The tool returns a result.';
    }
  }
}
