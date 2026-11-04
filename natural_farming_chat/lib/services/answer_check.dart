// Answer check for the recipe instructions (chainlink #119; spec docs/specs/answer-check-v1.md, from #101 and #86).
//
// Dart port of `answer_check.py` (version `answer_check_v1`) with the scorer v4/v5 helpers it uses (unit table, claim regex, amount
// matching, requirements). A pure function of the model's instruction text and the recipe tool's v1 served view (the map
// `RecipeToolService.servedView` returns). It reports four kinds of finding, each with a fixed message that names a kind of problem and
// never a value, and `repair` (owner decision 2026-11-01: show the repaired text) corrects the unit token of a volume whose number is
// right and appends fixed sentences built from the tool result. It never rewrites the model's wording and adds no model call.
//
// Pure Dart (dart:core plus the two pure files below). The golden file `test/fixtures/answer_check_goldens.json` is generated from the
// Python reference by `scripts/generate_answer_check_goldens.py`.

import 'format_g.dart';
import 'recipe_served_view_v2.dart';

const String answerCheckVersion = 'answer_check_v1';
const String volumeBase = 'ml';

const Map<String, String> findingMessages = {
  'volume_mismatch': 'A volume in the instructions does not match the recipe result in size or unit.',
  'volume_missing': 'A booster volume from the recipe result is not stated in the instructions.',
  'amount_missing': 'An amount from the recipe result is not stated in the instructions.',
  'assumption_missing': 'A required assumption from the recipe result is not stated in the instructions.',
};

/// Canonical unit per accepted alias: (base unit, factor to the base).
const Map<String, (String, double)> unitAliases = {
  'kg': ('g', 1000.0),
  'kilogram': ('g', 1000.0),
  'kilograms': ('g', 1000.0),
  'g': ('g', 1.0),
  'gram': ('g', 1.0),
  'grams': ('g', 1.0),
  'mg': ('g', 0.001),
  'milligram': ('g', 0.001),
  'milligrams': ('g', 0.001),
  'l': ('ml', 1000.0),
  'litre': ('ml', 1000.0),
  'litres': ('ml', 1000.0),
  'liter': ('ml', 1000.0),
  'liters': ('ml', 1000.0),
  'ml': ('ml', 1.0),
  'millilitre': ('ml', 1.0),
  'millilitres': ('ml', 1.0),
  'milliliter': ('ml', 1.0),
  'milliliters': ('ml', 1.0),
  'cm': ('cm', 1.0),
  'centimetre': ('cm', 1.0),
  'centimetres': ('cm', 1.0),
  'centimeter': ('cm', 1.0),
  'centimeters': ('cm', 1.0),
  'mm': ('cm', 0.1),
  'm2': ('m2', 1.0),
  'm²': ('m2', 1.0),
  'm^2': ('m2', 1.0),
  'sq m': ('m2', 1.0),
  'square metre': ('m2', 1.0),
  'square metres': ('m2', 1.0),
  'square meter': ('m2', 1.0),
  'square meters': ('m2', 1.0),
  '%': ('percent', 1.0),
  'percent': ('percent', 1.0),
};

/// Unit tokens allowed in an amount claim, longest first so "square metres" beats "m".
const List<String> _claimUnits = [
  'square metres', 'square meters', 'square metre', 'square meter',
  'kilograms', 'kilogram', 'millilitres', 'milliliters', 'millilitre',
  'milliliter', 'centimetres', 'centimeters', 'centimetre', 'centimeter',
  'milligrams', 'milligram', 'grams', 'gram', 'litres', 'liters', 'litre',
  'liter', 'mg', 'ml', 'kg', 'cm', 'mm', 'g', 'l', 'm2', 'm²', 'm^2',
  '%',
];

const String _number = r'\d+(?:,\d{3})*(?:\.\d+)?(?:[eE][+-]?\d+)?';
final RegExp claimRe = RegExp(
  '(?<value>$_number)\\s*(?<unit>${_claimUnits.map(RegExp.escape).join('|')})(?![A-Za-z])',
  caseSensitive: false,
);
final RegExp _whitespace = RegExp(r'\s+');

String normalize(Object? value) => (value ?? '').toString().trim().replaceAll(_whitespace, ' ').toLowerCase();

double? toFloat(Object? value) {
  if (value == null) return null;
  if (value is bool) return value ? 1.0 : 0.0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', ''));
}

