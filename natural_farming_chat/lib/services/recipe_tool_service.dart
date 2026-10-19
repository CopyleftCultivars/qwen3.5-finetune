import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Deterministic Dart port of bioaccumulator #56's `recipe_tool_oracle.py`.
///
/// The Python oracle is the reference implementation. This service reproduces
/// its full `recipe-tool-result-v2` JSON (including the assumptions block and
/// warnings) and the compact `recipe_tool_served_view_v1` projection that the
/// model reads in QUICK mode.
///
/// The port deliberately avoids model calls. It reads the pinned app data plus
/// the approved mapping/derivation/constant files copied verbatim from
/// `bioaccumulator-benchmark-workspace`.
class RecipeToolService {
  static const String triggerTemplate =
      'Bioaccumulator recipe: <candidate plant> for my <crop>, <area> m2';
  static const String schemaVersion = 'recipe-tool-result-v2';
  static const String assumptionsVersion = 'recipe-tool-assumptions-v2';
  static const String servedViewVersion = 'recipe_tool_served_view_v1';

  static const String _assetRoot = 'assets/recipe_tool';
  static const String _plantDataRoot = 'assets/plant_data';

  static const Map<String, String> _nutrients = {
    'N': 'nitrogen',
    'P': 'phosphorus',
    'K': 'potassium',
  };

  static const Map<String, String> _nutrientLabels = {
    'N': 'Nitrogen',
    'P': 'Phosphorus',
    'K': 'Potassium',
  };

  /// Insertion order is the oracle's `PLANT_SCALABLE_RECIPES`.
  static const Map<String, String> _plantScalableRecipes = {
    'FPJ': 'N',
    'FFJ': 'K',
    'WSP': 'P',
  };

  static const Map<String, String> _unitAliases = {
    'm2': 'm2',
    'm²': 'm2',
    'sq m': 'm2',
    'square metres': 'm2',
    'square meters': 'm2',
  };

  static const Map<String, String> _applicationRateKeys = {
    'foliar': 'foliar_application_rate_l_per_ha',
    'soil_drench': 'soil_drench_application_rate_l_per_ha',
  };

  static const Map<String, String> _topUpRecipe = {
    'N': 'FPJ',
    'K': 'FFJ',
    'P': 'WSP',
  };

  static final RegExp _triggerPattern = RegExp(
    r'^\s*Bioaccumulator recipe:\s*(?<candidatePlant>.+?)\s+for my\s+'
    r'(?<crop>[^,]+),\s*(?<quantity>\d+(?:\.\d+)?)\s*'
    r'(?<unit>m2|m²|sq m|square metres|square meters)\s*$',
    caseSensitive: false,
  );

  static final RegExp _broadTriggerPattern = RegExp(
    r'^\s*Bioaccumulator recipe:\s*(?<candidatePlant>.+?)\s+for my\s+'
    r'(?<crop>[^,]+),\s*(?<quantity>\d+(?:\.\d+)?)\s*'
    r'(?<unit>[^\s,]+(?:\s+[^\s,]+)*)\s*$',
    caseSensitive: false,
  );

  late List<Map<String, dynamic>> _crops;
  late List<Map<String, dynamic>> _plants;
  late List<Map<String, dynamic>> _recipes;
  late Map<String, dynamic> _mapping;
  late Map<String, dynamic> _derivationProposal;
  late Map<String, dynamic> _constants;
  late Map<String, dynamic> _triggerProposal;

  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Load the bundled recipe-tool contract.
  Future<void> initialize({AssetBundle? bundle}) async {
    if (_initialized) return;
    final assets = bundle ?? rootBundle;
    Future<String> read(String path) => assets.loadString(path);

    final rawCrops = jsonDecode(
      await read('$_plantDataRoot/Crop_Requirements.json'),
    );
    final rawPlants = jsonDecode(
      await read('$_plantDataRoot/plant_mineral_profiles.json'),
    );
    final rawRecipes = jsonDecode(
      await read('$_plantDataRoot/Enriched_Recipes.json'),
    );
    final rawMapping = jsonDecode(
      await read('$_assetRoot/recipe_mapping_v1.json'),
    );
    final rawProposal = jsonDecode(
      await read('$_assetRoot/recipe_mapping_derivations_proposal_v1.json'),
    );
    final rawConstants = jsonDecode(
      await read('$_assetRoot/recipe_tool_dosing_constants_proposal_v2.json'),
    );
    final rawTrigger = jsonDecode(
      await read('$_assetRoot/recipe_tool_trigger_template_proposal_v1.json'),
    );

    _crops = (rawCrops as List).cast<Map<String, dynamic>>();
    _plants = (rawPlants as List).cast<Map<String, dynamic>>();
    _recipes = (rawRecipes as List).cast<Map<String, dynamic>>();
    _mapping = rawMapping as Map<String, dynamic>;
    _derivationProposal = rawProposal as Map<String, dynamic>;
    _constants = rawConstants as Map<String, dynamic>;
    _triggerProposal = rawTrigger as Map<String, dynamic>;
    _initialized = true;
  }

  /// Test/constructor hook: load already-decoded contract data.
  void loadFromData({
    required List<Map<String, dynamic>> crops,
    required List<Map<String, dynamic>> plants,
    required List<Map<String, dynamic>> recipes,
    required Map<String, dynamic> mapping,
    required Map<String, dynamic> derivationProposal,
    required Map<String, dynamic> constants,
    required Map<String, dynamic> triggerProposal,
  }) {
    _crops = crops;
    _plants = plants;
    _recipes = recipes;
    _mapping = mapping;
    _derivationProposal = derivationProposal;
    _constants = constants;
    _triggerProposal = triggerProposal;
    _initialized = true;
  }

  Map<String, dynamic> get triggerProposal => _triggerProposal;

  /// Parse the fixed trigger template with exactly the oracle's semantics.
  ///
  /// Throws [RecipeTriggerException] with the oracle's `error.code` and
  /// `error.message` when the prefix is present but the message is malformed.
  RecipeTrigger parseTrigger(String text) {
    final match = _triggerPattern.firstMatch(text);
    if (match == null) {
      final broad = _broadTriggerPattern.firstMatch(text);
      if (broad != null) {
        throw RecipeTriggerException(
          'unsupported_unit',
          "Unit must be m2 (or m², sq m, square metres, square meters) in v2; "
              "got '${_trim(broad.namedGroup('unit'))}'.",
        );
      }
      throw RecipeTriggerException(
        'trigger_not_matched',
        "Message does not match 'Bioaccumulator recipe: <candidate plant> "
            "for my <crop>, <area> m2'.",
      );
    }
    final unit = _trim(match.namedGroup('unit')).toLowerCase();
    final canonical = _unitAliases[unit];
    if (canonical == null) {
      throw RecipeTriggerException(
        'unsupported_unit',
        'Unit must be m2 (or m², sq m, square metres, square meters) in v2.',
      );
    }
    final quantity = double.parse(match.namedGroup('quantity')!);
    if (!quantity.isFinite || quantity <= 0) {
      throw RecipeTriggerException(
        'invalid_quantity',
        'Area must be a positive number.',
      );
    }
    return RecipeTrigger(
      candidatePlant: _trim(match.namedGroup('candidatePlant')),
      crop: _trim(match.namedGroup('crop')),
      quantity: quantity,
      unit: canonical,
    );
  }

  /// True when [text] starts with the fixed trigger prefix.
  bool hasTriggerPrefix(String text) =>
      text.trimLeft().toLowerCase().startsWith('bioaccumulator recipe:');

