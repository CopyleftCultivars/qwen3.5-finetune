// Argument-grounding guard v1 for the Pixel harness (chainlink #104, from #90).
//
// Dart port of `argument_grounding.py` (version `argument_grounding_v1`, spec docs/specs/argument-grounding-v1.md). A recipe call's
// plant, crop and area must each be findable in what the model was shown (the history and the user turn, never the system prompt).
// A call with an ungrounded slot is not executed; the turn ends in one fixed feedback that names kinds of value, never a value.
// Lives in the benchmark harness, not the app's `lib/`: app changes go through #80 after #79 gives a go.
//
// Pure Dart (dart:core only) so it runs under `dart run` and inside the app package alike.

const String groundingVersion = 'argument_grounding_v1';
const List<String> guardedTools = ['bioaccumulator_recipe'];

/// slot -> (noun in the feedback text, alias catalog or null). Order is the feedback order.
const List<(String, String, String?)> slots = [
  ('candidate_plant', 'plant', 'plant'),
  ('crop', 'crop', 'crop'),
  ('quantity', 'area', null),
];

final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');
final RegExp _number = RegExp(r'(?<![A-Za-z0-9])\d+(?:[.,]\d+)?');

/// Case- and punctuation-insensitive form used for containment checks.
String surface(Object? text) => text.toString().toLowerCase().replaceAll(_nonAlnum, ' ').trim();

/// True when [value] is named in [text] (the `call_guard_v1` rule).
bool mentioned(String value, String text) {
  final needle = surface(value);
  if (needle.isEmpty) return true;
  final haystack = surface(text);
  if (' $haystack '.contains(' $needle ')) return true;
  final valueTokens = needle.split(' ').where((token) => token.length >= 4).toList();
  if (valueTokens.isEmpty) return false;
  final textTokens = haystack.split(' ').where((token) => token.isNotEmpty).toList();
  return valueTokens.every((token) => textTokens.any((other) => token == other || token.startsWith(other) || other.startsWith(token)));
}

/// The unique alias group a value resolves to (exact surface first, then containment), or null.
int? _resolveGroup(String value, List<List<String>> groups) {
  final needle = surface(value);
  if (needle.isEmpty) return null;
  final exact = <int>[];
  final partial = <int>[];
  for (var index = 0; index < groups.length; index++) {
    final surfaces = [for (final alias in groups[index]) if (surface(alias).isNotEmpty) surface(alias)];
    if (surfaces.any((s) => s == needle)) {
      exact.add(index);
    } else if (surfaces.any((s) => s.contains(needle) || needle.contains(s))) {
      partial.add(index);
    }
  }
  if (exact.length == 1) return exact.first;
  if (exact.isNotEmpty) return null;
  return partial.length == 1 ? partial.first : null;
}

bool entityGrounded(Object? value, String catalog, String text, Map<String, List<List<String>>> aliasGroups) {
  final raw = (value ?? '').toString();
  if (raw.trim().isEmpty) return true; // an empty slot is the executor's error to report, not an invention
  if (mentioned(raw, text)) return true;
  final groups = aliasGroups[catalog] ?? const <List<String>>[];
  final index = _resolveGroup(raw, groups);
  return index != null && groups[index].any((alias) => mentioned(alias, text));
}

Set<double> numbers(String text) => {for (final match in _number.allMatches(text)) double.parse(match.group(0)!.replaceAll(',', '.'))};

bool quantityGrounded(Object? value, String text) {
  if (value == null || value.toString().trim().isEmpty) return true;
  final wanted = double.tryParse(value.toString().replaceAll(',', '.'));
  if (wanted == null) return false;
  return numbers(text).contains(wanted);
}

/// What the model was shown, minus the fixed system prompt.
String groundingText(Iterable<Map<String, String>> messages) =>
    messages.where((m) => m['role'] != 'system').map((m) => m['content'] ?? '').join('\n');

/// The slots of a guarded call that cannot be found in [text] (empty for any other tool).
List<String> ungroundedSlots(Map<String, dynamic> call, String text, [Map<String, List<List<String>>> aliasGroups = const {}]) {
  if (!guardedTools.contains(call['name'])) return const [];
  final arguments = (call['arguments'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final missing = <String>[];
  for (final (slot, _, catalog) in slots) {
    final value = arguments[slot];
    final ok = catalog == null ? quantityGrounded(value, text) : entityGrounded(value, catalog, text, aliasGroups);
    if (!ok) missing.add(slot);
  }
  return missing;
}

/// The fixed clarification: names the kinds of value, never a value.
String feedback(Iterable<String> blockedSlots) {
  final nouns = [for (final (slot, noun, _) in slots) if (blockedSlots.contains(slot)) noun];
  final listed = nouns.length == 1 ? nouns.first : '${nouns.sublist(0, nouns.length - 1).join(', ')} and ${nouns.last}';
  return 'I could not find the $listed for this recipe in our conversation. Please tell me the $listed and I will run it.';
}

/// Guard one decision's tool calls. `kept` are the calls that run unchanged, `blocked` the dropped ones
/// (`call_index`, `tool`, `slots`); `answer` is the fixed feedback when calls were blocked and none is left, else null.
Map<String, dynamic> applyGuard(List<Map<String, dynamic>> toolCalls, String text, [Map<String, List<List<String>>> aliasGroups = const {}]) {
  final blocked = <Map<String, dynamic>>[];
  final kept = <Map<String, dynamic>>[];
  for (var index = 0; index < toolCalls.length; index++) {
    final missing = ungroundedSlots(toolCalls[index], text, aliasGroups);
    if (missing.isNotEmpty) {
      blocked.add({'call_index': index, 'tool': toolCalls[index]['name'], 'slots': missing});
    } else {
      kept.add(toolCalls[index]);
    }
  }
  String? answer;
  if (blocked.isNotEmpty && kept.isEmpty) {
    final union = {for (final b in blocked) ...(b['slots'] as List<String>)};
    answer = feedback([for (final (slot, _, _) in slots) if (union.contains(slot)) slot]);
  }
  return {'version': groundingVersion, 'fired': blocked.isNotEmpty, 'blocked': blocked, 'kept': kept, 'answer': answer};
}
