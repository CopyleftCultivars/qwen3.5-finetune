import 'recipe_form.dart';
import 'recipe_tool_service.dart';

/// Validate a recipe-form name with the tool's own resolver.
///
/// Returns the catalog row for exactly the names the tool accepts. Ambiguous
/// and unknown names never reach [RecipeToolService.calculate].
Map<String, dynamic>? resolveRecipeFormCrop(
  RecipeToolService service,
  String query,
) {
  return service.resolveCrop(query.trim());
}

/// The tool's own candidate-plant resolution, including its suggestions.
({Map<String, dynamic>? plant, List<String> suggestions})
resolveRecipeFormPlant(RecipeToolService service, String query) {
  return service.resolvePlant(query.trim());
}

/// Run the live, entirely deterministic pre-submit calculation.
///
/// This makes no model call: it uses the same [RecipeToolService] the chat
/// tool executes, so the status shown before submit is the result the submitted
/// trigger will produce.
RecipeFormEvaluation evaluateRecipeForm({
  required RecipeToolService service,
  required String candidatePlant,
  required String crop,
  required String areaText,
  Set<String> regionalPlantNames = const <String>{},
}) {
  final plantText = candidatePlant.trim();
  final cropText = crop.trim();
  final areaValue = double.tryParse(areaText.trim());

  if (plantText.isEmpty || cropText.isEmpty || areaText.trim().isEmpty) {
    return const RecipeFormEvaluation(status: RecipeFormStatus.incomplete);
  }

  if (resolveRecipeFormCrop(service, cropText) == null) {
    return const RecipeFormEvaluation(status: RecipeFormStatus.unknownCrop);
  }

  final plantResolution = resolveRecipeFormPlant(service, plantText);
  if (plantResolution.plant == null) {
    final suggestions = rankPlantSuggestionsByLocation(
      plantResolution.suggestions,
      regionalPlantNames,
    );
    return RecipeFormEvaluation(
      status: suggestions.isEmpty
          ? RecipeFormStatus.unknownPlant
          : RecipeFormStatus.ambiguousPlant,
      plantSuggestions: suggestions,
      regionalSuggestionCount: _regionalCount(suggestions, regionalPlantNames),
    );
  }

  if (areaValue == null || !areaValue.isFinite || areaValue <= 0) {
    return const RecipeFormEvaluation(status: RecipeFormStatus.invalidArea);
  }

  final result = service.calculate({
    'candidate_plant': plantText,
    'crop': cropText,
    'quantity': areaValue,
    'unit': 'm2',
  });
  return RecipeFormEvaluation(
    status: result['status'] == 'ok'
        ? RecipeFormStatus.ok
        : RecipeFormStatus.toolError,
    result: result,
  );
}

int _regionalCount(List<String> suggestions, Set<String> regionalNames) {
  if (regionalNames.isEmpty) return 0;
  return suggestions.where((suggestion) {
    final lowered = suggestion.toLowerCase();
    final base = lowered.split(' (').first;
    return regionalNames.contains(lowered) ||
        regionalNames.contains(base) ||
        regionalNames.any(
          (name) => lowered.contains(name) || base.contains(name),
        );
  }).length;
}