  /// The full `recipe-tool-result-v2` object for [payload].
  Map<String, dynamic> calculate(Map<String, dynamic> payload) {
    _ensureLoaded();
    final validation = _validateInput(payload);
    if (validation.error != null) return validation.error!;
    final normalised = validation.normalised!;

    final crop = _resolveCrop(normalised['crop'] as String);
    if (crop == null) {
      return _error(
        normalised,
        'unknown_crop',
        "no crop matches '${normalised['crop']}'",
      );
    }
    final plantResult = _resolvePlant(normalised['candidate_plant'] as String);
    final plant = plantResult.plant;
    if (plant == null) {
      final suggestions = plantResult.suggestions;
      return _error(
        normalised,
        suggestions.isNotEmpty ? 'ambiguous_plant' : 'unknown_plant',
        "candidate plant '${normalised['candidate_plant']}' did not resolve to one profile",
        suggestions.isNotEmpty ? {'candidates': suggestions} : null,
      );
    }

    final requirements = _cropRequirements(crop);
    if (requirements.ranges.isEmpty) {
      return _error(
        normalised,
        'crop_requirement_missing',
        'crop has no parseable N/P/K requirement',
      );
    }

    final tissues = _tissueMap(plant);
    final ratios = <String, dynamic>{};
    for (final short in _nutrients.keys) {
      final tissue = tissues[short];
      final cropMid = requirements.midpoints[short];
      if (tissue == null) {
        ratios[short] = {
          'value': null,
          'comparable': false,
          'tissue_midpoint_ppm': null,
          'crop_requirement_midpoint_kg_per_ha': cropMid == null
              ? null
              : _round(cropMid, 6),
          'part': null,
          'unit': 'ppm_per_kg_per_ha',
          'reason':
              'catalog profile has no complete ${_nutrients[short]} tissue value',
        };
        continue;
      }
      if (cropMid == null || cropMid <= 0) {
        ratios[short] = {
          'value': null,
          'comparable': false,
          'tissue_midpoint_ppm': _round(tissue['midpoint_ppm'] as double, 6),
          'crop_requirement_midpoint_kg_per_ha': null,
          'part': tissue['part'],
          'unit': 'ppm_per_kg_per_ha',
          'reason':
              'crop has no positive ${_nutrients[short]} requirement midpoint',
        };
        continue;
      }
      final ratioDecimals = _constantValue('ratio_rounding_decimals').toInt();
      ratios[short] = {
        'value': _round(
          (tissue['midpoint_ppm'] as double) / cropMid,
          ratioDecimals,
        ),
        'comparable': true,
        'tissue_midpoint_ppm': _round(tissue['midpoint_ppm'] as double, 6),
        'crop_requirement_midpoint_kg_per_ha': _round(cropMid, 6),
        'part': tissue['part'],
        'unit': 'ppm_per_kg_per_ha',
        'reason': null,
      };
    }

    final selections = _selectRecipes(plant);
    if (selections.isEmpty) {
      return _error(
        normalised,
        'candidate_not_offered_for_recipe',
        "'${plant['common_name']}' is not recipe-named or in the approved derived "
            'top-10 for N, P or K',
        {'suggestions': _candidateSuggestions()},
      );
    }

    final nutritionTrack = _buildNutritionTrack(
      plant,
      requirements.midpoints,
      normalised['quantity'] as double,
      normalised['target_fraction'] as double,
      selections,
    );
    final boosterRecipes = [
      for (final selection in selections)
        _buildBoosterRecipe(
          selection,
          plant,
          requirements.midpoints,
          normalised['quantity'] as double,
        ),
    ];

    final warnings = <String>[];
    final sizing = nutritionTrack['sizing_nutrient'] as String?;
    if (sizing != null) {
      final coverage = nutritionTrack['coverage'] as Map<String, dynamic>;
      final coverageBits = _nutrients.keys
          .where((nutrient) => coverage[nutrient] != null)
          .map(
            (nutrient) =>
                '$nutrient ${_pyG(_round((coverage[nutrient] as double) * 100.0, 1))}%',
          )
          .join(', ');
      warnings.add(
        'NUTRITION track (no overshoot): $sizing is the sizing nutrient; '
        '${_pyFloatStr(nutritionTrack['sizing_fresh_plant_material_kg'] as double)} kg fresh plant material '
        '(${_pyFloatStr(nutritionTrack['sizing_fresh_plant_material_kg_per_m2'] as double)} kg/m2) is spread for '
        '${_pyFloatStr(_round(normalised['quantity'] as double, 6))} m2 at a target fraction of '
        '${_pyFloatStr(nutritionTrack['target_fraction'] as double)}. Nutrient coverage: $coverageBits.',
      );
      for (final note
          in (nutritionTrack['top_up_notes'] as List).cast<String>()) {
        warnings.add('NUTRITION track top-up: $note');
      }
    } else {
      warnings.add(
        'NUTRITION track: no nutrient has both a complete candidate tissue and a positive crop '
        'requirement, so no fresh-material mass is calculated.',
      );
    }
    for (final rawMethod in (nutritionTrack['methods'] as List)) {
      final method = rawMethod as Map<String, dynamic>;
      if (method['method'] == 'mulch' &&
          method['fits_standard_depth'] == false) {
        warnings.add(
          'NUTRITION track mulch: ${_pyFloatStr(nutritionTrack['sizing_fresh_plant_material_kg_per_m2'] as double)} kg/m2 '
          'spread as a single surface layer is about ${_pyFloatStr(method['implied_depth_cm'] as double)} cm, deeper than '
          'the sourced ${_pyFloatStr(method['max_depth_cm'] as double)} cm maximum; split it into several applications.',
        );
      }
      if (method['method'] == 'plant_tea' &&
          method['fits_standard_rate'] == false) {
        warnings.add(
          'NUTRITION track plant tea: the sizing-mass tea volume needs '
          '${_pyFloatStr(_round((method['rate_l_per_m2'] as double) / (method['standard_rate_l_per_m2'] as double), 6))}x the standard '
          'liquid application rate; the tea volume, not the plant material, is the constraint.',
        );
      }
    }
    for (final rawRecipe in boosterRecipes) {
      final recipe = rawRecipe;
      if (recipe['computable'] != true) {
        warnings.add(
          '${recipe['recipe_abbrev']} booster: ${recipe['not_computable_reason']}; the template is '
          'returned but no standard batch is calculated.',
        );
        continue;
      }
      final dose = (recipe['application'] as Map<String, dynamic>?) ?? const {};
      final batch =
          (recipe['standard_batch'] as Map<String, dynamic>?) ?? const {};
      warnings.add(
        "BOOSTER only: ${recipe['recipe_abbrev']} at the recipe's standard rate supplies "
        "${_pyFloatStr((dose['nutrient_supplied_kg'] as num).toDouble())} kg ${recipe['target_nutrient']} "
        '(${_pyG(_round(((dose['fraction_of_requirement'] as num?)?.toDouble() ?? 0.0) * 100.0, 6))}% of the crop\'s full '
        "${recipe['target_nutrient']} requirement) from a standard batch of "
        "${_pyFloatStr((batch['plant_material_fresh_kg'] as num).toDouble())} kg fresh plant material; it is not a "
        'requirement-coverage dose.',
      );
      if ((recipe['template_adaptation'] as Map<String, dynamic>)['adapted'] ==
          true) {
        warnings.add(
          "${recipe['recipe_abbrev']}: v2 substitutes the candidate plant material for the "
          "source recipe's non-plant main input; this is a derived proposal.",
        );
      }
      if ((recipe['selection_note'] as String).contains('Trifolium repens')) {
        warnings.add(
          "${recipe['recipe_abbrev']}: the recipe names Trifolium repens (white clover); "
          'the catalog profile is Red Clover (Trifolium pratense)',
        );
      }
    }

    return {
      'schema_version': schemaVersion,
      'status': 'ok',
      'input': normalised,
      'candidate_plant': {
        'common_name': _text(plant, 'common_name'),
        'scientific_name': _text(plant, 'scientific_name'),
        'matched_via':
            _normalize(normalised['candidate_plant'] as String) ==
                _normalize(_text(plant, 'common_name'))
            ? 'common_name'
            : 'resolved',
        'tissue': tissues,
      },
      'crop': {
        'common_name': _text(crop, 'Crop'),
        'scientific_name': _text(crop, 'Scientific Name'),
        'requirement_ranges_kg_per_ha': requirements.ranges,
        'requirement_kg_per_ha': {
          for (final entry in requirements.midpoints.entries)
            entry.key: _round(entry.value, 6),
        },
        'source': {
          'file': 'Crop_Requirements.json',
          'sha256': _appDataSha256['Crop_Requirements.json'],
          'field': 'NPK Requirements',
        },
      },
      'ratios': ratios,
      'nutrition_track': nutritionTrack,
      'booster_track': {
        'basis':
            ("source recipe standard batch at the recipe's standard dilution and application rate; "
            'the nutrient supplied is information only and makes no requirement-coverage claim'),
        'recipes': boosterRecipes,
      },
      'assumptions': _assumptions(),
      'warnings': warnings,
    };
  }

  /// Project a full oracle result into the compact model-facing served view.
  Map<String, dynamic> servedView(Map<String, dynamic> result) {
    if (result['status'] != 'ok') {
      final error = (result['error'] as Map<String, dynamic>?) ?? const {};
      return {
        'served_view_version': servedViewVersion,
        'status': 'error',
        'error': {'code': error['code'], 'message': error['message']},
      };
    }

    final nutrition = result['nutrition_track'] as Map<String, dynamic>;
    final nutrientBodies = nutrition['nutrients'] as Map<String, dynamic>;
    final coverage = {
      for (final short in _nutrients.keys)
        short: _significance(nutrientBodies[short]['coverage_percent']),
    };
    final methods = (nutrition['methods'] as List?) ?? const [];
    final recipes =
        ((result['booster_track'] as Map<String, dynamic>)['recipes'] as List)
            .cast<Map<String, dynamic>>();
    Map<String, dynamic>? firstComputable;
    for (final recipe in recipes) {
      if (recipe['computable'] == true) {
        firstComputable = recipe;
        break;
      }
    }
    final booster = _servedBooster(firstComputable);
    final nonComputable = [
      for (final recipe in recipes)
        if (recipe['computable'] != true) recipe['recipe_abbrev'] as String,
    ];

    final candidate = result['candidate_plant'] as Map<String, dynamic>;
    final crop = result['crop'] as Map<String, dynamic>;
    return {
      'served_view_version': servedViewVersion,
      'status': 'ok',
      'candidate_plant': (candidate['common_name'] as String).isNotEmpty
          ? candidate['common_name']
          : candidate['scientific_name'],
      'crop': crop['common_name'],
      'area_m2': _significance(
        (result['input'] as Map<String, dynamic>)['quantity'],
      ),
      'nutrition': {
        'sizing_nutrient': nutrition['sizing_nutrient'],
        'fresh_material_kg': _significance(
          nutrition['sizing_fresh_plant_material_kg'],
        ),
        'fresh_material_kg_per_m2': _significance(
          nutrition['sizing_fresh_plant_material_kg_per_m2'],
        ),
        'coverage_percent': coverage,
        'top_up_notes': _servedTopUpNotes(nutrition),
        'method': _servedMethod(
          methods.isEmpty ? null : methods.first as Map<String, dynamic>,
        ),
      },
      'booster': booster,
      'non_computable_recipes': nonComputable,
      'assumptions': _servedAssumptions(nutrition, booster, nonComputable),
    };
  }

  // ---------------------------------------------------------------------
  // Input validation and resolution
  // ---------------------------------------------------------------------

