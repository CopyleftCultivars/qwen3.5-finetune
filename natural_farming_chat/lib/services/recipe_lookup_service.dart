import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'region_plant_service.dart';

/// Combined region + recipe lookup: does a crop grow in a named region (or
/// vice versa), and does a nutrient-deficiency phrase or crop/plant name
/// match a KNF/JADAM recipe.
///
/// On-device Dart port of `rlm_slice/domain_tools.py`'s
/// `regional_recipe_lookup` (chainlink #174/#177, minus the GPU-only QMD
/// collection lookup, which has no on-device equivalent here). Region data
/// reuses the already-bundled [RegionPlantService]; recipe data is backed by
/// a new asset, `Enriched_Recipes.json` (copied from the GPU repo's
/// `enriched_recipes.json`) -- deliberately NOT the older, bundled
/// `NF_Recipes.json`, which lacks `primary_nutrient`/
/// `suggested_bioaccumulators` and is still validated by
/// `DataValidator.validateRecipeEntries` against its own simpler schema.
class RecipeLookupService {
  final RegionPlantService _regionPlantService;

  List<Map<String, dynamic>> _recipes = [];
  bool _isInitialized = false;

  static const String _assetPath = 'assets/plant_data/Enriched_Recipes.json';

  static const Map<String, String> _problemNutrientHints = {
    'nitrogen': 'N',
    'n deficiency': 'N',
    'phosphorus': 'P',
    'p deficiency': 'P',
    'potassium': 'K',
    'k deficiency': 'K',
  };

  RecipeLookupService({required RegionPlantService regionPlantService})
      : _regionPlantService = regionPlantService;

  bool get isInitialized => _isInitialized;
  int get recipeCount => _recipes.length;

  /// Load KNF/JADAM recipes from the bundled JSON asset.
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_isInitialized) return;

    onProgress?.call(0.0, 'Loading enriched recipe database...');

    final jsonString = await rootBundle.loadString(_assetPath);
    final List<dynamic> rows = jsonDecode(jsonString);
    _recipes = rows.cast<Map<String, dynamic>>();

    _isInitialized = true;
    onProgress?.call(1.0, 'Recipe database ready (${_recipes.length} recipes)');
  }

  /// At least one of `crop`, `region`, `problem` must be given. Mirrors
  /// `regional_recipe_lookup()` in domain_tools.py (minus the QMD lookup):
  /// region matching + reverse crop-region matching via
  /// [RegionPlantService], plus token-overlap recipe scoring against
  /// `recipe_name`/`suggested_bioaccumulators`/`ingredients`, with a +2
  /// bonus when a nutrient-deficiency phrase in `problem` matches the
  /// recipe's `primary_nutrient`.
  RegionalRecipeLookupResult lookup({String? crop, String? region, String? problem}) {
    final cropTrim = (crop ?? '').trim();
    final regionTrim = (region ?? '').trim();
    final problemTrim = (problem ?? '').trim();

    if (cropTrim.isEmpty && regionTrim.isEmpty && problemTrim.isEmpty) {
      return RegionalRecipeLookupResult.error(
        'at least one of crop, region, or problem is required',
      );
    }

    if (!_isInitialized) {
      return RegionalRecipeLookupResult.error('Recipe database not initialized');
    }

    final regionMatches =
        regionTrim.isNotEmpty ? _regionPlantService.findRegions(regionTrim) : <RegionEntry>[];
    final regionsGrowingCrop =
        cropTrim.isNotEmpty ? _regionPlantService.regionsGrowingCrop(cropTrim) : <String>[];

    // Whole-string substring terms, matching the Python's `query_terms`
    // (crop/problem strings themselves, not tokenized words).
    final queryTerms = <String>{
      if (cropTrim.isNotEmpty) cropTrim.toLowerCase(),
      if (problemTrim.isNotEmpty) problemTrim.toLowerCase(),
    };

    String? hintedNutrient;
    if (problemTrim.isNotEmpty) {
      final problemL = problemTrim.toLowerCase();
      for (final entry in _problemNutrientHints.entries) {
        if (problemL.contains(entry.key)) {
          hintedNutrient = entry.value;
          break;
        }
      }
    }

    final scored = <MapEntry<int, Map<String, dynamic>>>[];
    for (final recipe in _recipes) {
      var score = _tokenOverlapScore(queryTerms, [
        (recipe['recipe_name'] as String?) ?? '',
        (((recipe['suggested_bioaccumulators'] as List?) ?? const []).cast<String>()).join(' '),
        (((recipe['ingredients'] as List?) ?? const []).cast<String>()).join(' '),
      ]);
      if (hintedNutrient != null && recipe['primary_nutrient'] == hintedNutrient) {
        score += 2;
      }
      if (score > 0) scored.add(MapEntry(score, recipe));
    }
    scored.sort((a, b) => b.key.compareTo(a.key));
    final matchingRecipes = scored.take(5).map((e) => e.value).toList();

    return RegionalRecipeLookupResult(
      success: true,
      regionMatches: regionMatches,
      regionsGrowingCrop: regionsGrowingCrop,
      matchingRecipes: matchingRecipes,
    );
  }

  int _tokenOverlapScore(Set<String> queryTerms, List<String> texts) {
    final blob = texts.join(' ').toLowerCase();
    var count = 0;
    for (final term in queryTerms) {
      if (term.isNotEmpty && blob.contains(term)) count++;
    }
    return count;
  }
}

