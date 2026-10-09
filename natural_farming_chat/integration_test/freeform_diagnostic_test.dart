// On-device counterpart to the GPU free-form generation run for #167's
// diagnostic: same 15 prompts from eval_freeform/dev.jsonl, no system
// prompt, matching autoresearch/generate_freeform_candidates.py's format
// (single user-turn message, enable_thinking false, temperature 0).
//
// Reads:  <appDocDir>/freeform_prompts.jsonl  (pushed via adb beforehand)
// Writes: <appDocDir>/freeform_results.json

import 'dart:convert';
import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:natural_farming_chat/services/model_service.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('freeform diagnostic (#167)', (tester) async {
    final modelService = ModelService();
    await modelService.downloadModel(onProgress: (progress, status) {
      // ignore: avoid_print
      print('[FREEFORM] download/init: $status ($progress)');
    });
    await modelService.initializeModel();

    final docDir = await getApplicationDocumentsDirectory();
    final promptsFile = File('${docDir.path}/freeform_prompts.jsonl');
    expect(await promptsFile.exists(), isTrue,
        reason: 'push freeform_prompts.jsonl to ${promptsFile.path} first');

    final lines = await promptsFile.readAsLines();
    final results = <Map<String, dynamic>>[];
    var done = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final item = jsonDecode(line) as Map<String, dynamic>;
      final question = item['question'] as String;

      final messages = [
        ChatMessage(content: ModelService.systemPrompt, role: 'system'),
        ChatMessage(content: question, role: 'user'),
      ];

      String rawResponse = '';
      String? errorMessage;
      double tokensPerSecond = 0.0;
      try {
        final result = await modelService.lm!.generateCompletion(
          messages: messages,
          params: CactusCompletionParams(
            maxTokens: ModelService.defaultMaxTokens,
            temperature: 0,
          ),
        );
        rawResponse = result.response;
        tokensPerSecond = result.tokensPerSecond;
        if (!result.success) {
          errorMessage = 'generation reported success=false';
        }
      } catch (e) {
        errorMessage = e.toString();
      }

      results.add({
        'id': item['id'],
        'question': question,
        'raw_response': rawResponse,
        'response_chars': rawResponse.length,
        'tokens_per_second': tokensPerSecond,
        'error': errorMessage,
      });

      done += 1;
      final outFile = File('${docDir.path}/freeform_results.json');
      await outFile.writeAsString(jsonEncode(results));
      // ignore: avoid_print
      print('[FREEFORM] $done/${lines.length} done');
    }

    // ignore: avoid_print
    print('[FREEFORM] DONE ${results.length}/${lines.length}');
    // ignore: avoid_print
    print('[FREEFORM] holding 60s for adb pull -- results file is final now');
    await Future.delayed(const Duration(seconds: 60));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