  ({Map<String, dynamic>? normalised, Map<String, dynamic>? error})
  _validateInput(Map<String, dynamic> payload) {
    final candidate = payload['candidate_plant'];
    final crop = payload['crop'];
    final quantity = payload['quantity'];
    final unit = payload['unit'];
    final targetFraction = payload.containsKey('target_fraction')
        ? payload['target_fraction']
        : 1.0;
    final normalised = <String, dynamic>{
      'candidate_plant': candidate is String ? candidate : '',
      'crop': crop is String ? crop : '',
      'quantity': quantity is num ? quantity : null,
      'unit': unit is String ? unit : null,
      'target_fraction': targetFraction is num ? targetFraction : null,
    };
    if (candidate is! String || candidate.trim().isEmpty) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'invalid_candidate_plant',
          'candidate_plant must be a non-empty string.',
        ),
      );
    }
    if (crop is! String || crop.trim().isEmpty) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'invalid_crop',
          'crop must be a non-empty string.',
        ),
      );
    }
    if (quantity is! num) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'invalid_quantity',
          'quantity must be a number.',
        ),
      );
    }
    final quantityValue = quantity.toDouble();
    if (!quantityValue.isFinite || quantityValue <= 0) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'invalid_quantity',
          'quantity must be a positive finite number.',
        ),
      );
    }
    if (quantityValue > 1000000) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'invalid_quantity',
          'quantity must be at most 1,000,000 m2.',
        ),
      );
    }
    if (unit is! String || !_unitAliases.containsKey(unit)) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'unsupported_unit',
          'unit must be m2; convert other units before calling the tool.',
          {
            'accepted_units': [
              'm2',
              'm²',
              'sq m',
              'square metres',
              'square meters',
            ],
          },
        ),
      );
    }
    if (targetFraction is! num) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'invalid_target_fraction',
          'target_fraction must be a number in (0, 1].',
        ),
      );
    }
    final fraction = targetFraction.toDouble();
    if (!fraction.isFinite || fraction <= 0 || fraction > 1) {
      return (
        normalised: null,
        error: _error(
          normalised,
          'invalid_target_fraction',
          'target_fraction must be greater than 0 and at most 1.',
        ),
      );
    }
    normalised['quantity'] = quantityValue;
    normalised['unit'] = _unitAliases[unit];
    normalised['target_fraction'] = _round(fraction, 6);
    return (normalised: normalised, error: null);
  }

  Map<String, dynamic>? _resolveCrop(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    for (final row in _crops) {
      if (normalized == _text(row, 'Crop').toLowerCase() ||
          normalized == _text(row, 'Scientific Name').toLowerCase()) {
        return row;
      }
    }
    for (final row in _crops) {
      if (_text(row, 'Crop').toLowerCase().contains(normalized)) return row;
    }
    return null;
  }

  ({Map<String, dynamic>? plant, List<String> suggestions}) _resolvePlant(
    String query,
  ) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return (plant: null, suggestions: const []);
    final common = _nameIndex('common_name');
    final scientific = _nameIndex('scientific_name');
    final commonExact = common[normalized];
    if (commonExact != null) return (plant: commonExact, suggestions: const []);
    final scientificExact = scientific[normalized];
    if (scientificExact != null)
      return (plant: scientificExact, suggestions: const []);

    for (final entry
        in <({Map<String, Map<String, dynamic>> index, bool scientific})>[
          (index: common, scientific: false),
          (index: scientific, scientific: true),
        ]) {
      final matches = <Map<String, dynamic>>[];
      for (final item in entry.index.entries) {
        if (item.key.contains(normalized) || normalized.contains(item.key)) {
          matches.add(item.value);
        }
      }
      if (matches.length == 1)
        return (plant: matches.first, suggestions: const []);
      if (matches.isNotEmpty) {
        final candidates = matches.take(10).map((row) {
          if (entry.scientific) {
            return '${_text(row, 'common_name')} (${_text(row, 'scientific_name')})';
          }
          return _text(row, 'common_name');
        }).toList();
        return (plant: null, suggestions: candidates);
      }
    }
    return (plant: null, suggestions: const []);
  }

  Map<String, Map<String, dynamic>> _nameIndex(String key) {
    final index = <String, Map<String, dynamic>>{};
    for (final row in _plants) {
      final name = _text(row, key).toLowerCase();
      if (name.isNotEmpty) index[name] = row;
    }
    return index;
  }

  // ---------------------------------------------------------------------
  // Crop requirement and tissue lookups
  // ---------------------------------------------------------------------

  ({Map<String, dynamic> ranges, Map<String, double> midpoints})
  _cropRequirements(Map<String, dynamic> crop) {
    final requirements = crop['NPK Requirements'];
    final body = requirements is Map<String, dynamic>
        ? requirements
        : <String, dynamic>{};
    final ranges = <String, dynamic>{};
    final midpoints = <String, double>{};
    for (final entry in _nutrients.entries) {
      final field = _nutrientLabels[entry.key]!;
      final parsed = _parseRange(body[field]);
      if (parsed == null) continue;
      ranges[entry.key] = {'min': parsed.$1, 'max': parsed.$2};
      midpoints[entry.key] = (parsed.$1 + parsed.$2) / 2;
    }
    return (ranges: ranges, midpoints: midpoints);
  }

  Map<String, Map<String, dynamic>?> _tissueMap(Map<String, dynamic> profile) {
    return {
      for (final short in _nutrients.keys)
        short: _bestTissue(profile, _nutrients[short]!),
    };
  }

  Map<String, dynamic>? _tissueFromPart(
    Map<String, dynamic> profile,
    String part,
    String mineral,
  ) {
    final parts = profile['parts'];
    if (parts is! Map<String, dynamic>) return null;
    final body = parts[part];
    if (body is! Map<String, dynamic>) return null;
    final minerals = body['minerals'];
    if (minerals is! Map<String, dynamic>) return null;
    final value = minerals[mineral];
    if (value is! Map<String, dynamic>) return null;
    final low = _numeric(value['min']);
    final high = _numeric(value['max']);
    if (low == null || high == null) return null;
    return {
      'part': part,
      'min_ppm': low,
      'max_ppm': high,
      'midpoint_ppm': (low + high) / 2,
      'unit': value['unit'] ?? 'ppm',
      'basis': 'dry matter',
    };
  }

  Map<String, dynamic>? _bestTissue(
    Map<String, dynamic> profile,
    String mineral,
  ) {
    final parts = profile['parts'];
    if (parts is! Map<String, dynamic>) return null;
    Map<String, dynamic>? best;
    for (final entry in parts.entries) {
      final body = entry.value;
      if (body is! Map<String, dynamic>) continue;
      final minerals = body['minerals'];
      if (minerals is! Map<String, dynamic>) continue;
      final value = minerals[mineral];
      if (value is! Map<String, dynamic>) continue;
      final low = value['min'];
      final high = value['max'];
      if (low is! num || high is! num) continue;
      final lowValue = low.toDouble();
      final highValue = high.toDouble();
      final midpoint = (lowValue + highValue) / 2;
      final candidate = <String, dynamic>{
        'part': entry.key,
        'min': lowValue,
        'max': highValue,
        'unit': value['unit'] ?? 'ppm',
        'midpoint': midpoint,
      };
      if (best == null ||
          midpoint > (best['midpoint'] as double) ||
          (midpoint == (best['midpoint'] as double) &&
              entry.key.compareTo(best['part'] as String) > 0)) {
        best = candidate;
      }
    }
    if (best == null) return null;
    return {
      'part': best['part'],
      'min_ppm': best['min'],
      'max_ppm': best['max'],
      'midpoint_ppm': best['midpoint'],
      'unit': best['unit'] ?? 'ppm',
      'basis': 'dry matter',
    };
  }

  // ---------------------------------------------------------------------
  // Recipe selection
  // ---------------------------------------------------------------------

  List<Map<String, dynamic>> _selectRecipes(Map<String, dynamic> profile) {
    final selected = <Map<String, dynamic>>[];
    for (final abbrev in _plantScalableRecipes.keys) {
      final meta = _recipeMeta(abbrev);
      if (meta == null) continue;
      final targetNutrient = _plantScalableRecipes[abbrev]!;
      final targetMineral = _nutrients[targetNutrient]!;
      final named = _recipeNamedEntries(meta);
      final derived = _derivedEntries(abbrev);
      final derivedApproved = derived.approved;
      Map<String, dynamic>? namedMatch;
      for (final entry in named) {
        if (_matchesProfile(profile, entry)) {
          namedMatch = entry;
          break;
        }
      }
      Map<String, dynamic>? derivedMatch;
      for (final entry in derived.entries) {
        if (_matchesProfile(profile, entry)) {
          derivedMatch = entry;
          break;
        }
      }
      if (namedMatch != null) {
        selected.add({
          'recipe_abbrev': abbrev,
          'recipe_name': (meta['recipe_name'] as String?) ?? '',
          'target_nutrient': targetNutrient,
          'target_mineral': targetMineral,
          'selection': 'recipe_named',
          'selection_note':
              "candidate matches the source recipe's suggested bioaccumulator "
              "'${namedMatch['text']}' (profile ${namedMatch['common_name']})",
          'named_match': namedMatch,
          'derived_rank': derivedMatch?['rank'],
          'derived_allowed': derivedApproved,
        });
      } else if (derivedMatch != null && derivedApproved) {
        selected.add({
          'recipe_abbrev': abbrev,
          'recipe_name': (meta['recipe_name'] as String?) ?? '',
          'target_nutrient': targetNutrient,
          'target_mineral': targetMineral,
          'selection': 'derived',
          'selection_note':
              "candidate is rank ${derivedMatch['rank']} in the owner-approved "
              'top-10 catalog plants for $targetMineral '
              '(tissue midpoint ${_pyFloatStr(derivedMatch['midpoint_ppm'] as double)} ppm in ${derivedMatch['part']})',
          'named_match': null,
          'derived_rank': derivedMatch['rank'],
          'derived_allowed': derivedApproved,
        });
      }
    }
    return selected;
  }

  Map<String, dynamic>? _recipeMeta(String abbrev) {
    for (final recipe in (_mapping['recipes'] as List?) ?? const []) {
      if (recipe is Map<String, dynamic> && recipe['recipe_abbrev'] == abbrev) {
        return recipe;
      }
    }
    return null;
  }

  Map<String, dynamic>? _sourceRecipe(String abbrev) {
    for (final recipe in _recipes) {
      if (recipe['recipe_abbrev'] == abbrev) return recipe;
    }
    return null;
  }

  List<Map<String, dynamic>> _recipeNamedEntries(Map<String, dynamic> recipe) {
    final entries = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final raw
        in (recipe['suggested_bioaccumulators'] as List?) ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['status'] != 'resolved' || raw['category'] != 'plant') continue;
      final profile = raw['profile'];
      if (profile is! Map<String, dynamic>) continue;
      final common = _trim(profile['common_name']);
      if (common.isEmpty || seen.contains(common)) continue;
      seen.add(common);
      entries.add({
        'text': _trim(raw['text']),
        'common_name': common,
        'scientific_name': _trim(profile['scientific_name']),
        'part': raw['part'],
        'note': raw['note'],
      });
    }
    return entries;
  }

  ({List<Map<String, dynamic>> entries, bool approved}) _derivedEntries(
    String abbrev,
  ) {
    final approved = _derivationProposal['status'] == 'approved_by_owner';
    for (final rawBlock
        in (_derivationProposal['recipe_candidate_plants'] as List?) ??
            const []) {
      if (rawBlock is! Map<String, dynamic> ||
          rawBlock['recipe_abbrev'] != abbrev)
        continue;
      final blockApproved = rawBlock['status'] == 'approved_by_owner';
      final entries = <Map<String, dynamic>>[];
      var rank = 1;
      for (final raw in (rawBlock['candidates'] as List?) ?? const []) {
        final candidate = raw as Map<String, dynamic>;
        entries.add({
          'common_name': (candidate['common_name'] as String?) ?? '',
          'scientific_name': (candidate['scientific_name'] as String?) ?? '',
          'part': (candidate['part'] as String?) ?? '',
          'midpoint_ppm': _numeric(candidate['midpoint']) ?? 0.0,
          'rank': rank,
        });
        rank += 1;
      }
      return (entries: entries, approved: approved || blockApproved);
    }
    return (entries: const [], approved: approved);
  }

  bool _matchesProfile(
    Map<String, dynamic> profile,
    Map<String, dynamic> entry,
  ) {
    final common = _normalize(_text(profile, 'common_name'));
    final scientific = _normalize(_text(profile, 'scientific_name'));
    return (common.isNotEmpty &&
            common == _normalize(entry['common_name'] as String?)) ||
        (scientific.isNotEmpty &&
            scientific == _normalize(entry['scientific_name'] as String?));
  }

  Map<String, List<String>> _candidateSuggestions() {
    final suggestions = <String, List<String>>{};
    for (final entry in _plantScalableRecipes.entries) {
      final abbrev = entry.key;
      final meta = _recipeMeta(abbrev);
      if (meta == null) continue;
      final names = <String>[];
      for (final named in _recipeNamedEntries(meta)) {
        names.add('${named['common_name']} (recipe-named)');
      }
      final derived = _derivedEntries(abbrev);
      if (derived.approved) {
        for (final candidate in derived.entries) {
          final label =
              "${candidate['common_name']} (derived #${candidate['rank']})";
          if (!names.contains(label)) names.add(label);
        }
      }
      suggestions[entry.value] = names.take(5).toList();
    }
    return suggestions;
  }

  // ---------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------

  double _constantValue(String name) {
    final constants = _constants['constants'] as Map<String, dynamic>;
    final body = constants[name] as Map<String, dynamic>;
    return (body['value'] as num).toDouble();
  }

  ({double rate, String source})? _applicationRate(String method) {
    final key = _applicationRateKeys[method];
    if (key == null) return null;
    final constants = _constants['constants'] as Map<String, dynamic>;
    final constant = constants[key] as Map<String, dynamic>;
    final ratePerHa = (constant['value'] as num).toDouble();
    final source = constant['source'] as Map<String, dynamic>;
    final label =
        '${source['corpus_file']}:${source['line']} (${source['quote']})';
    return (rate: ratePerHa / 10000.0, source: label);
  }

  ({String category, bool fallback}) _partCategory(String part) {
    final body =
        (_constants['constants'] as Map<String, dynamic>)['dry_matter_fraction']
            as Map<String, dynamic>;
    final mapping =
        (body['part_category_map'] as Map<String, dynamic>?) ?? const {};
    final category = mapping[part];
    if (category == null) {
      return (
        category: (body['default_category'] as String?) ?? 'herb',
        fallback: true,
      );
    }
    return (category: category as String, fallback: false);
  }

  ({double value, String category, bool fallback}) _dryMatterForPart(
    String part,
  ) {
    final body =
        (_constants['constants'] as Map<String, dynamic>)['dry_matter_fraction']
            as Map<String, dynamic>;
    final categoryResult = _partCategory(part);
    final byPart = (body['by_part'] as Map<String, dynamic>?) ?? const {};
    final entry =
        (byPart[categoryResult.category] as Map<String, dynamic>?) ??
        (byPart['herb'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final value =
        (entry['value'] as num?)?.toDouble() ??
        (body['value'] as num?)?.toDouble() ??
        0.15;
    return (
      value: value,
      category: categoryResult.category,
      fallback: categoryResult.fallback,
    );
  }

  double _releaseForNutrient(String nutrient) {
    final body =
        (_constants['constants']
                as Map<String, dynamic>)['nutrient_release_fraction']
            as Map<String, dynamic>;
    final byNutrient =
        (body['by_nutrient'] as Map<String, dynamic>?) ?? const {};
    final entry = (byNutrient[nutrient] as Map<String, dynamic>?) ?? const {};
    return (entry['value'] as num?)?.toDouble() ??
        (body['value'] as num?)?.toDouble() ??
        0.0;
  }

  // ---------------------------------------------------------------------
  // Nutrition track
  // ---------------------------------------------------------------------

  Map<String, dynamic> _buildNutritionTrack(
    Map<String, dynamic> profile,
    Map<String, double> cropMidpoints,
    double areaM2,
    double targetFraction,
    List<Map<String, dynamic>> selections,
  ) {
    final amountDecimals = _constantValue('amount_rounding_decimals').toInt();
    final tissues = _tissueMap(profile);
    final nutrients = <String, dynamic>{};
    for (final short in _nutrients.keys) {
      final tissue = tissues[short];
      final cropMid = cropMidpoints[short];
      if (tissue == null) {
        nutrients[short] = {
          'computable': false,
          'reason':
              'catalog profile has no complete ${_nutrients[short]} tissue value',
          'part': null,
          'part_category': null,
          'dry_matter_fraction': null,
          'release_fraction': null,
          'tissue_midpoint_ppm': null,
          'crop_requirement_kg_per_ha': cropMid == null
              ? null
              : _round(cropMid, 6),
          'available_g_per_kg_fresh': null,
          'required_kg': null,
          'fresh_plant_material_kg': null,
          'fresh_plant_material_kg_per_m2': null,
          'coverage_fraction': null,
          'coverage_percent': null,
          'shortfall_fresh_plant_material_kg': null,
          'shortfall_nutrient_kg': null,
          'top_up_source': null,
          'top_up_note': null,
        };
        continue;
      }
      if (cropMid == null || cropMid <= 0) {
        nutrients[short] = {
          'computable': false,
          'reason':
              'crop has no positive ${_nutrients[short]} requirement midpoint',
          'part': tissue['part'],
          'part_category': null,
          'dry_matter_fraction': null,
          'release_fraction': null,
          'tissue_midpoint_ppm': _round(tissue['midpoint_ppm'] as double, 6),
          'crop_requirement_kg_per_ha': null,
          'available_g_per_kg_fresh': null,
          'required_kg': null,
          'fresh_plant_material_kg': null,
          'fresh_plant_material_kg_per_m2': null,
          'coverage_fraction': null,
          'coverage_percent': null,
          'shortfall_fresh_plant_material_kg': null,
          'shortfall_nutrient_kg': null,
          'top_up_source': null,
          'top_up_note': null,
        };
        continue;
      }
      final dm = _dryMatterForPart(tissue['part'] as String);
      final release = _releaseForNutrient(short);
      final available =
          (tissue['midpoint_ppm'] as double) / 1000.0 * dm.value * release;
      final requiredG = cropMid * 0.1 * areaM2 * targetFraction;
      final freshKg = available != 0 ? requiredG / available : null;
      nutrients[short] = {
        'computable': freshKg != null,
        'reason': freshKg != null
            ? null
            : 'the tissue/release combination gives no available nutrient',
        'part': tissue['part'],
        'part_category': dm.category,
        'dry_matter_fraction': dm.value,
        'dry_matter_fallback': dm.fallback,
        'release_fraction': release,
        'tissue_midpoint_ppm': _round(tissue['midpoint_ppm'] as double, 6),
        'crop_requirement_kg_per_ha': _round(cropMid, 6),
        'available_g_per_kg_fresh': _round(available, amountDecimals),
        'required_kg': _round(requiredG / 1000.0, amountDecimals),
        'fresh_plant_material_kg': freshKg == null
            ? null
            : _round(freshKg, amountDecimals),
        'fresh_plant_material_kg_per_m2': freshKg == null || areaM2 == 0
            ? null
            : _round(freshKg / areaM2, amountDecimals),
        'coverage_fraction': null,
        'coverage_percent': null,
        'shortfall_fresh_plant_material_kg': null,
        'shortfall_nutrient_kg': null,
        'top_up_source': null,
        'top_up_note': null,
      };
    }

    String? sizing;
    double? sizingKg;
    for (final entry in nutrients.entries) {
      final body = entry.value as Map<String, dynamic>;
      if (body['computable'] != true) continue;
      final kg = body['fresh_plant_material_kg'] as double;
      if (sizingKg == null || kg < sizingKg) {
        sizing = entry.key;
        sizingKg = kg;
      }
    }

    final coverage = <String, double?>{};
    final topUpNotes = <String>[];
    for (final entry in nutrients.entries) {
      final short = entry.key;
      final body = entry.value as Map<String, dynamic>;
      final needed = body['fresh_plant_material_kg'] as double?;
      if (sizingKg == null || needed == null || needed <= 0) {
        body['coverage_fraction'] = null;
        body['coverage_percent'] = null;
        body['shortfall_fresh_plant_material_kg'] = null;
        body['shortfall_nutrient_kg'] = null;
        body['top_up_source'] = null;
        body['top_up_note'] = null;
        coverage[short] = null;
        continue;
      }
      final fraction = math.min(sizingKg / needed, 1.0);
      body['coverage_fraction'] = _round(fraction, 6);
      body['coverage_percent'] = _round(fraction * 100.0, 3);
      coverage[short] = body['coverage_fraction'] as double;
      if (fraction < 1.0) {
        final shortfall = needed - sizingKg;
        body['shortfall_fresh_plant_material_kg'] = _round(
          shortfall,
          amountDecimals,
        );
        final available = body['available_g_per_kg_fresh'] as double?;
        final requiredKg = body['required_kg'] as double?;
        final suppliedKg = available == null
            ? null
            : _round(sizingKg * available / 1000.0, amountDecimals);
        final shortfallNutrientKg = requiredKg != null && suppliedKg != null
            ? _round(math.max(requiredKg - suppliedKg, 0.0), amountDecimals)
            : null;
        body['shortfall_nutrient_kg'] = shortfallNutrientKg;
        final source = _topUpSource(short, profile, selections);
        body['top_up_source'] = source;
        var sourceLabel = '';
        if (source != null) {
          if (source['kind'] == 'plant') {
            sourceLabel =
                " a different source such as ${source['common_name']} (derived #${source['derived_rank']} for ${_nutrients[short]})";
          } else {
            sourceLabel =
                " the ${source['recipe_abbrev']} booster (${source['recipe_name']})";
          }
        }
        final note =
            '${_nutrientLabels[short]} coverage is '
            '${_pyG(_round(fraction * 100.0, 1))}% of the target; about '
            '${_pyG(shortfallNutrientKg ?? 0.0)} kg ${_nutrients[short]} is still needed '
            'for the area. Top up from${sourceLabel.isEmpty ? ' a different source' : sourceLabel}, '
            'not more of the same plant.';
        body['top_up_note'] = note;
        topUpNotes.add(note);
      } else {
        body['shortfall_fresh_plant_material_kg'] = 0.0;
        body['shortfall_nutrient_kg'] = 0.0;
        body['top_up_source'] = null;
        body['top_up_note'] = null;
      }
    }

    final methods = _buildNutritionMethods(sizingKg, areaM2, amountDecimals);
    return {
      'target_fraction': _round(targetFraction, 6),
      'basis':
          ('no-overshoot: fresh plant material is sized to the nutrient that needs the least '
          "material, so no nutrient exceeds the stated fraction of the crop's seasonal N, P "
          "and K requirement; each nutrient's coverage is reported"),
      'sizing_nutrient': sizing,
      'sizing_fresh_plant_material_kg': sizingKg == null
          ? null
          : _round(sizingKg, amountDecimals),
      'sizing_fresh_plant_material_kg_per_m2': sizingKg == null || areaM2 == 0
          ? null
          : _round(sizingKg / areaM2, amountDecimals),
      'coverage': coverage,
      'top_up_notes': topUpNotes,
      'nutrients': nutrients,
      'methods': methods,
      'assumptions': [
        'Fresh plant material is computed per nutrient from the crop requirement midpoint, the candidate tissue midpoint, the tissue part\'s dry-matter fraction and the nutrient\'s release fraction.',
        'The no-overshoot rule sizes the single applied mass to the nutrient that needs the least material, so the target fraction is never exceeded.',
        'Each nutrient\'s coverage of the target at that mass is reported; a shortfall carries a plain top-up note and is not covered by this single application.',
        'The nutrition track covers the crop requirement only if the dry-matter and release fractions are correct; it does not account for soil supply or losses.',
      ],
    };
  }

  Map<String, dynamic>? _topUpSource(
    String nutrient,
    Map<String, dynamic> profile,
    List<Map<String, dynamic>> selections,
  ) {
    final abbrev = _topUpRecipe[nutrient];
    if (abbrev != null) {
      final derived = _derivedEntries(abbrev);
      if (derived.approved) {
        final current = <String>{
          if (_normalize(_text(profile, 'common_name')).isNotEmpty)
            _normalize(_text(profile, 'common_name')),
          if (_normalize(_text(profile, 'scientific_name')).isNotEmpty)
            _normalize(_text(profile, 'scientific_name')),
        };
        for (final entry in derived.entries) {
          final names = <String>{
            if (_normalize(entry['common_name'] as String? ?? '').isNotEmpty)
              _normalize(entry['common_name'] as String? ?? ''),
            if (_normalize(
              entry['scientific_name'] as String? ?? '',
            ).isNotEmpty)
              _normalize(entry['scientific_name'] as String? ?? ''),
          };
          if (names.intersection(current).isNotEmpty) continue;
          return {
            'kind': 'plant',
            'common_name': entry['common_name'],
            'scientific_name': entry['scientific_name'],
            'part': entry['part'],
            'derived_rank': entry['rank'],
            'for_nutrient': _nutrients[nutrient],
            'recipe_abbrev': abbrev,
          };
        }
      }
    }
    for (final selection in selections) {
      if (selection['target_nutrient'] == nutrient) {
        return {
          'kind': 'recipe',
          'recipe_abbrev': selection['recipe_abbrev'],
          'recipe_name': selection['recipe_name'],
          'for_nutrient': _nutrients[nutrient],
        };
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _buildNutritionMethods(
    double? sizingKg,
    double areaM2,
    int amountDecimals,
  ) {
    if (sizingKg == null) return [];
    final methods = <Map<String, dynamic>>[];
    final kg = _round(sizingKg, amountDecimals);
    methods.add({
      'method': 'chop_and_drop',
      'label': 'Chop-and-drop',
      'fresh_plant_material_kg': kg,
      'steps': [
        'Cut the fresh candidate plant material (leaf, herb, shoot or the tissue named above).',
        'Scatter the chopped material on the soil surface around the crop.',
        'Leave it on the surface as a mulch layer; do not bury it.',
      ],
      'sources': [
        {
          'corpus_file':
              'Organic_Farming/Fabulous Food from Every Small Garden.md',
          'line': 2229,
          'quote':
              'chop up or mow over the plant you removed and either put it in the compost bin or spread it as mulch',
        },
        {
          'corpus_file':
              'Organic_Farming/Gaia_s Garden - A Guide to Home-Scale Permaculture.md',
          'line': 308,
          'quote':
              'I slash their leaves periodically and leave them on the ground to create a mulch layer',
        },
      ],
    });

    final constants = _constants['constants'] as Map<String, dynamic>;
    final mulchDepth = _constantValue('mulch_depth_cm');
    final mulchSource =
        constants['mulch_depth_cm']['source'] as Map<String, dynamic>;
    final steepLPerKg = _constantValue('plant_tea_steep_water_l_per_kg');
    final steepSource =
        constants['plant_tea_steep_water_l_per_kg']['source']
            as Map<String, dynamic>;
    final impliedDepthCm = areaM2 == 0
        ? 0.0
        : (sizingKg / areaM2) * steepLPerKg * 0.1;
    methods.add({
      'method': 'mulch',
      'label': 'Surface mulch',
      'fresh_plant_material_kg': kg,
      'mulch_depth_cm': _round(mulchDepth, amountDecimals),
      'max_depth_cm': _round(mulchDepth, amountDecimals),
      'implied_depth_cm': _round(impliedDepthCm, amountDecimals),
      'fits_standard_depth': impliedDepthCm <= mulchDepth,
      'depth_basis':
          ("the fresh material's loose volume is approximated with the approved plant-tea "
          'water-to-material convention (10 L water per kg material), an upper bound on the '
          'material volume'),
      'steps': [
        'Chop or roughly shred the fresh candidate plant material.',
        'Spread it as a surface mulch about ${_pyG(mulchDepth)} cm deep.',
        'Keep the material clear of crop stems to avoid heating or rot at the stem.',
      ],
      'sources': [
        {
          'corpus_file': mulchSource['corpus_file'],
          'line': mulchSource['line'],
          'quote': mulchSource['quote'],
        },
        {
          'corpus_file': steepSource['corpus_file'],
          'line': steepSource['line'],
          'quote': steepSource['quote'],
        },
      ],
    });

    final dilution = _constantValue('plant_tea_dilution_ratio');
    final standardRate = _constantValue('plant_tea_application_rate_l_per_m2');
    final steepWaterL = sizingKg * steepLPerKg;
    final concentrateL = steepWaterL;
    final dilutionWaterL = concentrateL * dilution;
    final dilutedVolumeL = concentrateL + dilutionWaterL;
    final rateLPerM2 = areaM2 == 0 ? 0.0 : dilutedVolumeL / areaM2;
    final dilutionSource =
        constants['plant_tea_dilution_ratio']['source'] as Map<String, dynamic>;
    final rateSource =
        constants['plant_tea_application_rate_l_per_m2']['source']
            as Map<String, dynamic>;
    methods.add({
      'method': 'plant_tea',
      'label': 'Plant tea',
      'fresh_plant_material_kg': kg,
      'steep_water_l': _round(steepWaterL, amountDecimals),
      'concentrate_l': _round(concentrateL, amountDecimals),
      'dilution_ratio': '1:${_pyG(dilution)}',
      'dilution_water_l': _round(dilutionWaterL, amountDecimals),
      'diluted_volume_l': _round(dilutedVolumeL, amountDecimals),
      'rate_l_per_m2': _round(rateLPerM2, amountDecimals),
      'standard_rate_l_per_m2': _round(standardRate, amountDecimals),
      'standard_rate_source':
          '${rateSource['corpus_file']}:${rateSource['line']} (${rateSource['quote']})',
      'fits_standard_rate': rateLPerM2 <= standardRate,
      'steps': [
        'Chop the fresh candidate plant material and put it in a watertight container.',
        'Cover the material with water and steep/ferment it; strain the liquid as the tea concentrate.',
        'Dilute the strained concentrate 1:${_pyG(dilution)} with water before use.',
        'Apply the diluted tea to the soil or as a foliar feed, then use the residue as mulch.',
      ],
      'sources': [
        {
          'corpus_file': steepSource['corpus_file'],
          'line': steepSource['line'],
          'quote': steepSource['quote'],
        },
        {
          'corpus_file': dilutionSource['corpus_file'],
          'line': dilutionSource['line'],
          'quote': dilutionSource['quote'],
        },
        {
          'corpus_file': rateSource['corpus_file'],
          'line': rateSource['line'],
          'quote': rateSource['quote'],
        },
      ],
    });
    return methods;
  }

  // ---------------------------------------------------------------------
  // Booster track
  // ---------------------------------------------------------------------

  Map<String, dynamic> _buildBoosterRecipe(
    Map<String, dynamic> selection,
    Map<String, dynamic> profile,
    Map<String, double> cropMidpoints,
    double areaM2,
  ) {
    final amountDecimals = _constantValue('amount_rounding_decimals').toInt();
    final targetNutrient = selection['target_nutrient'] as String;
    final targetMineral = selection['target_mineral'] as String;

    Map<String, dynamic>? tissue;
    final namedMatch = selection['named_match'];
    final namedPart = namedMatch is Map<String, dynamic>
        ? namedMatch['part']
        : null;
    if (namedPart is String) {
      tissue = _tissueFromPart(profile, namedPart, targetMineral);
    }
    tissue ??= _bestTissue(profile, targetMineral);

    final source =
        _sourceRecipe(selection['recipe_abbrev'] as String) ?? const {};
    final dilutionRatios =
        (source['dilution_ratio'] as Map<String, dynamic>?) ?? const {};
    final template = {
      'dilution_ratios': {
        for (final entry in dilutionRatios.entries)
          entry.key: entry.value.toString(),
      },
      'ingredients': [
        for (final item in (source['ingredients'] as List?) ?? const [])
          item.toString(),
      ],
      'steps': [
        for (
          var index = 0;
          index < ((source['steps'] as List?) ?? const []).length;
          index++
        )
          {
            'order': index + 1,
            'text': (source['steps'] as List)[index].toString(),
          },
      ],
      'source': {
        'file': 'Enriched_Recipes.json',
        'sha256': _appDataSha256['Enriched_Recipes.json'],
        'recipe_abbrev': selection['recipe_abbrev'],
      },
    };
    final adaptation = {
      'adapted': selection['recipe_abbrev'] == 'WSP',
      'substitutions': selection['recipe_abbrev'] == 'WSP'
          ? [
              {
                'source_input': 'bones (fish or animal)',
                'v1_input': 'candidate plant material',
              },
            ]
          : <dynamic>[],
      'note': selection['recipe_abbrev'] == 'WSP'
          ? ("WSP's source inputs are bones plus vinegar. v2 substitutes the candidate "
                'plant material for the bones and keeps the vinegar extraction; this is a '
                'derived-proposed adaptation, not a source recipe.')
          : null,
    };

    final base = <String, dynamic>{
      'recipe_abbrev': selection['recipe_abbrev'],
      'recipe_name': selection['recipe_name'],
      'target_nutrient': targetNutrient,
      'target_mineral': targetMineral,
      'selection': selection['selection'],
      'selection_note': selection['selection_note'],
      'derived_rank': selection['derived_rank'],
      'tissue': tissue,
      'template': template,
      'template_adaptation': adaptation,
    };

    if (tissue == null) {
      base.addAll({
        'computable': false,
        'not_computable_reason':
            'catalog profile has no complete $targetMineral tissue value '
            '(both min and max are required)',
        'standard_batch': null,
        'dilutions': <dynamic>[],
        'application': null,
        'ingredients': <dynamic>[],
        'assumptions': _recipeAssumptions(selection, null, adaptation),
      });
      return base;
    }

    final cropMidpoint = cropMidpoints[targetNutrient];
    if (cropMidpoint == null || cropMidpoint <= 0) {
      base.addAll({
        'computable': false,
        'not_computable_reason':
            'crop has no parseable $targetNutrient requirement',
        'standard_batch': null,
        'dilutions': <dynamic>[],
        'application': null,
        'ingredients': <dynamic>[],
        'assumptions': _recipeAssumptions(selection, tissue, adaptation),
      });
      return base;
    }

    final dm = _dryMatterForPart(tissue['part'] as String);
    final release = _releaseForNutrient(targetNutrient);
    final sugarRatio = _constantValue('sugar_to_plant_material_ratio');
    final vinegarRatio = _constantValue('vinegar_to_material_ratio');
    final isWsp = selection['recipe_abbrev'] == 'WSP';
    final availableGPerKgFresh =
        (tissue['midpoint_ppm'] as double) / 1000.0 * dm.value * release;
    final requiredG = cropMidpoint * 0.1 * areaM2;
    final plantMassFactor = isWsp ? (1.0 + vinegarRatio) : (1.0 + sugarRatio);
    final extractantName = isWsp
        ? 'Vinegar (brown rice vinegar)'
        : 'Brown sugar';
    final extractantUnit = isWsp ? 'L' : 'kg';
    final extractantRatio = isWsp ? vinegarRatio : sugarRatio;
    final extractantRole = isWsp ? 'extractant' : 'sugar';

    final standardBatch = {
      'basis':
          ("recipe template standard batch: 1 kg fresh plant material with the "
          "recipe's extractant at the template ratio; scale to the batch you make"),
      'plant_material_fresh_kg': _round(1.0, amountDecimals),
      'plant_to_extractant_ratio': _round(extractantRatio, amountDecimals),
      'sugar_or_extractant': {
        'name': extractantName,
        'amount': _round(extractantRatio, amountDecimals),
        'unit': extractantUnit,
        'role': extractantRole,
      },
    };

    Map<String, dynamic>? primary;
    Map<String, dynamic>? application;
    Map<String, dynamic>? applicationBatch;
    double? primaryRatio;
    double? primaryStandardRate;
    for (final method in const ['foliar', 'soil_drench']) {
      if (!dilutionRatios.containsKey(method)) continue;
      final ratio = _parseDilutionRatio(dilutionRatios[method]);
      final rate = _applicationRate(method);
      if (ratio == null || rate == null) continue;
      primary = {
        'method': method,
        'ratio': dilutionRatios[method].toString(),
        'ratio_parts_water_per_concentrate': _round(ratio, amountDecimals),
      };
      applicationBatch = _buildApplicationBatch(
        areaM2,
        ratio,
        rate.rate,
        plantMassFactor,
        availableGPerKgFresh,
        requiredG,
        amountDecimals,
      );
      primaryRatio = ratio;
      primaryStandardRate = rate.rate;
      break;
    }

    if (primary == null || applicationBatch == null) {
      base.addAll({
        'computable': false,
        'not_computable_reason':
            'recipe has no parseable dilution ratio or standard application rate',
        'standard_batch': null,
        'dilutions': <dynamic>[],
        'application': null,
        'ingredients': <dynamic>[],
        'assumptions': _recipeAssumptions(selection, tissue, adaptation),
      });
      return base;
    }

    final concentrateL = primaryStandardRate != null && primaryRatio != null
        ? areaM2 * primaryStandardRate / (1.0 + primaryRatio)
        : applicationBatch['concentrate_l'] as double;
    final dilutions = _buildDilutions(
      concentrateL,
      areaM2,
      dilutionRatios,
      amountDecimals,
    );
    Map<String, dynamic>? primaryDilution;
    for (final dilution in dilutions) {
      if (dilution['method'] == primary['method']) {
        primaryDilution = dilution;
        break;
      }
    }
    if (primaryDilution != null) {
      application = {
        'method': primaryDilution['method'],
        'ratio': primaryDilution['ratio'],
        'ratio_parts_water_per_concentrate': _round(
          primaryRatio ?? 0.0,
          amountDecimals,
        ),
        'area_m2': _round(areaM2, amountDecimals),
        'concentrate_l': applicationBatch['concentrate_l'],
        'concentrate_ml': applicationBatch['concentrate_ml'],
        'concentrate_mass_kg': applicationBatch['concentrate_mass_kg'],
        'diluted_volume_l': primaryDilution['diluted_volume_l'],
        'rate_l_per_m2': primaryDilution['rate_l_per_m2'],
        'standard_rate_l_per_m2': primaryDilution['standard_rate_l_per_m2'],
        'standard_rate_source': primaryDilution['standard_rate_source'],
        'multiple_of_standard': primaryDilution['multiple_of_standard'],
        'fits_standard_rate': primaryDilution['fits_standard_rate'],
        'plant_material_fresh_kg': applicationBatch['plant_material_fresh_kg'],
        'nutrient_supplied_kg': applicationBatch['nutrient_supplied_kg'],
        'fraction_of_requirement': applicationBatch['fraction_of_requirement'],
        'delivers_requirement': applicationBatch['delivers_requirement'],
      };
    }

    final ingredients = [
      {
        'name':
            '${(_text(profile, 'common_name').isNotEmpty ? _text(profile, 'common_name') : _text(profile, 'scientific_name'))} (fresh ${tissue['part']})',
        'amount': _round(1.0, amountDecimals),
        'unit': 'kg',
        'role': 'plant_material',
      },
      {
        'name': extractantName,
        'amount': _round(extractantRatio, amountDecimals),
        'unit': extractantUnit,
        'role': extractantRole,
      },
    ];

    base.addAll({
      'computable': true,
      'not_computable_reason': null,
      'tissue_detail': {
        'dry_matter_fraction': dm.value,
        'part_category': dm.category,
        'dry_matter_fallback': dm.fallback,
        'release_fraction': release,
      },
      'standard_batch': standardBatch,
      'dilutions': dilutions,
      'application': application,
      'ingredients': ingredients,
      'assumptions': _recipeAssumptions(selection, tissue, adaptation),
    });
    return base;
  }

  Map<String, dynamic> _buildApplicationBatch(
    double areaM2,
    double ratio,
    double standardRateLPerM2,
    double plantMassFactor,
    double availableGPerKgFresh,
    double targetG,
    int amountDecimals,
  ) {
    final dilutedVolumeL = areaM2 * standardRateLPerM2;
    final concentrateL = dilutedVolumeL / (1.0 + ratio);
    final density = _constantValue('ferment_density_kg_per_l');
    final concentrateMassKg = concentrateL * density;
    final plantKg = plantMassFactor != 0
        ? concentrateMassKg / plantMassFactor
        : 0.0;
    final nutrientKg = plantKg * availableGPerKgFresh / 1000.0;
    final fraction = targetG != 0 ? nutrientKg / (targetG / 1000.0) : 0.0;
    return {
      'diluted_volume_l': _round(dilutedVolumeL, amountDecimals),
      'concentrate_l': _round(concentrateL, amountDecimals),
      'concentrate_ml': _round(concentrateL * 1000.0, amountDecimals),
      'concentrate_mass_kg': _round(concentrateMassKg, amountDecimals),
      'plant_material_fresh_kg': _round(plantKg, amountDecimals),
      'nutrient_supplied_kg': _round(nutrientKg, 9),
      'fraction_of_requirement': _round(fraction, 9),
      'delivers_requirement': false,
    };
  }

  List<Map<String, dynamic>> _buildDilutions(
    double concentrateL,
    double areaM2,
    Map<String, dynamic> dilutionRatios,
    int amountDecimals,
  ) {
    final dilutions = <Map<String, dynamic>>[];
    for (final entry in dilutionRatios.entries) {
      final ratio = _parseDilutionRatio(entry.value);
      if (ratio == null) continue;
      final rate = _applicationRate(entry.key);
      if (rate == null) continue;
      final waterL = concentrateL * ratio;
      final dilutedVolumeL = concentrateL + waterL;
      final rateLPerM2 = areaM2 != 0 ? dilutedVolumeL / areaM2 : 0.0;
      final multiple = rate.rate != 0 ? rateLPerM2 / rate.rate : 0.0;
      dilutions.add({
        'method': entry.key,
        'ratio': entry.value.toString(),
        'ratio_parts_water_per_concentrate': _round(ratio, amountDecimals),
        'water_l': _round(waterL, amountDecimals),
        'diluted_volume_l': _round(dilutedVolumeL, amountDecimals),
        'rate_l_per_m2': _round(rateLPerM2, amountDecimals),
        'standard_rate_l_per_m2': _round(rate.rate, amountDecimals),
        'standard_rate_source': rate.source,
        'multiple_of_standard': _round(multiple, amountDecimals),
        'fits_standard_rate': rateLPerM2 <= rate.rate,
      });
    }
    return dilutions;
  }

  List<String> _recipeAssumptions(
    Map<String, dynamic> selection,
    Map<String, dynamic>? tissue,
    Map<String, dynamic> adaptation,
  ) {
    final notes = <String>[
      "Template: ${selection['recipe_name']} from Enriched_Recipes.json.",
      "Selection: ${selection['selection_note']}.",
    ];
    if (tissue != null) {
      notes.add(
        'Tissue: ${tissue['part']} midpoint ${_pyFloatStr(tissue['midpoint_ppm'] as double)} ppm '
        '(min ${_pyFloatStr(tissue['min_ppm'] as double)}, max ${_pyFloatStr(tissue['max_ppm'] as double)}) on a dry-matter basis.',
      );
    }
    notes.add(
      "Booster only: this is the recipe's standard batch at its standard dilution and "
      'application rate, without a requirement-coverage claim.',
    );
    if (adaptation['adapted'] == true) {
      notes.add(
        (adaptation['note'] as String?) ??
            'The source template was adapted for v2.',
      );
    }
    return notes;
  }

  // ---------------------------------------------------------------------
  // Assumptions block
  // ---------------------------------------------------------------------

  Map<String, dynamic> _assumptions() {
    final proposal = _derivationProposal;
    final trigger = _triggerProposal;
    final proposalSignoff =
        (proposal['owner_signoff'] as Map<String, dynamic>?) ?? const {};
    final triggerSignoff =
        (trigger['owner_signoff'] as Map<String, dynamic>?) ?? const {};
    return {
      'schema_version': assumptionsVersion,
      'owner_signoff': {
        'mappings': {
          'status': proposal['status'],
          'date': proposalSignoff['date'],
          'source': 'Chainlink issue #56 owner decisions comment',
          'file': 'data/recipe_mapping_derivations_proposal_v1.json',
        },
        'trigger_template': {
          'status': trigger['status'],
          'date': triggerSignoff['date'],
          'file': 'data/recipe_tool_trigger_template_proposal_v1.json',
        },
        'dosing_constants': {
          'status': _constants['status'],
          'date':
              (_constants['owner_signoff'] as Map<String, dynamic>?)?['date'],
          'file': 'data/recipe_tool_dosing_constants_proposal_v2.json',
        },
        'json_schemas': {
          'status': 'defined',
          'files': [
            'schemas/recipe_tool_input_v2.schema.json',
            'schemas/recipe_tool_output_v2.schema.json',
          ],
        },
      },
      'nutrient_scope': {
        'computed': ['N', 'P', 'K'],
        'nitrogen':
            ("N is included by the 2026-10-17 owner decision; the old "
            "'nitrogen is never comparable' rule is replaced by these assumptions."),
        'calcium':
            'Ca is out of scope for v2 because Crop_Requirements.json has no crop Ca requirement; WCA is not computable.',
        'not_computed': ['Ca'],
      },
      'crop_requirement': {
        'file': 'Crop_Requirements.json',
        'sha256': _appDataSha256['Crop_Requirements.json'],
        'unit': 'kg/ha',
        'unit_note':
            ('kg/ha is CONFIRMED by the owner (2026-10-18); the file does not state a unit, '
            'but the values and the corpus convention are kg/ha.'),
        'midpoint': 'arithmetic mean of the declared range',
        'basis':
            'full seasonal crop requirement, not a deficit after soil supply',
      },
      'tissue_basis': {
        'file': 'plant_mineral_profiles.json',
        'sha256': _appDataSha256['plant_mineral_profiles.json'],
        'unit': 'ppm = mg/kg',
        'basis': 'dry matter',
        'selection':
            "highest complete min/max midpoint among the profile's parts for each nutrient; a recipe-named part is preferred for that recipe's target nutrient when it has complete data",
        'incomplete_values': 'a value with only min or only max is ignored',
      },
      'dosing_constants': _constantSummary(),
      'track_model': _trackAssumptions(),
      'candidate_policy': {
        'status': proposal['status'],
        'date': proposalSignoff['date'],
        'order':
            'each recipe offers its recipe-named plants first, then the top catalog plants by tissue content for the recipe\'s nutrient',
        'derived_label': 'derived',
        'derived_limit': 10,
      },
      'mapping_decisions': [
        {
          'item': 'Trifolium repens (Clover)',
          'decision':
              'accepted as Red Clover (Trifolium pratense), the only clover profile in the catalog',
          'status': 'approved_by_owner',
          'date': '2026-10-17',
          'caveat':
              'species proxy: the recipe names white clover, the profile is red clover',
        },
        {
          'item': 'Citrus peel',
          'decision': 'the user picks from the eight citrus profiles',
          'status': 'approved_by_owner',
          'date': '2026-10-17',
          'scope':
              'AIA only; AIA has no N/P/K target and is not computed in v2',
        },
        {
          'item': 'Angelica archangelica',
          'decision':
              'use the closest of the three Angelica profiles; v2 records Angelica dahurica as closest by scientific-name similarity',
          'status': 'approved_by_owner',
          'date': '2026-10-17',
          'scope':
              'OHN only; OHN has no N/P/K target and is not computed in v2',
        },
        {
          'item': 'nutrient scope',
          'decision': 'compute N, P and K; keep Ca out of v2',
          'status': 'approved_by_owner',
          'date': '2026-10-17',
        },
        {
          'item': 'trigger template',
          'decision':
              "approved as proposed: 'Bioaccumulator recipe: <candidate plant> for my <crop>, <area> m2' with m2 aliases and other units rejected as unsupported_unit",
          'status': 'approved_by_owner',
          'date': '2026-10-17',
        },
        {
          'item': 'two tracks',
          'decision':
              'replace the full-requirement ferment dose with a nutrition track (chop-and-drop/mulch/plant tea) and a booster track (standard FPJ/FFJ/WSP batch, no coverage claim)',
          'status': 'approved_by_owner',
          'date': '2026-10-17',
        },
        {
          'item': 'WSP plant substitution',
          'decision':
              'keep WSP with the candidate plant substituted for the bones, flagged in template_adaptation and warnings',
          'status': 'approved_by_owner',
          'date': '2026-10-17',
        },
        {
          'item': 'no-overshoot dose rule',
          'decision':
              ('size the nutrition-track fresh material to the nutrient that needs the least '
              'material (sizing_nutrient) so no nutrient exceeds the target fraction, report '
              "each nutrient's coverage and a top-up note for the shortfalls, and warn when "
              'the amount exceeds the sourced mulch depth or tea application constraint'),
          'status': 'approved_by_owner',
          'date': '2026-10-18',
        },
        {
          'item': 'dosing constants',
          'decision':
              ('approved as in data/recipe_tool_dosing_constants_proposal_v2.json; the crop '
              'requirement unit kg/ha is confirmed by the owner'),
          'status': 'approved_by_owner',
          'date': '2026-10-18',
        },
      ],
      'recipe_scope': {
        'computed_templates': ['FPJ (N)', 'FFJ (K)', 'WSP (P)'],
        'excluded': {
          'FAA':
              'fish is the main material; the named plants are additives, so scaling a plant as FAA would invent a recipe',
          'OHN': 'alcohol extract; micronutrient target, not N/P/K',
          'WCA':
              'calcium is out of scope and there is no crop-side Ca requirement',
          'IMO': 'soil-biology target, not a single mineral',
          'IMO-3': 'soil-biology target, not a single mineral',
          'LABS': 'soil-biology target, not a single mineral',
          'BRV': 'pH-buffer target, not a single mineral',
          'SES': 'recipe-product mixture, not a plant material',
          'FMC': 'mixed compost, not a single plant material',
          'AIA': 'insect attractant, no N/P/K target',
          'Wildcrafted':
              'variable target; its per-nutrient lists duplicate the FPJ/FFJ/WSP derived candidates',
        },
      },
      'interpretation': {
        'nutrition_track':
            'The nutrition track is a nutrient-equivalence mass: the stated fresh material, spread as chop-and-drop or mulch or brewed as plant tea, would supply the target fraction of the crop\'s seasonal N/P/K requirement if the dry-matter and release fractions are correct. The mass is sized by the no-overshoot rule to the nutrient that needs the least, so the target is never exceeded and the other nutrients reach only the stated coverage.',
        'booster_track':
            'The booster track is the source recipe at its normal strength. It is a small, convenient input, not a way to cover the crop requirement on the stated area.',
        'not_a_prescription':
            "The old 'relative signal, not a dose' caveat is replaced by these explicit assumptions. The output is an assumption-bound calculation, not a fertilizer recommendation or a substitute for soil testing.",
      },
      'limitations': [
        'Dry matter is per plant part but every value is a corpus point estimate; bark uses a wood-moisture proxy and flower uses whole-plant water content.',
        'P release uses a plant-uptake efficiency (less than 20%) as a conservative proxy because the corpus has no direct residue-P release measurement.',
        "K release of 0.80 follows 'most of the potassium is leached' rather than a measured fraction.",
        'The plant-tea steep ratio (10 L water per kg fresh material) is a method convention; only the 1:10 finished-tea dilution and the application rate are corpus-sourced.',
        'The ferment density is a water-density unit convention, not a measured extract density.',
        'The model does not account for soil nutrient supply, leaching, volatilization, fixation, plant uptake efficiency, or nutrient interactions.',
        "WSP uses the source recipe's bone/vinegar steps; the candidate plant material is a derived substitution, not a source recipe.",
        'The crop requirement unit (kg/ha) is confirmed by the owner (2026-10-18) even though Crop_Requirements.json does not state it.',
        'The no-overshoot sizing keeps the target fraction from being exceeded, so nutrients that are not the sizing nutrient are deliberately under-supplied; their coverage and top-up note are reported.',
        "The implied mulch depth approximates the fresh material's loose volume with the approved plant-tea water-to-material convention (10 L water per kg material), an upper bound on the material volume, so the depth check is conservative.",
      ],
    };
  }

  Map<String, dynamic> _constantSummary() {
    final summary = <String, dynamic>{};
    final constants = _constants['constants'] as Map<String, dynamic>;
    for (final entry in constants.entries) {
      final body = entry.value as Map<String, dynamic>;
      final source = (body['source'] as Map<String, dynamic>?) ?? const {};
      summary[entry.key] = {
        'value': body['value'],
        'unit': body['unit'],
        'source': {
          'corpus_file': source['corpus_file'],
          'line': source['line'],
          'quote': source['quote'],
          'derivation': source['derivation'],
          'source_type': source['source_type'],
        },
        'caveat': body['caveat'],
        'owner_signoff': body['owner_signoff'] ?? 'pending',
      };
    }
    return summary;
  }

  Map<String, dynamic> _trackAssumptions() {
    final constants = _constants['constants'] as Map<String, dynamic>;
    final dm = constants['dry_matter_fraction'] as Map<String, dynamic>;
    final release =
        constants['nutrient_release_fraction'] as Map<String, dynamic>;
    final byNutrient = release['by_nutrient'] as Map<String, dynamic>;
    return {
      'nutrition':
          ('Fresh plant material is computed per nutrient from the crop requirement, the '
          "candidate tissue midpoint, the tissue part's dry-matter fraction and the "
          "nutrient's release fraction. The no-overshoot rule sizes the material to the "
          'nutrient that needs the least, so no nutrient exceeds the target fraction; each '
          "nutrient's resulting coverage is reported."),
      'booster':
          ("The booster is the source recipe's standard batch at its standard dilution and "
          'application rate. Its nutrient amount is reported for information only and does '
          'not claim to cover the crop requirement.'),
      'dry_matter':
          ("Dry matter is per plant part; the value's corpus source is recorded for each part. "
          "Unmapped parts fall back to the ${dm['default_category'] ?? 'herb'} category."),
      'release':
          ('Release/extraction is per nutrient (N, P, K); the residue-N recovery figure is not '
          'reused for P and K.'),
      'release_values': {
        'N': byNutrient['N']['value'],
        'P': byNutrient['P']['value'],
        'K': byNutrient['K']['value'],
      },
      'dose_rule':
          ('no overshoot: the single applied mass is the smallest per-nutrient requirement, '
          'so the target fraction is never exceeded; shortfalls are reported as coverage '
          'with a top-up note'),
    };
  }

  // ---------------------------------------------------------------------
  // Served view helpers
  // ---------------------------------------------------------------------

  Map<String, dynamic>? _servedMethod(Map<String, dynamic>? method) {
    if (method == null) return null;
    final served = <String, dynamic>{
      'name': method['method'],
      'label': method['label'],
      'fresh_material_kg': _significance(method['fresh_plant_material_kg']),
      'steps': List<String>.from(method['steps'] as List),
    };
    const definingKeys = [
      'mulch_depth_cm',
      'implied_depth_cm',
      'fits_standard_depth',
      'steep_water_l',
      'concentrate_l',
      'dilution_ratio',
      'diluted_volume_l',
      'rate_l_per_m2',
      'standard_rate_l_per_m2',
      'fits_standard_rate',
    ];
    for (final key in definingKeys) {
      if (method.containsKey(key)) served[key] = _significance(method[key]);
    }
    return served;
  }

  Map<String, dynamic>? _servedBooster(Map<String, dynamic>? recipe) {
    if (recipe == null) return null;
    final batch =
        (recipe['standard_batch'] as Map<String, dynamic>?) ?? const {};
    final dose = (recipe['application'] as Map<String, dynamic>?) ?? const {};
    final extractant = batch['sugar_or_extractant'] as Map<String, dynamic>?;
    return {
      'recipe_abbrev': recipe['recipe_abbrev'],
      'recipe_name': recipe['recipe_name'],
      'target_nutrient': recipe['target_nutrient'],
      'standard_batch': {
        'plant_material_fresh_kg': _significance(
          batch['plant_material_fresh_kg'],
        ),
        'plant_to_extractant_ratio': _significance(
          batch['plant_to_extractant_ratio'],
        ),
        'extractant': extractant == null
            ? null
            : {
                'name': extractant['name'],
                'amount': _significance(extractant['amount']),
                'unit': extractant['unit'],
              },
      },
      'application': {
        'method': dose['method'],
        'ratio': dose['ratio'],
        'concentrate_ml': _significance(dose['concentrate_ml']),
        'diluted_volume_l': _significance(dose['diluted_volume_l']),
        'rate_l_per_m2': _significance(dose['rate_l_per_m2']),
        'standard_rate_l_per_m2': _significance(dose['standard_rate_l_per_m2']),
      },
      'substitution':
          (recipe['template_adaptation'] as Map<String, dynamic>)['adapted'] ==
              true
          ? 'WSP substitutes the candidate plant material for the source bones (derived recipe).'
          : null,
    };
  }

  List<String> _servedTopUpNotes(Map<String, dynamic> nutrition) {
    final notes = <String>[];
    final nutrients = nutrition['nutrients'] as Map<String, dynamic>;
    for (final short in _nutrients.keys) {
      final body = nutrients[short] as Map<String, dynamic>;
      final percent = body['coverage_percent'] as num?;
      final shortfall = body['shortfall_nutrient_kg'] as num?;
      if (body['top_up_note'] == null ||
          percent == null ||
          shortfall == null ||
          shortfall == 0) {
        continue;
      }
      final source = body['top_up_source'] as Map<String, dynamic>?;
      String sourceLabel;
      if (source == null) {
        sourceLabel = 'another source';
      } else if (source['kind'] == 'plant') {
        sourceLabel =
            "${source['common_name']} (derived #${source['derived_rank']} for ${_nutrients[short]})";
      } else {
        sourceLabel = "the ${source['recipe_abbrev']} booster";
      }
      notes.add(
        '${_nutrientLabels[short]} coverage ${_pyG(_significance(percent).toDouble())}%; '
        '${_pyG(_significance(shortfall).toDouble())} kg ${_nutrients[short]} still needed for the area. '
        'Top up from a different source: $sourceLabel.',
      );
    }
    return notes;
  }

  List<String> _servedAssumptions(
    Map<String, dynamic> nutrition,
    Map<String, dynamic>? booster,
    List<String> nonComputableRecipes,
  ) {
    final notes = <String>[
      'Estimates from dry matter and nutrient release fractions, not a soil test.',
    ];
    if (((nutrition['top_up_notes'] as List?) ?? const []).isNotEmpty) {
      notes.add('No-overshoot sizing: the shortfall nutrients need a top up.');
    }
    if (booster != null) {
      notes.add('Booster is information only, not a coverage dose.');
    }
    if (booster != null && booster['substitution'] != null) {
      notes.add(
        'WSP substitutes the candidate plant material for the bones (derived recipe).',
      );
    }
    if (nonComputableRecipes.isNotEmpty) {
      notes.add(
        'No standard batch is computable for: ${nonComputableRecipes.join(', ')}.',
      );
    }
    return notes;
  }

  // ---------------------------------------------------------------------
  // Error and numeric helpers
  // ---------------------------------------------------------------------

  Map<String, dynamic> _error(
    Map<String, dynamic> input,
    String code,
    String message, [
    Map<String, dynamic>? details,
  ]) {
    return {
      'schema_version': schemaVersion,
      'status': 'error',
      'input': input,
      'error': {'code': code, 'message': message, 'details': details},
    };
  }

  void _ensureLoaded() {
    if (!_initialized) {
      throw StateError('RecipeToolService.initialize must be called first');
    }
  }

  static final RegExp _numberPattern = RegExp(r'\d+(?:\.\d+)?');
  static final RegExp _dilutionPattern = RegExp(r'1\s*:\s*(\d+(?:\.\d+)?)');

  (double, double)? _parseRange(dynamic value) {
    final numbers = _numberPattern
        .allMatches(value?.toString() ?? '')
        .map((match) => double.parse(match.group(0)!))
        .toList();
    if (numbers.isEmpty) return null;
    return (numbers.reduce(math.min), numbers.reduce(math.max));
  }

  double? _numeric(dynamic value) {
    if (value is! num) return null;
    final converted = value.toDouble();
    return converted.isFinite ? converted : null;
  }

  double? _parseDilutionRatio(dynamic value) {
    final text = (value?.toString() ?? '').trim();
    final match = _dilutionPattern.firstMatch(text);
    if (match == null) return null;
    final ratio = double.parse(match.group(1)!);
    return ratio.isFinite && ratio > 0 ? ratio : null;
  }

  static String _text(Map<String, dynamic> row, String key) {
    final value = row[key];
    return value is String ? value.trim() : '';
  }

  static String _trim(dynamic value) => value is String ? value.trim() : '';

  static String _normalize(dynamic value) {
    return (value?.toString() ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  static const Map<String, String> _appDataSha256 = {
    'Enriched_Recipes.json':
        'a09340679a7a184be12f7e1fb74b060e2ec9a3a066970092112a1e57d32c0514',
    'NF_Recipes.json':
        '21690722326bed97dd0e393355783bd217d1c4a58b8490619cf71f6bf609ae6a',
    'plant_mineral_profiles.json':
        'c97f9afa9956bebe3478dbd8bbcd4245dcf471a2f7d84c0cad80b696d09ef053',
    'Crop_Requirements.json':
        '5a85ec677eddf6ce9d7cef3d3edeb15ccd5395191b9c4c0ae849d42de6f89559',
  };
}

/// Compact, key-sorted JSON; byte-compatible with the MCP server's serializer.
String canonicalJson(dynamic value) => jsonEncode(_canonicalValue(value));

dynamic _canonicalValue(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalValue(value[key])};
  }
  if (value is List) return [for (final item in value) _canonicalValue(item)];
  return value;
}

/// Canonical tool arguments parsed from the fixed chat trigger.
class RecipeTrigger {
  final String candidatePlant;
  final String crop;
  final double quantity;
  final String unit;

  const RecipeTrigger({
    required this.candidatePlant,
    required this.crop,
    required this.quantity,
    required this.unit,
  });

  Map<String, dynamic> toArguments() => {
    'candidate_plant': candidatePlant,
    'crop': crop,
    'quantity': quantity,
    'unit': unit,
  };
}

/// A deterministic trigger parse failure carrying the oracle's error code.
class RecipeTriggerException implements Exception {
  final String code;
  final String message;

  RecipeTriggerException(this.code, this.message);

  @override
  String toString() => 'RecipeTriggerException($code): $message';
}

/// Round half away from zero, matching the oracle's Decimal ROUND_HALF_UP.
double _round(double value, int digits) {
  final result = _quantize(value, -digits);
  return result == 0 ? 0.0 : result;
}

/// Round a number to three significant figures, as the oracle does.
dynamic _significance(dynamic value) {
  if (value is! num) return value;
  final number = value.toDouble();
  if (number == 0.0 || !number.isFinite) return number;
  var exponent = (math.log(number.abs()) / math.ln10).floor();
  exponent = math.max(exponent, -(3 + 300));
  return _quantize(number, exponent - (3 - 1));
}

/// Decimal half-away-from-zero quantisation of [value] at 10^[exponent].
double _quantize(double value, int exponent) {
  if (value == 0.0 || !value.isFinite) return value;
  final parsed = _decimalParts(value);
  var digits = parsed.digits;
  final shift = parsed.exponent - exponent;
  if (shift >= 0) {
    final padded = digits + '0' * shift;
    return double.parse('${parsed.sign}${padded}e$exponent');
  }
  final keep = digits.length + shift;
  if (keep <= 0) {
    // The value is smaller than half a quantum unless the first dropped digit
    // is at or above 5 at exactly half of the quantum.
    final dropped = '0' * (-keep) + digits;
    final roundUp = dropped.isNotEmpty && dropped.codeUnitAt(0) >= 53;
    return roundUp ? double.parse('${parsed.sign}1e$exponent') : 0.0;
  }
  final kept = digits.substring(0, keep);
  final rest = digits.substring(keep);
  var roundUp = false;
  if (rest.isNotEmpty && rest.codeUnitAt(0) >= 53) {
    roundUp = true;
  }
  var integer = BigInt.parse(kept.isEmpty ? '0' : kept);
  if (roundUp) integer += BigInt.one;
  return double.parse('${parsed.sign}${integer}e$exponent');
}

({String sign, String digits, int exponent}) _decimalParts(double value) {
  var text = value.abs().toString();
  var exponent = 0;
  final eIndex = text.indexOf(RegExp('[eE]'));
  if (eIndex >= 0) {
    exponent = int.parse(text.substring(eIndex + 1));
    text = text.substring(0, eIndex);
  }
  final dot = text.indexOf('.');
  if (dot >= 0) {
    exponent -= text.length - dot - 1;
    text = text.substring(0, dot) + text.substring(dot + 1);
  }
  text = text.replaceFirst(RegExp(r'^0+'), '');
  if (text.isEmpty) text = '0';
  return (sign: value.isNegative ? '-' : '', digits: text, exponent: exponent);
}

/// Python `str(float)`-compatible shortest representation for interpolation.
///
/// Dart and Python both print the shortest round-trip digits, but choose
/// different fixed/scientific thresholds. Python uses scientific notation for
/// non-zero magnitudes below 1e-4 or at/above 1e16; this re-formats Dart's
/// digits to match exactly.
String _pyFloatStr(double value) {
  if (value.isNaN) return 'nan';
  if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';
  if (value == 0) return value.isNegative ? '-0.0' : '0.0';
  final parsed = _decimalParts(value);
  final digits = parsed.digits;
  final exponent = parsed.exponent;
  final scientificExponent = exponent + digits.length - 1;
  if (scientificExponent < -4 || scientificExponent >= 16) {
    final mantissa = digits.length == 1
        ? digits
        : '${digits[0]}.${digits.substring(1)}';
    final sign = scientificExponent < 0 ? '-' : '+';
    final magnitude = scientificExponent.abs().toString().padLeft(2, '0');
    return '${parsed.sign}${mantissa}e$sign$magnitude';
  }
  final point = digits.length + exponent;
  if (point <= 0) {
    return '${parsed.sign}0.${'0' * (-point)}$digits';
  }
  if (point >= digits.length) {
    return '${parsed.sign}$digits${'0' * (point - digits.length)}.0';
  }
  return '${parsed.sign}${digits.substring(0, point)}.${digits.substring(point)}';
}

/// Python `format(value, "g")` with the default six significant figures.
String _pyG(double value, {int precision = 6}) {
  if (value == 0) return '0';
  if (!value.isFinite) return _pyFloatStr(value);
  var exponent = (math.log(value.abs()) / math.ln10).floor();
  final rounded = _quantize(value, exponent - (precision - 1));
  exponent = (math.log(rounded.abs()) / math.ln10).floor();
  if (exponent < -4 || exponent >= precision) {
    final text = rounded.toStringAsExponential(precision - 1);
    final parts = text.split('e');
    var mantissa = parts[0];
    if (mantissa.contains('.')) {
      mantissa = mantissa.replaceFirst(RegExp(r'0+$'), '');
      mantissa = mantissa.replaceFirst(RegExp(r'\.$'), '');
    }
    final exp = int.parse(parts[1]);
    final sign = exp < 0 ? '-' : '+';
    final magnitude = exp.abs().toString().padLeft(2, '0');
    return '${mantissa}e$sign$magnitude';
  }
  final decimals = math.max(precision - 1 - exponent, 0);
  var text = rounded.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}