/// Result of a combined regional/recipe lookup.
class RegionalRecipeLookupResult {
  final bool success;
  final List<RegionEntry> regionMatches;
  final List<String> regionsGrowingCrop;
  final List<Map<String, dynamic>> matchingRecipes;
  final String? errorMessage;

  RegionalRecipeLookupResult({
    required this.success,
    this.regionMatches = const [],
    this.regionsGrowingCrop = const [],
    this.matchingRecipes = const [],
    this.errorMessage,
  });

  factory RegionalRecipeLookupResult.error(String message) => RegionalRecipeLookupResult(
        success: false,
        errorMessage: message,
      );

  /// Format for inclusion in the tool-result prompt / ToolExecutor's
  /// ToolResult.result.
  String toMessage() {
    if (!success) return errorMessage ?? 'Unknown error';

    final buffer = StringBuffer();

    if (regionMatches.isNotEmpty) {
      buffer.writeln('Regions matching query:');
      for (final r in regionMatches) {
        final plantNames = r.plants.map((p) => p.commonName).take(8).join(', ');
        buffer.writeln('  ${r.displayName}: $plantNames');
      }
    }

    if (regionsGrowingCrop.isNotEmpty) {
      buffer.writeln('Regions where this crop grows: ${regionsGrowingCrop.join(", ")}');
    }

    if (matchingRecipes.isNotEmpty) {
      buffer.writeln('Matching KNF/JADAM recipes:');
      for (final r in matchingRecipes) {
        final name = r['recipe_name'] ?? r['recipe_abbrev'] ?? 'unnamed recipe';
        final nutrient = r['primary_nutrient'];
        final bioaccumulators = ((r['suggested_bioaccumulators'] as List?) ?? const []).join(', ');
        final dilution = r['dilution_ratio'];
        buffer.writeln('  $name (primary nutrient: $nutrient)');
        if (bioaccumulators.isNotEmpty) {
          buffer.writeln('    suggested bioaccumulators: $bioaccumulators');
        }
        if (dilution != null) {
          buffer.writeln('    dilution: $dilution');
        }
      }
    }

    if (regionMatches.isEmpty && regionsGrowingCrop.isEmpty && matchingRecipes.isEmpty) {
      buffer.writeln('No region or recipe matches found for the given query.');
    }

    return buffer.toString().trimRight();
  }
}
