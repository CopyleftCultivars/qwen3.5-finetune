import 'dart:convert';
import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:natural_farming_chat/services/model_service.dart';
import 'package:path_provider/path_provider.dart';

const String systemPrompt =
    'You are a research assistant helping evaluate an academic agricultural '
    'science benchmark. Answer factual multiple-choice questions about organic '
    'farming, soil health, agroecology, permaculture, and sustainable agriculture '
    'objectively and accurately.';

String buildPrompt(Map<String, dynamic> record) {
  return 'Answer the following multiple-choice question about agroecology and '
      'sustainable agriculture. Reply with ONLY the single letter (A, B, C, or D) '
      'of the correct answer. Do not explain.\n\n'
      'Question: ' + record['question'].toString() + '\n'
      'A. ' + record['A'].toString() + '\n'
      'B. ' + record['B'].toString() + '\n'
      'C. ' + record['C'].toString() + '\n'
      'D. ' + record['D'].toString() + '\n\n'
      'Answer:';
}

String? extractAnswer(String text) {
  if (text.trim().isEmpty) return null;
  final trimmed = text.trim();
  final afterThink = trimmed.split(RegExp(r'</think>'));
  final searchText =
      afterThink.length > 1 ? afterThink.last.trim() : trimmed;
  final first = RegExp(r'\b([A-D])\b').firstMatch(searchText);
  if (first != null) return first.group(1);
  if (searchText.isNotEmpty && 'ABCD'.contains(searchText[0])) {
    return searchText[0];
  }
  final fallback = RegExp(r'\b([A-D])\b').firstMatch(trimmed);
  return fallback?.group(1);
}

Future<void> saveCache(File destination, Map<String, dynamic> cache) async {
  final temporary = File(destination.path + '.tmp');
  await temporary.writeAsString(jsonEncode(cache), flush: true);
  await temporary.rename(destination.path);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('benchmark-eval-workspace Natural Fertilizers 225-question Pixel 7 ladder',
      (tester) async {
    final modelService = ModelService();
    await modelService.downloadModel(onProgress: (progress, status) {
      if (status.contains('complete') || progress >= 0.99) {
        // ignore: avoid_print
        print('[NF_BENCH] model: ' + status + ' (' + progress.toString() + ')');
      }
    });
    await modelService.initializeModel();

    final docDir = await getApplicationDocumentsDirectory();
    final benchmarkFile = File(docDir.path + '/benchmark_combined.jsonl');
    expect(await benchmarkFile.exists(), isTrue,
        reason: 'stage benchmark_combined.jsonl into app documents before running');

    final cacheFile = File(
        docDir.path + '/qwen35-natural-fertilizers-cq4-pixel7-cache.json');
    final cache = <String, dynamic>{};
    if (await cacheFile.exists()) {
      final existing = jsonDecode(await cacheFile.readAsString());
      if (existing is Map<String, dynamic>) cache.addAll(existing);
    }

    final lines = await benchmarkFile.readAsLines();
    final records = lines
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .where((record) =>
            record['category'] == 'Natural Fertilizers Benchmark')
        .toList();
    expect(records.length, 225,
        reason: 'use the current benchmark-eval-workspace Natural Fertilizers subset');

    final lm = modelService.lm!;
    var done = 0;
    var errors = 0;
    for (final record in records) {
      final id = record['question_id'].toString();
      final cachedEntry = cache[id];
      if (cachedEntry is! Map ||
          !cachedEntry.containsKey('generation_metrics')) {
        String? rawResponse;
        String? error;
        Map<String, dynamic>? generationMetrics;
        try {
          final result = await lm.generateCompletion(
            messages: [
              ChatMessage(content: systemPrompt, role: 'system'),
              ChatMessage(content: buildPrompt(record), role: 'user'),
            ],
            params: CactusCompletionParams(maxTokens: 16, temperature: 0),
          );
          rawResponse = result.response;
          generationMetrics = {
            'time_to_first_token_ms': result.timeToFirstTokenMs,
            'total_time_ms': result.totalTimeMs,
            'tokens_per_second': result.tokensPerSecond,
            'prefill_tokens': result.prefillTokens,
            'decode_tokens': result.decodeTokens,
            'total_tokens': result.totalTokens,
          };
          if (!result.success) error = 'generation reported success=false';
        } catch (e) {
          error = e.toString();
        }
        if (error != null) errors += 1;
        cache[id] = {
          'raw_response': rawResponse,
          'model_answer':
              error == null && rawResponse != null ? extractAnswer(rawResponse) : null,
          if (generationMetrics != null) 'generation_metrics': generationMetrics,
          if (error != null) 'error': error,
        };
        await saveCache(cacheFile, cache);
      }
      done += 1;
      if (done % 25 == 0) {
        // ignore: avoid_print
        print('[NF_BENCH] ' + done.toString() + '/' + records.length.toString() +
            ' complete; errors=' + errors.toString());
      }
    }

    final doneFile = File(
        docDir.path + '/qwen35-natural-fertilizers-cq4-pixel7-done.txt');
    await doneFile.writeAsString(
        'count=' + records.length.toString() +
        ' errors=' + errors.toString() +
        ' model=' + ModelService.modelSlug,
        flush: true);
    // ignore: avoid_print
    print('[NF_BENCH] DONE ' + records.length.toString() +
        '/' + records.length.toString() + '; errors=' + errors.toString());
    // Keep app data available long enough for adb run-as to pull the cache.
    await Future.delayed(const Duration(minutes: 3));
  }, timeout: const Timeout(Duration(hours: 16)));
}
