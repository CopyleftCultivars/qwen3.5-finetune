/// Heuristic, controller-owned argument extraction for the two domain tools
/// (chainlink #177), used where a caller has free-text (a ladder MCQ's
/// question+options, or a chat query) but not structured
/// crop/plant/region/problem fields.
///
/// Faithful port of `rlm_slice/multi_tool_context.py`'s `extract_args` /
/// `_find_in_text`: longest-match, case-insensitive substring search over
/// closed vocabularies the domain data itself defines (no NER model, no
/// extra model call -- just the same names `bioaccumulator_ratio`/
/// `regional_recipe_lookup` already validate against). Per that module's
/// docstring, this exists because the 0.6B champion was already found
/// (G9/#156) not to reliably self-initiate tool calls or extract its own
/// arguments -- the controller does this instead, deterministically.
/// Longest-match (vocab must already be sorted longest-first),
/// case-insensitive substring search. Terms of length <= 2 are skipped
/// (matches the Python's `len(term) > 2` gate).
String? findInText(String text, List<String> sortedVocab) {
  final textL = text.toLowerCase();
  for (final term in sortedVocab) {
    if (term.length > 2 && textL.contains(term.toLowerCase())) {
      return term;
    }
  }
  return null;
}

List<String> sortVocabLongestFirst(Iterable<String> terms) {
  final list = terms.where((t) => t.trim().length > 2).toSet().toList();
  list.sort((a, b) => b.length.compareTo(a.length));
  return list;
}

class ToolArgExtractor {
  final List<String> cropVocab;
  final List<String> plantVocab;
  final List<String> regionVocab;

  ToolArgExtractor({
    required Iterable<String> cropNames,
    required Iterable<String> plantNames,
    required Iterable<String> regionNames,
  })  : cropVocab = sortVocabLongestFirst(cropNames),
        plantVocab = sortVocabLongestFirst(plantNames),
        regionVocab = sortVocabLongestFirst(regionNames);

  /// Mirrors `multi_tool_context.py`'s `extract_args`: returns null if not
  /// enough was found to justify running the tool at all.
  Map<String, String>? extractArgs(String toolName, String query) {
    if (toolName == 'bioaccumulator_ratio') {
      final crop = findInText(query, cropVocab);
      final plant = findInText(query, plantVocab);
      if (crop != null && plant != null) {
        return {'crop': crop, 'candidate_plant': plant};
      }
      return null;
    }
    if (toolName == 'regional_recipe_lookup') {
      final crop = findInText(query, cropVocab);
      final region = findInText(query, regionVocab);
      // `problem` always falls back to the raw query, so this tool can run
      // (and honestly report an empty match) whenever it's selected.
      return {
        if (crop != null) 'crop': crop,
        if (region != null) 'region': region,
        'problem': query,
      };
    }
    return null;
  }
}
