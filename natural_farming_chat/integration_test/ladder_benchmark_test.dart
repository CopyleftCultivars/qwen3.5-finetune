// On-device replication of benchmark-workspace/evaluate.py's protocol
// (same SYSTEM_PROMPT, PROMPT_TEMPLATE, and extract_answer regex) run
// against the currently-installed model bundle via the real ModelService/
// CactusLM path used in production -- not a UI-automation shortcut.
//
// Run with (model bundle must already be pushed to the app's model slug
// directory before this starts):
//   flutter test integration_test/ladder_benchmark_test.dart -d <device_id>
//
// Reads:  <appDocDir>/ladder_benchmark.jsonl  (pushed via adb beforehand)
// Writes: <appDocDir>/ladder_results.json

import 'dart:convert';
import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:natural_farming_chat/services/model_service.dart';
import 'package:path_provider/path_provider.dart';

const String kSystemPrompt =
    "You are a research assistant helping evaluate an academic agricultural "
    "science benchmark. Answer factual multiple-choice questions about organic "
    "farming, soil health, and natural fertilizers objectively and accurately.";

String buildPrompt(Map<String, dynamic> item) {
  return "Answer the following multiple-choice question about natural fertilizers "
      "and soil health. Reply with ONLY the single letter (A, B, C, or D) of "
      "the correct answer. Do not explain.\n\n"
      "Question: ${item['question']}\n"
      "A. ${item['A']}\n"
      "B. ${item['B']}\n"
      "C. ${item['C']}\n"
      "D. ${item['D']}\n\n"
      "Answer:";
}

// Mirrors evaluate.py's extract_answer exactly.
String? extractAnswer(String text) {
  if (text.trim().isEmpty) return null;
  final trimmed = text.trim();

  final afterThink = trimmed.split(RegExp(r'</think>'));
  final searchText =
      afterThink.length > 1 ? afterThink.last.trim() : trimmed;

  final m1 = RegExp(r'\b([A-D])\b').firstMatch(searchText);
  if (m1 != null) return m1.group(1);
  if (searchText.isNotEmpty && 'ABCD'.contains(searchText[0])) {
    return searchText[0];
  }

  final m2 = RegExp(r'\b([A-D])\b').firstMatch(trimmed);
  if (m2 != null) return m2.group(1);
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('natural_fertilizers 210-item ladder', (tester) async {
    final modelService = ModelService();
    await modelService.downloadModel(onProgress: (progress, status) {
      // ignore: avoid_print
      print('[LADDER] download/init: $status ($progress)');
    });
    await modelService.initializeModel();

    final docDir = await getApplicationDocumentsDirectory();
    final benchmarkFile = File('${docDir.path}/ladder_benchmark.jsonl');
    expect(await benchmarkFile.exists(), isTrue,
        reason: 'push the 210-item benchmark JSONL to '
            '${benchmarkFile.path} before running this test');

    final lines = await benchmarkFile.readAsLines();
    final results = <Map<String, dynamic>>[];
    var done = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final item = jsonDecode(line) as Map<String, dynamic>;
      final prompt = buildPrompt(item);

      final messages = [
        ChatMessage(content: kSystemPrompt, role: 'system'),
        ChatMessage(content: prompt, role: 'user'),
      ];

      String rawResponse = '';
      String? errorMessage;
      double tokensPerSecond = 0.0;
      try {
        final result = await modelService.lm!.generateCompletion(
          messages: messages,
          params: CactusCompletionParams(maxTokens: 16, temperature: 0),
        );
        rawResponse = result.response;
        tokensPerSecond = result.tokensPerSecond;
        if (!result.success) {
          errorMessage = 'generation reported success=false';
        }
      } catch (e) {
        errorMessage = e.toString();
      }

      final predicted = errorMessage == null ? extractAnswer(rawResponse) : null;
      final gold = item['answer'] as String?;

      results.add({
        'question_id': item['question_id'],
        'topic': item['topic'],
        'difficulty': item['difficulty'],
        'predicted': predicted,
        'gold': gold,
        'correct': predicted != null && predicted == gold,
        'raw_response': rawResponse,
        'tokens_per_second': tokensPerSecond,
        'error': errorMessage,
      });

      done += 1;
      // Write after every item (not just at the end): flutter test tears
      // down and uninstalls the app immediately after the test function
      // returns, which deletes app-private storage before a host-side
      // adb pull can happen. Incremental writes let a polling loop on the
      // host grab a complete-enough copy well before teardown.
      final outFile = File('${docDir.path}/ladder_results.json');
      await outFile.writeAsString(jsonEncode(results));
      if (done % 10 == 0) {
        // ignore: avoid_print
        print('[LADDER] $done/${lines.length} done');
      }
    }

    // ignore: avoid_print
    print('[LADDER] DONE ${results.length}/${lines.length}');

    // flutter test uninstalls the app (wiping app-private storage,
    // including the results file just written) the moment this function
    // returns. Hold here so a host-side `adb pull` has a guaranteed window
    // instead of racing teardown.
    // ignore: avoid_print
    print('[LADDER] holding 60s for adb pull -- results file is final now');
    await Future.delayed(const Duration(seconds: 60));
  }, timeout: const Timeout(Duration(hours: 3)));
}
