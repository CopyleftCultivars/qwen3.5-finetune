import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'plant_lookup_service.dart';

/// Compares a crop's NPK requirement (Phosphorus/Potassium only) against a
/// candidate bioaccumulator plant's tissue mineral content.
///
/// On-device Dart port of `rlm_slice/domain_tools.py`'s `bioaccumulator_ratio`
/// (chainlink #174/#177), backed by `Crop_Requirements.json` (new asset,
/// copied from the GPU repo's `crop_requirements.json`) and the already-
/// bundled `plant_mineral_profiles.json` via [PlantLookupService].
class BioaccumulatorRatioService {
  final PlantLookupService _plantLookupService;

  List<Map<String, dynamic>> _crops = [];
  bool _isInitialized = false;

  static const String _assetPath = 'assets/plant_data/Crop_Requirements.json';

  /// plant_mineral_profiles.json tracks trace minerals (P, K, Ca, Fe, ...)
  /// per USDA composition data; it does not track nitrogen (N is protein-
  /// bound, not a "mineral" in that dataset's sense). So only P and K are
  /// ever comparable against Crop_Requirements.json's NPK Requirements --
  /// nitrogen is always reported as not-comparable, not silently dropped.
  static const Map<String, String> _nutrientMap = {
    'Phosphorus': 'phosphorus',
    'Potassium': 'potassium',
  };

  // No leading "-?": Crop_Requirements.json's NPK ranges are strings like
  // "30-70", where the hyphen is a range separator, not a sign. A leading
  // "-?" here misparses "30-70" as [30, -70] -- the exact bug found and
  // fixed on the GPU side (chainlink #175, rlm_slice/domain_tools.py's
  // `_RANGE_RE`). Do not reintroduce it here.
  static final RegExp _rangeRe = RegExp(r'\d+(?:\.\d+)?');

  BioaccumulatorRatioService({required PlantLookupService plantLookupService})
      : _plantLookupService = plantLookupService;

  bool get isInitialized => _isInitialized;
  int get cropCount => _crops.length;

  /// All known crop names, for vocabulary-based argument extraction
  /// (`ToolArgExtractor`, chainlink #177's on-device ladder harness) --
  /// mirrors `rlm_slice/multi_tool_context.py`'s `_crop_vocab()`.
  List<String> get cropNames => _crops
      .map((row) => row['Crop'] as String?)
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .toSet()
      .toList();

