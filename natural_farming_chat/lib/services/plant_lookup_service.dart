import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'data_validator.dart';

/// Service for direct JSON-based plant mineral profile lookups.
/// Replaces RAG-based lookups which suffered from context truncation
/// due to varying mineral properties per plant.
class PlantLookupService {
  /// In-memory index: lowercase common name -> plant JSON object
  final Map<String, Map<String, dynamic>> _byCommonName = {};

  /// In-memory index: lowercase scientific name -> plant JSON object
  final Map<String, Map<String, dynamic>> _byScientificName = {};

  /// All plant names for fuzzy matching
  final List<String> _allCommonNames = [];

  bool _isInitialized = false;

  static const String _assetPath = 'assets/plant_data/plant_mineral_profiles.json';

  bool get isInitialized => _isInitialized;
  int get plantCount => _byCommonName.length;

  /// Access to scientific name index for cross-referencing by other services.
  Map<String, Map<String, dynamic>> get byScientificName => _byScientificName;

  /// Access to common name index for cross-referencing by other services
  /// (e.g. `BioaccumulatorRatioService`, which needs the raw per-part
  /// numeric mineral data, not `lookup()`'s pre-formatted display string).
  Map<String, Map<String, dynamic>> get byCommonName => _byCommonName;

  /// All known plant common + scientific names, for vocabulary-based
  /// argument extraction (`ToolArgExtractor`, chainlink #177's on-device
  /// ladder harness) -- mirrors `rlm_slice/multi_tool_context.py`'s
  /// `_plant_vocab()`.
  List<String> get allPlantNames => {
        ..._byCommonName.values.map((p) => p['common_name'] as String?),
        ..._byScientificName.values.map((p) => p['scientific_name'] as String?),
      }.whereType<String>().where((s) => s.trim().isNotEmpty).toList();

  /// Load plant mineral profiles from bundled JSON asset.
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_isInitialized) return;

    onProgress?.call(0.0, 'Loading plant mineral database...');

    final jsonString = await rootBundle.loadString(_assetPath);
    final List<dynamic> plants = jsonDecode(jsonString);

    onProgress?.call(0.3, 'Validating ${plants.length} plant profiles...');
    DataValidator.validatePlantProfiles(plants);

    onProgress?.call(0.5, 'Indexing ${plants.length} plants...');

    for (final plant in plants) {
      final map = plant as Map<String, dynamic>;
      final commonName = (map['common_name'] as String).toLowerCase();
      final scientificName = (map['scientific_name'] as String).toLowerCase();

      _byCommonName[commonName] = map;
      _byScientificName[scientificName] = map;
      _allCommonNames.add(map['common_name'] as String);
    }

    _isInitialized = true;
    onProgress?.call(1.0, 'Plant database ready (${plants.length} plants)');
    print('[PLANT_LOOKUP] Loaded ${plants.length} plants');
  }

  /// Look up a plant by name (common or scientific).
  /// Returns the full mineral profile as a formatted JSON string,
  /// or null if no match is found.
  PlantLookupResult lookup(String name) {
    if (!_isInitialized) {
      return PlantLookupResult(
        found: false,
        message: 'Plant database not initialized',
      );
    }

    final query = name.trim().toLowerCase();

    // Try exact match on common name
    var plant = _byCommonName[query];
    if (plant != null) {
      return PlantLookupResult(
        found: true,
        plantName: plant['common_name'] as String,
        message: _formatPlantProfile(plant),
      );
    }

    // Try exact match on scientific name
    plant = _byScientificName[query];
    if (plant != null) {
      return PlantLookupResult(
        found: true,
        plantName: plant['common_name'] as String,
        message: _formatPlantProfile(plant),
      );
    }

    // Try substring match on common names
    final substringMatches = _byCommonName.entries
        .where((e) => e.key.contains(query) || query.contains(e.key))
        .toList();

    if (substringMatches.length == 1) {
      final match = substringMatches.first.value;
      return PlantLookupResult(
        found: true,
        plantName: match['common_name'] as String,
        message: _formatPlantProfile(match),
      );
    }

    if (substringMatches.isNotEmpty) {
      final names = substringMatches
          .map((e) => e.value['common_name'] as String)
          .take(10)
          .toList();
      return PlantLookupResult(
        found: false,
        message: 'Multiple plants match "$name". Did you mean: ${names.join(", ")}?',
        suggestions: names,
      );
    }

    // Try substring match on scientific names
    final sciMatches = _byScientificName.entries
        .where((e) => e.key.contains(query) || query.contains(e.key))
        .toList();

    if (sciMatches.length == 1) {
      final match = sciMatches.first.value;
      return PlantLookupResult(
        found: true,
        plantName: match['common_name'] as String,
        message: _formatPlantProfile(match),
      );
    }

    if (sciMatches.isNotEmpty) {
      final names = sciMatches
          .map((e) => '${e.value['common_name']} (${e.value['scientific_name']})')
          .take(10)
          .toList();
      return PlantLookupResult(
        found: false,
        message: 'Multiple plants match "$name". Did you mean: ${names.join(", ")}?',
        suggestions: names,
      );
    }

    return PlantLookupResult(
      found: false,
      message: 'No plant found matching "$name". '
          'Try using the common name (e.g., "Tomato") or scientific name (e.g., "Solanum lycopersicum").',
    );
  }

  /// Format a plant profile as a readable string for the LLM to interpret.
  String _formatPlantProfile(Map<String, dynamic> plant) {
    final buffer = StringBuffer();
    final commonName = plant['common_name'] as String;
    final scientificName = plant['scientific_name'] as String;
    final parts = plant['parts'] as Map<String, dynamic>;

    buffer.writeln('Plant: $commonName ($scientificName)');
    buffer.writeln('Mineral Profile:');

    for (final partEntry in parts.entries) {
      final partName = partEntry.key;
      final partData = partEntry.value as Map<String, dynamic>;
      final minerals = partData['minerals'] as Map<String, dynamic>;

      buffer.writeln('  $partName:');
      for (final mineralEntry in minerals.entries) {
        final mineralName = mineralEntry.key;
        final mineralData = mineralEntry.value as Map<String, dynamic>;
        final unit = mineralData['unit'] as String;
        final min = mineralData['min'];
        final max = mineralData['max'];

        if (min != null && max != null) {
          buffer.writeln('    $mineralName: $min-$max $unit');
        } else if (max != null) {
          buffer.writeln('    $mineralName: up to $max $unit');
        } else if (min != null) {
          buffer.writeln('    $mineralName: $min+ $unit');
        }
      }
    }

    return buffer.toString().trimRight();
  }
}

/// Result from a plant lookup operation.
class PlantLookupResult {
  final bool found;
  final String? plantName;
  final String message;
  final List<String>? suggestions;

  PlantLookupResult({
    required this.found,
    this.plantName,
    required this.message,
    this.suggestions,
  });
}