(String, double)? unitFamily(String unit) => unitAliases[normalize(unit)];

bool _withinTolerance(double a, double b) => (a - b).abs() <= _max(b.abs() * 0.01, 1e-6);
double _max(double a, double b) => a > b ? a : b;

class RequiredAmount {
  RequiredAmount(this.value, this.unit, this.label);
  final double value;
  final String unit;
  final String label;
}

class Requirements {
  Requirements({required this.status, this.amounts = const [], this.assumptions = const []});
  final String? status;
  final List<RequiredAmount> amounts;
  final List<String> assumptions;
}

Map<String, dynamic> _map(Object? value) => value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

/// Scorer v4 `fidelity_requirements`: the amounts and assumption phrases a faithful reply must carry (from the v1 served view).
Requirements fidelityRequirements(Map<String, dynamic> served) {
  final status = served['status'] as String?;
  if (status != 'ok') return Requirements(status: status);
  final amounts = <RequiredAmount>[];
  final seen = <String>{};
  void add(Object? value, String unit, String label) {
    final number = toFloat(value);
    if (number == null) return;
    final key = '${number.toStringAsFixed(9)}|$unit';
    if (!seen.add(key)) return;
    amounts.add(RequiredAmount(number, unit, label));
  }

  add(served['area_m2'], 'm2', 'area');
  final nutrition = _map(served['nutrition']);
  add(nutrition['fresh_material_kg'], 'kg', 'nutrition.fresh_material');
  add(nutrition['fresh_material_kg_per_m2'], 'kg', 'nutrition.fresh_material_per_m2');
  for (final entry in _map(nutrition['coverage_percent']).entries) {
    add(entry.value, '%', 'nutrition.coverage.${entry.key}');
  }
  final method = nutrition['method'] == null ? null : _map(nutrition['method']);
  if (method != null) {
    final name = method['name'];
    add(method['fresh_material_kg'], 'kg', 'nutrition.method.$name.mass');
    if (name == 'mulch') {
      add(method['mulch_depth_cm'], 'cm', 'nutrition.method.mulch.mulch_depth');
      add(method['implied_depth_cm'], 'cm', 'nutrition.method.mulch.implied_depth');
    }
    if (name == 'plant_tea') {
      add(method['diluted_volume_l'], 'l', 'nutrition.method.plant_tea.diluted_volume');
      add(method['rate_l_per_m2'], 'l', 'nutrition.method.plant_tea.rate_per_m2');
    }
  }
  final booster = served['booster'] == null ? null : _map(served['booster']);
  var hasSubstitution = false;
  if (booster != null) {
    final abbreviation = booster['recipe_abbrev'];
    final batch = _map(booster['standard_batch']);
    add(batch['plant_material_fresh_kg'], 'kg', 'booster.$abbreviation.standard_batch.plant_material');
    final extractant = _map(batch['extractant']);
    if (extractant['amount'] != null) {
      final unit = extractant['unit'];
      add(extractant['amount'], (unit is String && unit.isNotEmpty) ? unit : 'kg', 'booster.$abbreviation.extractant');
    }
    final application = _map(booster['application']);
    add(application['concentrate_ml'], 'ml', 'booster.$abbreviation.concentrate_ml');
    add(application['diluted_volume_l'], 'l', 'booster.$abbreviation.diluted_volume');
    if (application['rate_l_per_m2'] != null) {
      add(application['rate_l_per_m2'], 'l', 'booster.$abbreviation.rate_per_m2');
    }
    final substitution = booster['substitution'];
    hasSubstitution = substitution != null && substitution != false && substitution != '' && !(substitution is Iterable && substitution.isEmpty) && !(substitution is Map && substitution.isEmpty);
  }
  final topUp = nutrition['top_up_notes'];
  final assumptions = <String>['dry matter', 'estimate'];
  if (topUp is Iterable && topUp.isNotEmpty) assumptions.add('top up');
  if (booster != null) assumptions.add('information only');
  if (hasSubstitution) assumptions.add('substitut');
  return Requirements(status: status, amounts: amounts, assumptions: assumptions);
}

bool _amountMatches(double claimValue, String claimUnit, RequiredAmount required) {
  final family = unitFamily(claimUnit);
  if (family == null) return false;
  final requiredFamily = unitFamily(required.unit);
  if (requiredFamily == null || requiredFamily.$1 != family.$1) return false;
  return _withinTolerance(claimValue * family.$2, required.value * requiredFamily.$2);
}

