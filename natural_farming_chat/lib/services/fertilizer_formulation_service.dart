import 'dart:math' as math;

import 'plant_lookup_service.dart';
import 'region_plant_service.dart';

/// NPK target ratios by use case, derived from FORMULATION_GUIDE.md.
/// Values represent relative proportions (not absolute percentages).
class NpkTarget {
  final String name;
  final String description;
  final double n;
  final double p;
  final double k;

  const NpkTarget(this.name, this.description, this.n, this.p, this.k);

  /// Normalize to ratio form (sum = 1.0).
  List<double> get ratioNormalized {
    final sum = n + p + k;
    if (sum == 0) return [0, 0, 0];
    return [n / sum, p / sum, k / sum];
  }

  String get ratioString =>
      '${n.toStringAsFixed(0)}-${p.toStringAsFixed(0)}-${k.toStringAsFixed(0)}';
}

/// NPK targets by growth stage and nutrient focus.
const npkTargets = {
  'nitrogen': NpkTarget(
    'High Nitrogen',
    'Best for leafy greens, vegetative growth stage',
    10, 5, 5,
  ),
  'phosphorus': NpkTarget(
    'High Phosphorus',
    'Best for root development, flowering, seedlings',
    5, 10, 10,
  ),
  'potassium': NpkTarget(
    'High Potassium',
    'Best for fruiting, disease resistance, late season',
    5, 5, 10,
  ),
  'balanced': NpkTarget(
    'Balanced',
    'General purpose, most crops',
    5, 5, 5,
  ),
  // Growth stage specific
  'vegetative': NpkTarget(
    'Vegetative Stage',
    'Early growth, leaf and stem development',
    10, 5, 5,
  ),
  'flowering': NpkTarget(
    'Flowering Stage',
    'Flower bud formation and bloom',
    5, 10, 10,
  ),
  'fruiting': NpkTarget(
    'Fruiting Stage',
    'Fruit development and ripening',
    5, 5, 10,
  ),
  'seedling': NpkTarget(
    'Seedling Stage',
    'Root establishment after transplant',
    10, 20, 10,
  ),
};

/// A plant with its extracted NPK values for a specific part.
class _PlantNpk {
  final String commonName;
  final String scientificName;
  final String partName;
  final double nitrogen;
  final double phosphorus;
  final double potassium;

  _PlantNpk({
    required this.commonName,
    required this.scientificName,
    required this.partName,
    required this.nitrogen,
    required this.phosphorus,
    required this.potassium,
  });

  double get total => nitrogen + phosphorus + potassium;

  /// PPM to dry weight percentage: 10000 ppm = 1%.
  double get nPercent => nitrogen / 10000;
  double get pPercent => phosphorus / 10000;
  double get kPercent => potassium / 10000;
}

/// One ingredient in a formulation blend.
class FormulationIngredient {
  final String commonName;
  final String scientificName;
  final String partUsed;
  final int percentage;
  final double nContribution;
  final double pContribution;
  final double kContribution;

  FormulationIngredient({
    required this.commonName,
    required this.scientificName,
    required this.partUsed,
    required this.percentage,
    required this.nContribution,
    required this.pContribution,
    required this.kContribution,
  });
}

/// Complete formulation result.
class FormulationResult {
  final bool success;
  final String regionName;
  final NpkTarget target;
  final List<FormulationIngredient> ingredients;
  final double totalN;
  final double totalP;
  final double totalK;
  final double matchScore;
  final String message;

  FormulationResult({
    required this.success,
    required this.regionName,
    required this.target,
    this.ingredients = const [],
    this.totalN = 0,
    this.totalP = 0,
    this.totalK = 0,
    this.matchScore = 0,
    required this.message,
  });
}

/// Service that cross-references regional plant availability with mineral
/// profiles to produce fertilizer blend formulations with NPK targets.
class FertilizerFormulationService {
  final RegionPlantService _regionService;
  final PlantLookupService _plantLookupService;

  FertilizerFormulationService({
    required RegionPlantService regionService,
    required PlantLookupService plantLookupService,
  })  : _regionService = regionService,
        _plantLookupService = plantLookupService;