  /// Load crop NPK requirements from the bundled JSON asset.
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_isInitialized) return;

    onProgress?.call(0.0, 'Loading crop requirements database...');

    final jsonString = await rootBundle.loadString(_assetPath);
    final List<dynamic> rows = jsonDecode(jsonString);
    _crops = rows.cast<Map<String, dynamic>>();

    _isInitialized = true;
    onProgress?.call(1.0, 'Crop requirements database ready (${_crops.length} crops)');
  }

  /// Compare `crop`'s NPK requirement against `candidatePlant`'s tissue
  /// mineral content. Mirrors `bioaccumulator_ratio()` in domain_tools.py
  /// exactly: parse each range as (min, max), take the midpoint; for the
  /// plant, take the richest (max) mid-value across all `parts` for
  /// phosphorus and potassium; ratio = plant_mid / crop_mid.
  BioaccumulatorRatioResult compute(String crop, String candidatePlant) {
    if (!_isInitialized) {
      return BioaccumulatorRatioResult.error(
        'Crop requirements database not initialized',
      );
    }

    final cropRow = _findCrop(crop);
    if (cropRow == null) {
      return BioaccumulatorRatioResult.error(
        "no crop matching '$crop' in Crop_Requirements.json",
      );
    }

    final plantRow = _findPlant(candidatePlant);
    if (plantRow == null) {
      return BioaccumulatorRatioResult.error(
        "no plant matching '$candidatePlant' in plant_mineral_profiles.json",
      );
    }

    final npk = (cropRow['NPK Requirements'] as Map<String, dynamic>?) ?? {};
    final ratios = <String, double>{};
    final notComparable = <String>[];

    for (final entry in _nutrientMap.entries) {
      final reqKey = entry.key;
      final mineralKey = entry.value;

      final cropBounds = _parseRange(npk[reqKey] as String?);
      final plantMid = _bestMineralMid(plantRow, mineralKey);

      if (cropBounds == null || plantMid == null) {
        notComparable.add(mineralKey);
        continue;
      }

      final cropMid = _mid(cropBounds);
      if (cropMid == 0) {
        notComparable.add(mineralKey);
        continue;
      }
      ratios[mineralKey] = double.parse((plantMid / cropMid).toStringAsFixed(3));
    }
    notComparable.add('nitrogen'); // never tracked by the mineral-profile source

    final candidateName =
        (plantRow['common_name'] as String?) ?? (plantRow['scientific_name'] as String?) ?? candidatePlant;

    return BioaccumulatorRatioResult(
      success: true,
      crop: (cropRow['Crop'] as String?) ?? crop,
      candidatePlant: candidateName,
      ratios: ratios,
      notComparable: notComparable,
      unitCaveat: 'Ratios compare tissue ppm (plant_mineral_profiles.json) against an '
          'agronomic NPK requirement index (Crop_Requirements.json) -- a relative '
          'signal, not a unit-equivalent dosing calculation.',
    );
  }

  Map<String, dynamic>? _findCrop(String name) {
    final nameL = name.trim().toLowerCase();
    if (nameL.isEmpty) return null;
    for (final row in _crops) {
      final cropName = (row['Crop'] as String?)?.toLowerCase();
      final sciName = (row['Scientific Name'] as String?)?.toLowerCase();
      if (cropName == nameL || sciName == nameL) return row;
    }
    for (final row in _crops) {
      final cropName = (row['Crop'] as String? ?? '').toLowerCase();
      if (cropName.contains(nameL)) return row;
    }
    return null;
  }

  Map<String, dynamic>? _findPlant(String name) {
    final nameL = name.trim().toLowerCase();
    if (nameL.isEmpty) return null;
    final byCommon = _plantLookupService.byCommonName;
    final bySci = _plantLookupService.byScientificName;

    if (byCommon.containsKey(nameL)) return byCommon[nameL];
    if (bySci.containsKey(nameL)) return bySci[nameL];

    for (final e in byCommon.entries) {
      if (e.key.contains(nameL) || nameL.contains(e.key)) return e.value;
    }
    for (final e in bySci.entries) {
      if (e.key.contains(nameL) || nameL.contains(e.key)) return e.value;
    }
    return null;
  }

  /// Richest-part mid-range value for one mineral, ppm (max across plant
  /// parts). A part missing either `min` or `max` for that mineral is
  /// skipped, matching the Python try/except-swallow behavior.
  double? _bestMineralMid(Map<String, dynamic> plantRow, String mineralKey) {
    double? best;
    final parts = plantRow['parts'] as Map<String, dynamic>?;
    if (parts == null) return null;

    for (final partData in parts.values) {
      final minerals = (partData as Map<String, dynamic>?)?['minerals'] as Map<String, dynamic>?;
      final mineral = minerals?[mineralKey] as Map<String, dynamic>?;
      if (mineral == null) continue;

      final minV = mineral['min'];
      final maxV = mineral['max'];
      if (minV is! num || maxV is! num) continue;

      final mid = (minV.toDouble() + maxV.toDouble()) / 2.0;
      if (best == null || mid > best) best = mid;
    }
    return best;
  }

  /// Parses a "30-70"-style range string into (min, max). Deliberately does
  /// NOT allow a leading minus per number (see `_rangeRe` above).
  _Range? _parseRange(String? text) {
    if (text == null) return null;
    final nums = _rangeRe.allMatches(text).map((m) => double.parse(m.group(0)!)).toList();
    if (nums.isEmpty) return null;
    nums.sort();
    return _Range(nums.first, nums.last);
  }

  double _mid(_Range bounds) => (bounds.min + bounds.max) / 2.0;
}

class _Range {
  final double min;
  final double max;
  const _Range(this.min, this.max);
}

/// Result of a bioaccumulator ratio comparison.
class BioaccumulatorRatioResult {
  final bool success;
  final String? crop;
  final String? candidatePlant;
  final Map<String, double> ratios;
  final List<String> notComparable;
  final String? unitCaveat;
  final String? errorMessage;

  BioaccumulatorRatioResult({
    required this.success,
    this.crop,
    this.candidatePlant,
    this.ratios = const {},
    this.notComparable = const [],
    this.unitCaveat,
    this.errorMessage,
  });

  factory BioaccumulatorRatioResult.error(String message) => BioaccumulatorRatioResult(
        success: false,
        errorMessage: message,
      );

  /// Format for inclusion in the tool-result prompt / ToolExecutor's
  /// ToolResult.result, mirroring the other tool result formatters' style.
  String toMessage() {
    if (!success) return errorMessage ?? 'Unknown error';

    final buffer = StringBuffer();
    buffer.writeln('Bioaccumulator ratio: $candidatePlant vs. $crop');
    if (ratios.isEmpty) {
      buffer.writeln('No comparable nutrients found.');
    } else {
      for (final entry in ratios.entries) {
        buffer.writeln('  ${entry.key}: ${entry.value} (tissue ppm / crop requirement mid)');
      }
    }
    if (notComparable.isNotEmpty) {
      buffer.writeln('Not comparable: ${notComparable.join(", ")}');
    }
    if (unitCaveat != null) {
      buffer.writeln(unitCaveat);
    }
    return buffer.toString().trimRight();
  }
}