List<RequiredAmount> _missingAmounts(String answer, Requirements requirements) {
  final claims = <(double, String)>[];
  for (final match in claimRe.allMatches(answer)) {
    final value = toFloat(match.namedGroup('value'));
    if (value != null) claims.add((value, match.namedGroup('unit')!));
  }
  return [for (final required in requirements.amounts) if (!claims.any((claim) => _amountMatches(claim.$1, claim.$2, required))) required];
}

double? _volumeMl(double value, Object? unit) {
  if (unit is! String) return null;
  final family = unitFamily(unit.endsWith('_per_m2') ? unit.substring(0, unit.length - 7).replaceAll('_', ' ') : unit.replaceAll('_', ' '));
  return family != null && family.$1 == volumeBase ? value * family.$2 : null;
}

/// Scorer v5 `volume_quantities_ml`: every volume of a v2 served view in millilitres.
List<double> volumeQuantitiesMl(Map<String, dynamic> servedV2) {
  final found = <double>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final value = entry.value;
        if (value is num) {
          final ml = _volumeMl(value.toDouble(), node['${entry.key}_unit']);
          if (ml != null) found.add(ml);
        }
        walk(value);
      }
      final amount = node['amount'];
      if (amount is num) {
        final ml = _volumeMl(amount.toDouble(), node['unit']);
        if (ml != null) found.add(ml);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item);
      }
    } else if (node is String) {
      for (final match in claimRe.allMatches(node)) {
        final family = unitFamily(match.namedGroup('unit')!);
        final value = toFloat(match.namedGroup('value'));
        if (family != null && family.$1 == volumeBase && value != null) found.add(value * family.$2);
      }
    }
  }

  walk(servedV2);
  return found;
}

/// Findings for [answer] against the recipe tool's v1 served view. An error result has nothing to check here.
Map<String, dynamic> checkAnswer(String answer, Map<String, dynamic> served) {
  final requirements = fidelityRequirements(served);
  if (requirements.status != 'ok') {
    return {'version': answerCheckVersion, 'ok': true, 'skipped': 'error result', 'findings': <Map<String, dynamic>>[]};
  }
  final quantities = volumeQuantitiesMl(servedViewV2(served));
  final findings = <Map<String, dynamic>>[];
  for (final match in claimRe.allMatches(answer)) {
    final family = unitFamily(match.namedGroup('unit')!);
    final value = toFloat(match.namedGroup('value'));
    if (family != null && family.$1 == volumeBase && value != null) {
      final claimed = value * family.$2;
      if (!quantities.any((known) => _withinTolerance(claimed, known))) {
        findings.add({'kind': 'volume_mismatch', 'stated': match.group(0)});
      }
    }
  }
  for (final amount in _missingAmounts(answer, requirements)) {
    final volume = _volumeLabel(amount.label);
    findings.add(volume != null ? {'kind': 'volume_missing', 'volume': volume} : {'kind': 'amount_missing', 'label': amount.label});
  }
  for (final phrase in requirements.assumptions) {
    if (!normalize(answer).contains(phrase)) findings.add({'kind': 'assumption_missing', 'phrase': phrase});
  }
  for (final finding in findings) {
    finding['message'] = findingMessages[finding['kind']];
  }
  return {'version': answerCheckVersion, 'ok': findings.isEmpty, 'findings': findings};
}

const Map<String, String> _boosterVolumeLabels = {
  'concentrate_ml': 'concentrate',
  'diluted_volume': 'diluted volume',
  'rate_per_m2': 'application rate',
};

String? _volumeLabel(String label) {
  for (final entry in _boosterVolumeLabels.entries) {
    if (label.endsWith(entry.key)) return entry.value;
  }
  return null;
}

/// The booster volumes as one fixed sentence, in the units code chose for the served view (null parts are left out).
String? boosterLine(Map<String, dynamic> served) {
  final booster = servedViewV2(served)['booster'];
  final application = booster == null ? null : _map(_map(booster)['application']);
  if (application == null || application.isEmpty) return null;
  final parts = <String>[];
  if (application['concentrate'] != null) {
    parts.add('${formatG((application['concentrate'] as num).toDouble())} ${application['concentrate_unit']} concentrate');
  }
  if (application['diluted_volume'] != null) {
    parts.add('${formatG((application['diluted_volume'] as num).toDouble())} ${application['diluted_volume_unit']} diluted volume');
  }
  var line = parts.isNotEmpty ? 'Booster application: ${parts.join(' in ')}' : '';
  if (application['rate'] != null) {
    final rateUnit = (application['rate_unit'] as String).replaceAll('_per_m2', ' per m2');
    line = '${line.isNotEmpty ? '$line, ' : 'Booster application: '}applied at ${formatG((application['rate'] as num).toDouble())} $rateUnit';
  }
  return line.isNotEmpty ? '$line.' : null;
}