  /// Create a fertilizer formulation for a given location and nutrient target.
  ///
  /// [location] - Country or region name (e.g., "Kenya", "California").
  /// [nutrient] - Target nutrient or growth stage key from [npkTargets].
  FormulationResult formulate(String location, String nutrient) {
    // Resolve target
    final target = npkTargets[nutrient.toLowerCase()];
    if (target == null) {
      return FormulationResult(
        success: false,
        regionName: location,
        target: npkTargets['balanced']!,
        message:
            'Unknown nutrient target "$nutrient". '
            'Valid options: ${npkTargets.keys.join(", ")}.',
      );
    }

    // Find matching regions
    final regions = _regionService.findRegions(location);
    if (regions.isEmpty) {
      return FormulationResult(
        success: false,
        regionName: location,
        target: target,
        message:
            'No region found matching "$location". '
            'Available countries: ${_regionService.countries.take(20).join(", ")}...',
      );
    }

    // Merge plants from all matching regions (e.g., "France" may match
    // country-level + Brittany + Loire Valley + Bordeaux)
    final allRegionPlants = <String, RegionPlant>{};
    final matchedRegionNames = <String>[];
    for (final region in regions) {
      matchedRegionNames.add(region.displayName);
      for (final plant in region.plants) {
        allRegionPlants[plant.scientificName.toLowerCase()] = plant;
      }
    }

    // Cross-reference with mineral profiles
    final candidates = <_PlantNpk>[];
    final sciIndex = _plantLookupService.byScientificName;

    for (final regionPlant in allRegionPlants.values) {
      final profile = _matchPlantProfile(
        regionPlant.scientificName,
        sciIndex,
      );
      if (profile == null) continue;

      final parts = profile['parts'] as Map<String, dynamic>;
      final commonName = profile['common_name'] as String;
      final scientificName = profile['scientific_name'] as String;

      // For each plant part, extract NPK values
      for (final partEntry in parts.entries) {
        final minerals =
            (partEntry.value as Map<String, dynamic>)['minerals']
                as Map<String, dynamic>;

        final n = _extractMineral(minerals, 'nitrogen');
        final p = _extractMineral(minerals, 'phosphorus');
        final k = _extractMineral(minerals, 'potassium');

        // Only include if at least one of N/P/K is measurable
        if (n > 0 || p > 0 || k > 0) {
          candidates.add(_PlantNpk(
            commonName: commonName,
            scientificName: scientificName,
            partName: partEntry.key,
            nitrogen: n,
            phosphorus: p,
            potassium: k,
          ));
        }
      }
    }

    if (candidates.isEmpty) {
      return FormulationResult(
        success: false,
        regionName: matchedRegionNames.join('; '),
        target: target,
        message:
            'Found ${allRegionPlants.length} plants in $location but none '
            'have NPK data in the mineral profiles database.',
      );
    }

    // Pick the best part per plant (highest in target nutrient)
    final bestPerPlant = _selectBestParts(candidates, target);

    if (bestPerPlant.length < 2) {
      return FormulationResult(
        success: false,
        regionName: matchedRegionNames.join('; '),
        target: target,
        message:
            'Only ${bestPerPlant.length} plant(s) with NPK data found in '
            '$location. Need at least 2 to create a blend.',
      );
    }

    // Build the blend
    final ingredients = _buildBlend(bestPerPlant, target);
    final totalN = ingredients.fold(0.0, (s, i) => s + i.nContribution);
    final totalP = ingredients.fold(0.0, (s, i) => s + i.pContribution);
    final totalK = ingredients.fold(0.0, (s, i) => s + i.kContribution);
    final score = _calculateMatchScore(totalN, totalP, totalK, target);

    final formulation = FormulationResult(
      success: true,
      regionName: matchedRegionNames.join('; '),
      target: target,
      ingredients: ingredients,
      totalN: totalN,
      totalP: totalP,
      totalK: totalK,
      matchScore: score,
      message: _formatFormulation(
        matchedRegionNames.first,
        target,
        ingredients,
        totalN,
        totalP,
        totalK,
        score,
      ),
    );

    return formulation;
  }

