import 'package:cactus/cactus.dart' show CactusTool, ToolParametersSchema;
import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/tool_router.dart';

// Mirrors qwen3-finetune/tests/test_tool_router.py's test cases, so this
// port's fidelity to the Python (and, through it, cactus-engine's C++) is
// checked the same way on both sides (chainlink #177).

CactusTool _tool(String name, String description) => CactusTool(
      name: name,
      description: description,
      parameters: ToolParametersSchema(properties: const {}),
    );

/// Deterministic bag-of-words one-hot-ish stub: no live embedding model
/// needed, matching the Python tests' `_stub_embed_fn`.
Future<List<double>> _stubEmbedFn(String text) async {
  const vocab = [
    'bioaccumulator',
    'ratio',
    'region',
    'recipe',
    'retrieval',
    'ferment',
  ];
  final words = tokenizeWords(text).toSet();
  return [for (final v in vocab) words.contains(v) ? 1.0 : 0.0];
}

void main() {
  group('tokenize + BM25 (fidelity check against cactus-engine)', () {
    test('drops short and non-alnum tokens', () {
      expect(
        tokenizeWords('Add a cup to the mix!'),
        ['add', 'cup', 'the', 'mix'],
      );
    });

    test('tool_to_text is name + space + description', () {
      final tool = _tool('foo', 'does a thing');
      expect(toolToText(tool), 'foo does a thing');
    });

    test('BM25 score is zero for no overlap', () {
      final score = computeBm25Score(
        queryWords: ['nitrogen', 'deficiency'],
        docContent: 'regional plant lookup for bioaccumulators',
        avgDocLen: 5.0,
        docFreqs: {'regional': 1, 'plant': 1, 'lookup': 1, 'bioaccumulators': 1},
        totalDocs: 2,
      );
      expect(score, 0.0);
    });

    test('BM25 score is positive for overlap', () {
      final score = computeBm25Score(
        queryWords: ['nitrogen', 'ratio'],
        docContent: 'nitrogen ratio calculator for bioaccumulator plants',
        avgDocLen: 6.0,
        docFreqs: {'nitrogen': 1, 'ratio': 1},
        totalDocs: 2,
      );
      expect(score, greaterThan(0.0));
    });
  });

  group('cosine similarity', () {
    test('identical vectors score one', () {
      expect(cosineSimilarity([1.0, 0.0], [1.0, 0.0]), closeTo(1.0, 1e-9));
    });

    test('orthogonal vectors score zero', () {
      expect(cosineSimilarity([1.0, 0.0], [0.0, 1.0]), closeTo(0.0, 1e-9));
    });

    test('mismatched lengths score zero', () {
      expect(cosineSimilarity([1.0], [1.0, 0.0]), 0.0);
    });
  });

  group('RRF fusion', () {
    test('item ranked first by both signals scores highest', () {
      final embRanked = [const MapEntry(0.9, 0), const MapEntry(0.1, 1)];
      final bm25Ranked = [const MapEntry(5.0, 0), const MapEntry(0.0, 1)];
      final scored = computeRrfScores(
        embRanked: embRanked,
        bm25Ranked: bm25Ranked,
        numItems: 2,
      );
      expect(scored.first.value, 0);
    });

    test('scores use the documented RRF constants', () {
      final embRanked = [const MapEntry(0.9, 0), const MapEntry(0.1, 1)];
      final bm25Ranked = [const MapEntry(5.0, 0), const MapEntry(0.0, 1)];
      final scored = computeRrfScores(
        embRanked: embRanked,
        bm25Ranked: bm25Ranked,
        numItems: 2,
      );
      final byIdx = {for (final e in scored) e.value: e.key};
      final expected0 =
          rrfEmbWeight / (rrfK + 1) + rrfBm25Weight / (rrfK + 1);
      expect(byIdx[0], closeTo(expected0, 1e-12));
    });
  });

  group('selectRelevantTools (stub embedder, no live model needed)', () {
    final tools = [
      _tool('bioaccumulator_ratio',
          'Compare crop nutrient ratio against bioaccumulator plant'),
      _tool('regional_recipe_lookup',
          'Region and recipe lookup for bioaccumulator plants'),
    ];

    test('empty tool list returns no scores', () async {
      final result =
          await selectRelevantTools('anything', [], embedFn: _stubEmbedFn);
      expect(result.scores, isEmpty);
    });

    test('every tool is scored', () async {
      final result = await selectRelevantTools(
        'bioaccumulator ratio question',
        tools,
        embedFn: _stubEmbedFn,
      );
      expect(
        result.scores.map((s) => s.name).toSet(),
        {'bioaccumulator_ratio', 'regional_recipe_lookup'},
      );
    });

    test('selected respects topK', () async {
      final result = await selectRelevantTools(
        'bioaccumulator ratio question',
        tools,
        embedFn: _stubEmbedFn,
      );
      expect(result.selected(topK: 1).length, 1);
    });

    test('selected respects minScore', () async {
      final result = await selectRelevantTools(
        'bioaccumulator ratio question',
        tools,
        embedFn: _stubEmbedFn,
      );
      expect(result.selected(minScore: 10000.0), isEmpty);
    });
  });
}
