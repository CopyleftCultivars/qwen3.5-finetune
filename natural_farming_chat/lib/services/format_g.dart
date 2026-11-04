// Python `format(value, "g")` for the numbers the app prints (shared by the ledger and the answer check). Pure Dart.

/// Python `f"{value:g}"` for the values a recipe area takes.
String formatG(double value) {
  if (value == 0) return '0';
  final abs = value.abs();
  if (abs >= 1e6 || abs < 1e-4) {
    var text = value.toStringAsExponential(5); // 1.00000e+6
    final parts = text.split('e');
    var mantissa = parts[0];
    if (mantissa.contains('.')) {
      mantissa = mantissa.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    final sign = parts[1].startsWith('-') ? '-' : '+';
    final digits = parts[1].replaceFirst(RegExp(r'^[+-]'), '').padLeft(2, '0');
    return '${mantissa}e$sign$digits';
  }
  var text = value.toStringAsPrecision(6);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}