  /// Match a regional plant's scientific name to the mineral profile database.
  /// Uses multiple strategies: exact, prefix, genus, and stripped subspecies.
  Map<String, dynamic>? _matchPlantProfile(
    String scientificName,
    Map<String, Map<String, dynamic>> sciIndex,
  ) {
    final query = scientificName.toLowerCase().trim();

    // 1. Exact match
    if (sciIndex.containsKey(query)) return sciIndex[query];

    // 2. Prefix match: "allium sativum" matches "allium sativum var. sativum"
    for (final entry in sciIndex.entries) {
      if (entry.key.startsWith(query)) return entry.value;
    }

    // 3. Reverse prefix: "brassica oleracea var. sabellica" matches "brassica oleracea"
    for (final entry in sciIndex.entries) {
      if (query.startsWith(entry.key)) return entry.value;
    }

    // 4. Genus match for "spp." entries: "rubus spp." -> any "rubus *"
    if (query.endsWith(' spp.') || query.endsWith(' spp')) {
      final genus = query.split(' ').first;
      for (final entry in sciIndex.entries) {
        if (entry.key.startsWith('$genus ')) return entry.value;
      }
    }

    return null;
  }

  /// Extract average mineral concentration in ppm.
  /// Uses midpoint of min/max range, or whichever is available.
  double _extractMineral(Map<String, dynamic> minerals, String name) {
    final data = minerals[name];
    if (data == null) return 0;
    final map = data as Map<String, dynamic>;
    final min = (map['min'] as num?)?.toDouble();
    final max = (map['max'] as num?)?.toDouble();

    if (min != null && max != null) return (min + max) / 2;
    if (max != null) return max;
    if (min != null) return min;
    return 0;
  }

  /// From all candidate plant-part combos, select the single best part
  /// per plant (the one with highest concentration of the target nutrient).
  List<_PlantNpk> _selectBestParts(
    List<_PlantNpk> candidates,
    NpkTarget target,
  ) {
    // Group by scientific name
    final byPlant = <String, List<_PlantNpk>>{};
    for (final c in candidates) {
      byPlant.putIfAbsent(c.scientificName.toLowerCase(), () => []).add(c);
    }

    // For each plant, pick the part with highest target nutrient
    final best = <_PlantNpk>[];
    for (final parts in byPlant.values) {
      parts.sort((a, b) {
        final aScore = _targetScore(a, target);
        final bScore = _targetScore(b, target);
        return bScore.compareTo(aScore);
      });
      best.add(parts.first);
    }

    // Sort all by target nutrient score descending
    best.sort((a, b) =>
        _targetScore(b, target).compareTo(_targetScore(a, target)));

    return best;
  }

  /// Score a plant-part combo by how well it supplies the target nutrient.
  /// The target nutrient is weighted more heavily but all NPK contribute.
  double _targetScore(_PlantNpk plant, NpkTarget target) {
    final ratio = target.ratioNormalized;
    // Weighted sum: emphasize the dominant nutrient(s) in the target
    return plant.nitrogen * ratio[0] +
        plant.phosphorus * ratio[1] +
        plant.potassium * ratio[2];
  }

  /// Build a blend from the top candidates that targets the desired NPK ratio.
  ///
  /// Strategy:
  /// 1. Take top 3-5 plants by target score
  /// 2. Assign decreasing percentages (40%, 25%, 20%, 15% for 4 plants)
  /// 3. Adjust to balance off-target nutrients
  List<FormulationIngredient> _buildBlend(
    List<_PlantNpk> ranked,
    NpkTarget target,
  ) {
    // Take top 3-5 plants
    final count = ranked.length.clamp(2, 5);
    final selected = ranked.take(count).toList();

    // Assign base percentages
    final percentages = _assignPercentages(count);

    // Build ingredients
    final ingredients = <FormulationIngredient>[];
    for (var i = 0; i < selected.length; i++) {
      final plant = selected[i];
      final pct = percentages[i];
      final frac = pct / 100.0;

      ingredients.add(FormulationIngredient(
        commonName: plant.commonName,
        scientificName: plant.scientificName,
        partUsed: plant.partName,
        percentage: pct,
        nContribution: plant.nPercent * frac,
        pContribution: plant.pPercent * frac,
        kContribution: plant.kPercent * frac,
      ));
    }

    return ingredients;
  }

