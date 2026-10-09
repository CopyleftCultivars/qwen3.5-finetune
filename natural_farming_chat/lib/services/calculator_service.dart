import 'dart:math' as math;

/// Service for safe mathematical expression evaluation.
/// Used in agentic mode to process `<calculate>` tags.
class CalculatorService {
  /// Evaluate a mathematical expression safely
  /// Returns the result as a string, or an error message
  String evaluate(String expression) {
    if (expression.length > 200) {
      return 'Error: Expression too long';
    }

    try {
      final cleaned = expression.trim();
      final result = _parseAndEvaluate(cleaned);

      // Format result nicely
      if (result == result.roundToDouble()) {
        return result.toInt().toString();
      } else {
        // Limit decimal places
        return result.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
      }
    } catch (e) {
      return 'Error: ${e.toString()}';
    }
  }

  /// Extract all `<calculate>` tags from text.
  List<CalculatorMatch> extractTags(String text) {
    final pattern = RegExp(r'<calculate>(.*?)</calculate>', dotAll: true);
    final matches = pattern.allMatches(text);

    return matches.map((m) => CalculatorMatch(
      fullMatch: m.group(0)!,
      expression: m.group(1)!.trim(),
      start: m.start,
      end: m.end,
    )).toList();
  }

  /// Replace `<calculate>` tags with their results.
  String processResponse(String response) {
    final tags = extractTags(response);
    if (tags.isEmpty) return response;

    var result = response;
    // Process in reverse order to maintain positions
    for (final tag in tags.reversed) {
      final calcResult = evaluate(tag.expression);
      final replacement = '**Result:** $calcResult';
      result = result.replaceRange(tag.start, tag.end, replacement);
    }

    return result;
  }

  /// Parse and evaluate a mathematical expression
  /// Supports: +, -, *, /, ^, %, sqrt, sin, cos, tan, log, ln, pi, e
  double _parseAndEvaluate(String expression) {
    final parser = _ExpressionParser(expression);
    return parser.parse();
  }
}

/// Represents a matched `<calculate>` tag.
class CalculatorMatch {
  final String fullMatch;
  final String expression;
  final int start;
  final int end;

  CalculatorMatch({
    required this.fullMatch,
    required this.expression,
    required this.start,
    required this.end,
  });
}

/// Simple recursive descent parser for mathematical expressions
class _ExpressionParser {
  final String input;
  int _pos = 0;

  _ExpressionParser(this.input);

  double parse() {
    final result = _parseExpression();
    _skipWhitespace();
    if (_pos < input.length) {
      throw FormatException('Unexpected character: ${input[_pos]}');
    }
    return result;
  }

  double _parseExpression() {
    return _parseAddSub();
  }

  double _parseAddSub() {
    var left = _parseMulDiv();

    while (true) {
      _skipWhitespace();
      if (_match('+')) {
        left = left + _parseMulDiv();
      } else if (_match('-')) {
        left = left - _parseMulDiv();
      } else {
        break;
      }
    }

    return left;
  }

  double _parseMulDiv() {
    var left = _parsePower();

    while (true) {
      _skipWhitespace();
      if (_match('*')) {
        left = left * _parsePower();
      } else if (_match('/')) {
        final right = _parsePower();
        if (right == 0) throw FormatException('Division by zero');
        left = left / right;
      } else if (_match('%')) {
        left = left % _parsePower();
      } else {
        break;
      }
    }

    return left;
  }

  double _parsePower() {
    var left = _parseUnary();

    _skipWhitespace();
    if (_match('^') || _match('**')) {
      left = math.pow(left, _parsePower()).toDouble();
    }

    return left;
  }

  double _parseUnary() {
    _skipWhitespace();

    if (_match('-')) {
      return -_parseUnary();
    }
    if (_match('+')) {
      return _parseUnary();
    }

    return _parsePrimary();
  }

  double _parsePrimary() {
    _skipWhitespace();

    // Check for functions
    for (final func in _functions.entries) {
      if (_matchWord(func.key)) {
        _skipWhitespace();
        if (!_match('(')) throw FormatException('Expected ( after ${func.key}');
        final arg = _parseExpression();
        _skipWhitespace();
        if (!_match(')')) throw FormatException('Expected )');
        return func.value(arg);
      }
    }

    // Check for constants
    if (_matchWord('pi')) return math.pi;
    if (_matchWord('e')) return math.e;

    // Parenthesized expression
    if (_match('(')) {
      final result = _parseExpression();
      _skipWhitespace();
      if (!_match(')')) throw FormatException('Expected )');
      return result;
    }

    // Number
    return _parseNumber();
  }

  double _parseNumber() {
    _skipWhitespace();
    final start = _pos;

    while (_pos < input.length &&
           (input[_pos].contains(RegExp(r'[0-9.]')))) {
      _pos++;
    }

    if (_pos == start) {
      throw FormatException('Expected number at position $_pos');
    }

    final numStr = input.substring(start, _pos);
    final number = double.tryParse(numStr);
    if (number == null) {
      throw FormatException('Invalid number: $numStr');
    }

    return number;
  }

  void _skipWhitespace() {
    while (_pos < input.length && input[_pos].trim().isEmpty) {
      _pos++;
    }
  }

  bool _match(String expected) {
    _skipWhitespace();
    if (_pos + expected.length <= input.length &&
        input.substring(_pos, _pos + expected.length) == expected) {
      _pos += expected.length;
      return true;
    }
    return false;
  }

  bool _matchWord(String word) {
    _skipWhitespace();
    if (_pos + word.length <= input.length &&
        input.substring(_pos, _pos + word.length).toLowerCase() == word.toLowerCase()) {
      // Make sure it's not part of a longer word
      if (_pos + word.length < input.length) {
        final nextChar = input[_pos + word.length];
        if (RegExp(r'[a-zA-Z0-9_]').hasMatch(nextChar)) {
          return false;
        }
      }
      _pos += word.length;
      return true;
    }
    return false;
  }

  static final _functions = <String, double Function(double)>{
    'sqrt': math.sqrt,
    'sin': math.sin,
    'cos': math.cos,
    'tan': math.tan,
    'asin': math.asin,
    'acos': math.acos,
    'atan': math.atan,
    'log': (x) => math.log(x) / math.ln10, // log10
    'ln': math.log,
    'abs': (x) => x.abs(),
    'floor': (x) => x.floorToDouble(),
    'ceil': (x) => x.ceilToDouble(),
    'round': (x) => x.roundToDouble(),
    'exp': math.exp,
  };
}
