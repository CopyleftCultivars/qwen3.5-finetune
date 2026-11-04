// Served view v2 for the Pixel harness (chainlink #101 step 3, parent #86).
//
// Dart port of `recipe_tool_served_view_v2.py`: a pure projection of the v1 served view (the map the app's
// `RecipeToolService.servedView` returns) in which every volume is a plain number plus a separate unit field chosen by code
// (ml below 1 l, l from 1 l; rates ml_per_m2 / l_per_m2). Metric only. It lives in the benchmark harness, not in the app's
// `lib/`: app changes go through #80 after #79 gives a go. The app's own rounding helpers are private, so the three-significant-
// figure rounding is copied here (the same decimal, half-away-from-zero rule as `_significance` in recipe_tool_service.dart).
//
// Exactness: the factor of 1000 is applied to the decimal digits of the shortest round-trip form of the value (the same digits
// Python's `Decimal(str(value))` sees), never by floating-point multiplication.
//
// Pure Dart (dart:convert and dart:math only) so it runs under `dart run` and inside the app package alike.

import 'dart:convert';
import 'dart:math' as math;

const String servedViewV2Version = 'recipe_tool_served_view_v2';

/// Variants (chainlink #101): `v2` converts every volume field; `v2b` is identical except `concentrate_ml` stays exactly as in v1
/// (already millilitres, no unit field). v2 as measured made the model stop stating the concentrate; v2b isolates the key rename.
const Map<String, String> variantVersions = {
  'v2': servedViewV2Version,
  'v2b': 'recipe_tool_served_view_v2b',
};
const Map<String, Set<String>> keptV1Keys = {
  'v2': <String>{},
  'v2b': {'concentrate_ml'},
};

/// v1 key -> (v2 key, unit the v1 number is written in).
const Map<String, (String, String)> volumeFields = {
  'steep_water_l': ('steep_water', 'l'),
  'concentrate_l': ('concentrate', 'l'),
  'concentrate_ml': ('concentrate', 'ml'),
  'diluted_volume_l': ('diluted_volume', 'l'),
  'rate_l_per_m2': ('rate', 'l_per_m2'),
  'standard_rate_l_per_m2': ('standard_rate', 'l_per_m2'),
};

/// `(number, unit)` for a v1 volume written in [v1Unit] (`l`, `ml` or `l_per_m2`); `(null, null)` for a null.
(num?, String?) volumePair(num? value, String v1Unit) {
  if (value == null) return (null, null);
  final perArea = v1Unit.endsWith('_per_m2');
  final fromMl = v1Unit == 'ml';
  final given = _decimalParts(value.toDouble());
  // litres < 1 on the decimal digits: the value is below 1 when it has no integer digit (or is zero).
  final litresExponent = given.exponent - (fromMl ? 3 : 0);
  final isZero = given.digits.replaceAll('0', '').isEmpty;
  final belowOneLitre = isZero || given.digits.length + litresExponent <= 0;
  final int shift;
  final String unit;
  if (belowOneLitre) {
    shift = fromMl ? 0 : 3;
    unit = 'ml';
  } else {
    shift = fromMl ? -3 : 0;
    unit = 'l';
  }
  final scaled = double.parse('${given.sign}${given.digits}e${given.exponent + shift}');
  return (_significance(scaled) as num, unit + (perArea ? '_per_m2' : ''));
}

/// A copy of a v1 block (a nutrition method or a booster application) with its volume fields as number plus unit,
/// in place, so key order is kept.
Map<String, dynamic> convertVolumes(Map<String, dynamic> block, [Set<String> keep = const <String>{}]) {
  final out = <String, dynamic>{};
  for (final entry in block.entries) {
    final field = volumeFields[entry.key];
    if (field == null || keep.contains(entry.key)) {
      out[entry.key] = entry.value;
      continue;
    }
    final (number, unit) = volumePair(entry.value as num?, field.$2);
    out[field.$1] = number;
    out['${field.$1}_unit'] = unit;
  }
  return out;
}

/// The v2 served view of a v1 served view (a decoded JSON map). The input is not modified.
Map<String, dynamic> servedViewV2(Map<String, dynamic> v1, {String variant = 'v2'}) {
  final keep = keptV1Keys[variant]!;
  final view = jsonDecode(jsonEncode(v1)) as Map<String, dynamic>;
  view['served_view_version'] = variantVersions[variant]!;
  if (view['status'] != 'ok') return view;
  final nutrition = view['nutrition'] as Map<String, dynamic>;
  final method = nutrition['method'];
  if (method != null) {
    nutrition['method'] = convertVolumes(method as Map<String, dynamic>, keep);
  }
  final booster = view['booster'];
  if (booster != null) {
    final boosterMap = booster as Map<String, dynamic>;
    final application = boosterMap['application'];
    if (application != null) {
      boosterMap['application'] = convertVolumes(application as Map<String, dynamic>, keep);
    }
  }
  return view;
}

/// The tool-result text the model receives for a v1 served-view text: v2, canonical JSON (sorted keys, like the app's).
String servedViewV2Text(String v1Text, {String variant = 'v2'}) =>
    canonicalJsonV2(servedViewV2(jsonDecode(v1Text) as Map<String, dynamic>, variant: variant));

String canonicalJsonV2(dynamic value) => jsonEncode(_canonical(value));

dynamic _canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return [for (final item in value) _canonical(item)];
  return value;
}

// --- three significant figures, decimal half-away-from-zero (copied from recipe_tool_service.dart) ---

dynamic _significance(dynamic value) {
  if (value is! num) return value;
  final number = value.toDouble();
  if (number == 0.0 || !number.isFinite) return number;
  var exponent = (math.log(number.abs()) / math.ln10).floor();
  exponent = math.max(exponent, -(3 + 300));
  return _quantize(number, exponent - (3 - 1));
}

double _quantize(double value, int exponent) {
  if (value == 0.0 || !value.isFinite) return value;
  final parsed = _decimalParts(value);
  final digits = parsed.digits;
  final shift = parsed.exponent - exponent;
  if (shift >= 0) {
    final padded = digits + '0' * shift;
    return double.parse('${parsed.sign}${padded}e$exponent');
  }
  final keep = digits.length + shift;
  if (keep <= 0) {
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