  /// Assign percentage weights for N ingredients.
  /// Decreasing allocation: primary ingredient gets the most.
  List<int> _assignPercentages(int count) {
    switch (count) {
      case 2:
        return [60, 40];
      case 3:
        return [45, 30, 25];
      case 4:
        return [40, 25, 20, 15];
      case 5:
        return [35, 25, 20, 12, 8];
      default:
        // Shouldn't happen due to clamp, but handle gracefully
        final base = 100 ~/ count;
        final remainder = 100 - (base * count);
        return List.generate(
          count,
          (i) => i == 0 ? base + remainder : base,
        );
    }
  }

  /// Calculate how well the blend matches the target NPK ratio (0-100%).
  double _calculateMatchScore(
    double totalN,
    double totalP,
    double totalK,
    NpkTarget target,
  ) {
    final sum = totalN + totalP + totalK;
    if (sum == 0) return 0;

    final actualRatio = [totalN / sum, totalP / sum, totalK / sum];
    final targetRatio = target.ratioNormalized;

    // Cosine similarity between actual and target ratio vectors
    double dot = 0, magA = 0, magB = 0;
    for (var i = 0; i < 3; i++) {
      dot += actualRatio[i] * targetRatio[i];
      magA += actualRatio[i] * actualRatio[i];
      magB += targetRatio[i] * targetRatio[i];
    }

    final magnitude = math.sqrt(magA) * math.sqrt(magB);
    if (magnitude == 0) return 0;

    return (dot / magnitude * 100).clamp(0, 100);
  }

  /// Format the formulation as human-readable text for the LLM to present.
  String _formatFormulation(
    String regionName,
    NpkTarget target,
    List<FormulationIngredient> ingredients,
    double totalN,
    double totalP,
    double totalK,
    double matchScore,
  ) {
    final buf = StringBuffer();
    buf.writeln('Formulation: ${target.name} Blend for $regionName');
    buf.writeln('Target NPK Ratio: ${target.ratioString}');
    buf.writeln('Best for: ${target.description}');
    buf.writeln();
    buf.writeln('Ingredients:');

    for (final ing in ingredients) {
      buf.writeln(
        '  ${ing.percentage}% ${ing.commonName} (${ing.partUsed}) '
        '- N: ${(ing.nContribution * 100).toStringAsFixed(2)}%, '
        'P: ${(ing.pContribution * 100).toStringAsFixed(2)}%, '
        'K: ${(ing.kContribution * 100).toStringAsFixed(2)}%',
      );
    }

    buf.writeln();
    buf.writeln(
      'Estimated Blend NPK: '
      '${(totalN * 100).toStringAsFixed(2)}-'
      '${(totalP * 100).toStringAsFixed(2)}-'
      '${(totalK * 100).toStringAsFixed(2)}',
    );
    buf.writeln('NPK Match Score: ${matchScore.toStringAsFixed(0)}%');
    buf.writeln();
    buf.writeln('Preparation (Fermented Wildcrafted Plant Fertilizer):');
    buf.writeln('1. Collect and finely chop the selected plants.');
    buf.writeln(
      '2. Mix with brown sugar or molasses (optional) to start fermentation.',
    );
    buf.writeln('3. Add LAB serum and IMO4 if available.');
    buf.writeln(
      '4. Add non-chlorinated water to create a slurry.',
    );
    buf.writeln(
      '5. Cover with breathable cloth, ferment 7-14 days in cool dark place.',
    );
    buf.writeln(
      '6. Dilute 1:10 with water and apply as soil drench or foliar spray.',
    );
    buf.writeln();
    buf.writeln('Application Rate: 2-4 lbs dry material per 100 sq ft.');
    buf.writeln('Note: Start with lower rates and monitor plant response.');

    return buf.toString().trimRight();
  }
}