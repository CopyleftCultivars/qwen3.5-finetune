import 'dart:math' as math;

import 'package:cactus/cactus.dart' show CactusTool;

/// Static, pre-generation, query-based tool routing (chainlink #177, on-device
/// port of #175's GPU-side router).
///
/// Faithful Dart port of `qwen3-finetune/rlm_slice/tool_router.py`, which is
/// itself a faithful Python port of cactus-engine/src/rag.cpp's
/// `select_relevant_tools`: same tokenizer, same BM25 formula/constants, same
/// RRF fusion of an embedding-cosine ranking and a BM25 ranking.
///
/// This is a deliberate *re-port*, not a call into Cactus's own routing --
/// per the owner's explicit decision this session, Cactus's native
/// `select_relevant_tools` (C++, unreachable from Dart -- never exposed
/// through the FFI layer) and `ToolFilterService` (Dart, wired nowhere in
/// this app) are both known-weak and are not to be used. This file is our
/// own routing algorithm, ported faithfully from the GPU experiment that
/// validated it (#175: McNemar chi2=6.125, p<0.05 for tool-augmented context
/// vs. retrieval-alone).
///
/// Only the two *domain* tools (bioaccumulator_ratio, regional_recipe_lookup)
/// are meant to be routed by this. Retrieval (`RagService`) stays a fixed,
/// always-executed step, not part of the routed tool list -- mirroring how
/// the GPU harness kept `retrieve_rag_context` and `select_relevant_tools` as
/// two separate mechanisms (see `multi_tool_context.py`'s docstring).
const double rrfK = 60.0;
const double rrfEmbWeight = 0.8;
const double rrfBm25Weight = 0.2;
const double bm25K1 = 1.5;
const double bm25B = 0.75;

final RegExp _wordRe = RegExp(r'[a-z0-9]+');

/// cactus-engine's tokenize_words: alnum runs, lowercased, length > 2.
List<String> tokenizeWords(String text) {
  return _wordRe
      .allMatches(text.toLowerCase())
      .map((m) => m.group(0)!)
      .where((w) => w.length > 2)
      .toList();
}

/// cactus-engine's tool_to_text: name + " " + description, verbatim.
String toolToText(CactusTool tool) => '${tool.name} ${tool.description}';

/// Standard Okapi BM25 score of `queryWords` against one document.
double computeBm25Score({
  required List<String> queryWords,
  required String docContent,
  required double avgDocLen,
  required Map<String, int> docFreqs,
  required int totalDocs,
}) {
  final docWords = tokenizeWords(docContent);
  final docLen = docWords.length.toDouble();
  final tf = <String, int>{};
  for (final w in docWords) {
    tf[w] = (tf[w] ?? 0) + 1;
  }

  var score = 0.0;
  for (final term in queryWords.toSet()) {
    final termFreq = tf[term];
    if (termFreq == null) continue;
    final df = (docFreqs[term] ?? 1).toDouble();
    final idf = math.log((totalDocs - df + 0.5) / (df + 0.5) + 1.0);
    final tfComponent = (termFreq * (bm25K1 + 1.0)) /
        (termFreq + bm25K1 * (1.0 - bm25B + bm25B * (docLen / avgDocLen)));
    score += idf * tfComponent;
  }
  return score;
}

/// Standard cosine similarity; 0.0 for mismatched lengths or an empty vector.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0.0;
  var dot = 0.0, normA = 0.0, normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  final denom = math.sqrt(normA) * math.sqrt(normB);
  return denom > 0 ? dot / denom : 0.0;
}

/// Reciprocal Rank Fusion of an embedding-cosine ranking and a BM25 ranking.
/// `embRanked`/`bm25Ranked` are (score, itemIndex) pairs; ranks are
/// 1-indexed by descending score within each signal. Returns (rrfScore,
/// itemIndex) pairs sorted by descending rrfScore.
List<MapEntry<double, int>> computeRrfScores({
  required List<MapEntry<double, int>> embRanked,
  required List<MapEntry<double, int>> bm25Ranked,
  required int numItems,
}) {
  final embSorted = [...embRanked]..sort((a, b) => b.key.compareTo(a.key));
  final bm25Sorted = [...bm25Ranked]..sort((a, b) => b.key.compareTo(a.key));

  final embRank = <int, int>{};
  for (var r = 0; r < embSorted.length; r++) {
    embRank[embSorted[r].value] = r + 1;
  }
  final bm25Rank = <int, int>{};
  for (var r = 0; r < bm25Sorted.length; r++) {
    bm25Rank[bm25Sorted[r].value] = r + 1;
  }

  final rrfScored = <MapEntry<double, int>>[];
  for (var i = 0; i < numItems; i++) {
    final rrf = rrfEmbWeight / (rrfK + embRank[i]!) +
        rrfBm25Weight / (rrfK + bm25Rank[i]!);
    rrfScored.add(MapEntry(rrf, i));
  }
  rrfScored.sort((a, b) => b.key.compareTo(a.key));
  return rrfScored;
}