List<String> _assumptionSentences(Map<String, dynamic> served, String phrase) {
  final assumptions = served['assumptions'];
  if (assumptions is! List) return const [];
  return [for (final sentence in assumptions) if (sentence.toString().toLowerCase().contains(phrase.toLowerCase())) sentence.toString()];
}

List<(double, String)> _pairs(Map<String, dynamic> served) {
  const units = {'ml', 'l', 'ml_per_m2', 'l_per_m2'};
  final pairs = <(double, String)>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final unit = node['${entry.key}_unit'];
        final value = entry.value;
        if (value is num && unit is String && units.contains(unit)) {
          pairs.add((value.toDouble(), unit.split('_per_').first));
        }
        walk(value);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item);
      }
    }
  }

  walk(servedViewV2(served));
  return pairs;
}

(String, List<Map<String, String>>) _fixUnitSlips(String answer, List<(double, String)> pairs) {
  final fixes = <Map<String, String>>[];
  final pieces = StringBuffer();
  var last = 0;
  final knownMl = [for (final (number, unit) in pairs) number * (unit == 'ml' ? 1.0 : 1000.0)];
  for (final match in claimRe.allMatches(answer)) {
    final family = unitFamily(match.namedGroup('unit')!);
    final value = toFloat(match.namedGroup('value'));
    if (family == null || family.$1 != volumeBase || value == null) continue;
    final claimed = value * family.$2;
    if (knownMl.any((known) => _withinTolerance(claimed, known))) continue;
    for (final (number, unit) in pairs) {
      if ((value - number).abs() <= _max(number.abs() * 0.01, 1e-6) && unit != (family.$2 == 1.0 ? 'ml' : 'l')) {
        final start = match.start + match.group(0)!.length - match.namedGroup('unit')!.length;
        pieces.write(answer.substring(last, start));
        pieces.write(unit);
        last = match.end;
        fixes.add({'from': match.group(0)!, 'unit': unit});
        break;
      }
    }
  }
  pieces.write(answer.substring(last));
  return (pieces.toString(), fixes);
}

/// The checked text with the optional fixes. `changed` is false when the answer already passes or nothing can be fixed.
Map<String, dynamic> repairAnswer(String answer, Map<String, dynamic> served) {
  final report = checkAnswer(answer, served);
  if (report['ok'] == true) {
    return {'version': answerCheckVersion, 'answer': answer, 'changed': false, 'unit_fixes': <Map<String, String>>[], 'appended': <String>[], 'report': report};
  }
  final (text, fixes) = _fixUnitSlips(answer, _pairs(served));
  final appended = <String>[];
  final after = checkAnswer(text, served);
  final findings = (after['findings'] as List).cast<Map<String, dynamic>>();
  if (findings.any((f) => f['kind'] == 'volume_missing')) {
    final line = boosterLine(served);
    if (line != null) appended.add(line);
  }
  for (final finding in findings) {
    if (finding['kind'] == 'assumption_missing') {
      for (final sentence in _assumptionSentences(served, finding['phrase'] as String)) {
        if (!appended.contains(sentence) && !text.contains(sentence)) appended.add(sentence);
      }
    }
  }
  final trimmed = text.replaceFirst(RegExp(r'\s+$'), '');
  final repaired = appended.isEmpty ? trimmed : '$trimmed\n\n${appended.join(' ')}';
  return {'version': answerCheckVersion, 'answer': repaired, 'changed': repaired != answer, 'unit_fixes': fixes, 'appended': appended, 'report': report};
}

/// Count-only summary for the device log: finding kinds in order, never text or values.
String findingKinds(Map<String, dynamic> report) {
  final kinds = <String>[];
  for (final finding in (report['findings'] as List).cast<Map<String, dynamic>>()) {
    if (!kinds.contains(finding['kind'])) kinds.add(finding['kind'] as String);
  }
  return kinds.isEmpty ? 'none' : kinds.join(',');
}
