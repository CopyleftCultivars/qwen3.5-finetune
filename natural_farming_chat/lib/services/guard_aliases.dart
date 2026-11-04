import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Alias groups for the argument-grounding guard (chainlink #119; guard #104, from #90).
///
/// The guard accepts a plant or crop the user wrote under another of its names, so it needs each catalog entry's common and scientific
/// name together. The app already bundles both catalogs; this builds the groups from them, exactly as the Python reference does
/// (`pinned_entity_alias_groups` in `scripts/run_hf_gpu_tool_benchmark.py`): a crop group is `Crop` and `Scientific Name` of a
/// `Crop_Requirements.json` row, a plant group is `common_name` and `scientific_name` of a `plant_mineral_profiles.json` row, blank
/// names left out, rows with no name skipped. The phone harness uses the same function, so it no longer stages a copy of the groups.
const String cropAssetPath = 'assets/plant_data/Crop_Requirements.json';
const String plantAssetPath = 'assets/plant_data/plant_mineral_profiles.json';

List<String> _names(Map row, List<String> keys) => [
      for (final key in keys)
        if (row[key] is String && (row[key] as String).trim().isNotEmpty) row[key] as String,
    ];

/// Pure: the groups for decoded catalog rows.
Map<String, List<List<String>>> aliasGroupsFromRows(List<dynamic> crops, List<dynamic> plants) {
  final groups = <String, List<List<String>>>{'crop': [], 'plant': []};
  for (final row in crops) {
    final names = _names(row as Map, ['Crop', 'Scientific Name']);
    if (names.isNotEmpty) groups['crop']!.add(names);
  }
  for (final row in plants) {
    final names = _names(row as Map, ['common_name', 'scientific_name']);
    if (names.isNotEmpty) groups['plant']!.add(names);
  }
  return groups;
}

Future<Map<String, List<List<String>>>> loadGuardAliasGroups({AssetBundle? bundle}) async {
  final source = bundle ?? rootBundle;
  final crops = jsonDecode(await source.loadString(cropAssetPath)) as List<dynamic>;
  final plants = jsonDecode(await source.loadString(plantAssetPath)) as List<dynamic>;
  return aliasGroupsFromRows(crops, plants);
}