/// Per-tool score record, mirroring the Python `ToolScore` dataclass.
class ToolScore {
  final String name;
  final double rrfScore;
  final double bm25Score;
  final double embeddingCosine;

  ToolScore({
    required this.name,
    required this.rrfScore,
    required this.bm25Score,
    required this.embeddingCosine,
  });
}

/// Every candidate tool's score against one query, mirroring the Python
/// `RoutingResult` dataclass.
class RoutingResult {
  final String query;
  final List<ToolScore> scores;

  RoutingResult({required this.query, required this.scores});

  /// Tool names ranked by descending RRF score, optionally filtered to a
  /// minimum score and/or truncated to the top `topK`.
  List<String> selected({int? topK, double? minScore}) {
    var ranked = [...scores]..sort((a, b) => b.rrfScore.compareTo(a.rrfScore));
    if (minScore != null) {
      ranked = ranked.where((s) => s.rrfScore >= minScore).toList();
    }
    if (topK != null) {
      ranked = ranked.take(topK).toList();
    }
    return ranked.map((s) => s.name).toList();
  }
}

/// Produces an embedding for one piece of text. Callers pass
/// `EmbeddingService.generateEmbedding` (or a deterministic stub in tests) --
/// this file never talks to a model directly, so tests don't need a live
/// embedding model.
typedef EmbedFn = Future<List<double>> Function(String text);

/// Rank every tool in `tools` against `query`; the caller decides
/// top_k/threshold via [RoutingResult.selected].
///
/// Always scores and returns every tool (unlike Cactus's early-return when
/// `tools.length <= topK`), matching the Python port's rationale: routing
/// experiments want a per-question score record for every candidate, not
/// just a final selection.
Future<RoutingResult> selectRelevantTools(
  String query,
  List<CactusTool> tools, {
  required EmbedFn embedFn,
}) async {
  if (tools.isEmpty) {
    return RoutingResult(query: query, scores: []);
  }

  final texts = tools.map(toolToText).toList();
  final toolWords = texts.map(tokenizeWords).toList();
  final queryWords = tokenizeWords(query);

  final totalLen = toolWords.fold<int>(0, (sum, w) => sum + w.length);
  final avgDocLen = texts.isNotEmpty ? totalLen / texts.length : 1.0;

  final docFreqs = <String, int>{};
  for (final words in toolWords) {
    for (final w in words.toSet()) {
      docFreqs[w] = (docFreqs[w] ?? 0) + 1;
    }
  }

  final queryEmb = await embedFn(query);
  final toolEmbs = <List<double>>[];
  for (final text in texts) {
    toolEmbs.add(await embedFn(text));
  }

  final embRanked = <MapEntry<double, int>>[
    for (var i = 0; i < toolEmbs.length; i++)
      MapEntry(cosineSimilarity(queryEmb, toolEmbs[i]), i),
  ];
  final bm25Ranked = <MapEntry<double, int>>[
    for (var i = 0; i < texts.length; i++)
      MapEntry(
        computeBm25Score(
          queryWords: queryWords,
          docContent: texts[i],
          avgDocLen: avgDocLen,
          docFreqs: docFreqs,
          totalDocs: texts.length,
        ),
        i,
      ),
  ];

  final rrfScored = computeRrfScores(
    embRanked: embRanked,
    bm25Ranked: bm25Ranked,
    numItems: texts.length,
  );
  final rrfByIdx = <int, double>{
    for (final e in rrfScored) e.value: e.key,
  };

  final scores = <ToolScore>[
    for (var i = 0; i < tools.length; i++)
      ToolScore(
        name: tools[i].name,
        rrfScore: rrfByIdx[i]!,
        bm25Score: bm25Ranked[i].key,
        embeddingCosine: embRanked[i].key,
      ),
  ];
  return RoutingResult(query: query, scores: scores);
}
