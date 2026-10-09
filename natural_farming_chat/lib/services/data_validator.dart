/// Runtime JSON schema validation for plant and region data files.
/// Validates structure at load time so corrupt data fails fast
/// rather than producing silent wrong results at query time.
class DataValidator {
  /// Validate a single plant mineral profile entry.
  /// Throws [DataValidationError] if the entry is malformed.
  static void validatePlantProfile(Map<String, dynamic> plant, int index) {
    _requireString(plant, 'scientific_name', 'plant[$index]');
    _requireString(plant, 'common_name', 'plant[$index]');

    final parts = plant['parts'];
    if (parts == null || parts is! Map<String, dynamic> || parts.isEmpty) {
      throw DataValidationError(
        'plant[$index] (${plant['scientific_name']}): '
        '"parts" must be a non-empty object',
      );
    }

    for (final partEntry in parts.entries) {
      final partName = partEntry.key;
      final partData = partEntry.value;
      final ctx = 'plant[$index].parts.$partName';

      if (partData is! Map<String, dynamic>) {
        throw DataValidationError('$ctx: must be an object');
      }

      final minerals = partData['minerals'];
      if (minerals == null || minerals is! Map<String, dynamic>) {
        throw DataValidationError('$ctx: "minerals" must be an object');
      }

      for (final mineralEntry in minerals.entries) {
        final mineralName = mineralEntry.key;
        final mineralData = mineralEntry.value;
        final mCtx = '$ctx.minerals.$mineralName';

        if (mineralData is! Map<String, dynamic>) {
          throw DataValidationError('$mCtx: must be an object');
        }

        _requireString(mineralData, 'unit', mCtx);

        final hasMin = mineralData.containsKey('min');
        final hasMax = mineralData.containsKey('max');
        if (!hasMin && !hasMax) {
          throw DataValidationError(
            '$mCtx: must have at least one of "min" or "max"',
          );
        }
        if (hasMin && mineralData['min'] is! num) {
          throw DataValidationError('$mCtx: "min" must be a number');
        }
        if (hasMax && mineralData['max'] is! num) {
          throw DataValidationError('$mCtx: "max" must be a number');
        }
      }
    }
  }

  /// Validate a single region entry from the region plants file.
  /// Throws [DataValidationError] if the entry is malformed.
  static void validateRegionEntry(Map<String, dynamic> entry, int index) {
    _requireString(entry, 'Country', 'region[$index]');

    // Region is optional (country-level entries don't have it)
    if (entry.containsKey('Region')) {
      if (entry['Region'] is! String || (entry['Region'] as String).isEmpty) {
        throw DataValidationError(
          'region[$index]: "Region" must be a non-empty string if present',
        );
      }
    }

    final plants = entry['Plants'];
    if (plants == null || plants is! List || plants.isEmpty) {
      throw DataValidationError(
        'region[$index] (${entry['Country']}): '
        '"Plants" must be a non-empty array',
      );
    }

    for (var i = 0; i < plants.length; i++) {
      if (plants[i] is! String || (plants[i] as String).isEmpty) {
        throw DataValidationError(
          'region[$index].Plants[$i]: must be a non-empty string',
        );
      }
    }
  }

  /// Validate a recipe entry from NF_Recipes.json.
  /// Throws [DataValidationError] if the entry is malformed.
  static void validateRecipeEntry(Map<String, dynamic> recipe, int index) {
    _requireString(recipe, 'Recipe', 'recipe[$index]');
    _requireStringList(recipe, 'Ingredients', 'recipe[$index]');
    _requireStringList(recipe, 'Steps', 'recipe[$index]');
    _requireStringList(recipe, 'Uses', 'recipe[$index]');
  }

  /// Validate an entire plant profiles array. Returns the count validated.
  static int validatePlantProfiles(List<dynamic> plants) {
    for (var i = 0; i < plants.length; i++) {
      if (plants[i] is! Map<String, dynamic>) {
        throw DataValidationError('plant[$i]: must be an object');
      }
      validatePlantProfile(plants[i] as Map<String, dynamic>, i);
    }
    return plants.length;
  }

  /// Validate an entire region array. Returns the count validated.
  static int validateRegionEntries(List<dynamic> entries) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] is! Map<String, dynamic>) {
        throw DataValidationError('region[$i]: must be an object');
      }
      validateRegionEntry(entries[i] as Map<String, dynamic>, i);
    }
    return entries.length;
  }

  /// Validate an entire recipe array. Returns the count validated.
  static int validateRecipeEntries(List<dynamic> entries) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] is! Map<String, dynamic>) {
        throw DataValidationError('recipe[$i]: must be an object');
      }
      validateRecipeEntry(entries[i] as Map<String, dynamic>, i);
    }
    return entries.length;
  }

  // --- Helpers ---

  static void _requireString(
    Map<String, dynamic> obj,
    String key,
    String context,
  ) {
    if (!obj.containsKey(key) ||
        obj[key] is! String ||
        (obj[key] as String).isEmpty) {
      throw DataValidationError(
        '$context: "$key" must be a non-empty string',
      );
    }
  }

  static void _requireStringList(
    Map<String, dynamic> obj,
    String key,
    String context,
  ) {
    final value = obj[key];
    if (value == null || value is! List || value.isEmpty) {
      throw DataValidationError(
        '$context: "$key" must be a non-empty array',
      );
    }
    for (var i = 0; i < value.length; i++) {
      if (value[i] is! String) {
        throw DataValidationError(
          '$context.$key[$i]: must be a string',
        );
      }
    }
  }
}

/// Thrown when JSON data does not conform to the expected schema.
class DataValidationError implements Exception {
  final String message;

  DataValidationError(this.message);

  @override
  String toString() => 'DataValidationError: $message';
}