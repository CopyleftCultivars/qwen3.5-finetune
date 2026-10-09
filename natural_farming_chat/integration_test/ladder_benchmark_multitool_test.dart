// Multi-tool-augmented on-device replication of the natural_fertilizers
// 210-item ladder (chainlink #177), sibling to ladder_benchmark_test.dart.
//
// ladder_benchmark_test.dart calls the model with a raw MCQ prompt and no
// tools at all -- it measures the deployed champion's baseline. This harness
// instead mirrors qwen3-finetune/rlm_slice/multi_tool_context.py's
// controller-owned design (not the model self-initiating tool calls, which
// G9/#156 already found the 0.6B champion can't do reliably):
//
//   1. build a query from the MCQ's question+options (the ladder has no
//      structured crop/plant/region/problem fields, so this is the only
//      text available to key extraction off of);
//   2. extract heuristic arguments for each of the two domain tools via
//      ToolArgExtractor (closed-vocabulary substring match, no model call);
//   3. run every tool whose arguments were extractable (cheap, local,
//      deterministic) and check whether it produced real content --
//      "viable" mirrors multi_tool_context.py's `_has_real_content`;
//   4. rank viable tools via tool_router.dart (audit/log only -- #175's
//      dual-relevant eval found top-1 routing and inject-all-viable land on
//      identical aggregate accuracy, so this harness injects ALL viable
//      tools' output rather than gating further on rank);
//   5. inject the viable tools' formatted output into the prompt before
//      asking for the MCQ answer, same generation params as the baseline
//      harness so the two are comparable.
//
// Run with (model bundle must already be pushed; the embedding model is
// deliberately NOT initialized in this harness -- see the note by
// `embeddingReady` below -- so the routing audit's RRF-score field is
// always absent, but tool selection/injection itself does not need it):
//   flutter test integration_test/ladder_benchmark_multitool_test.dart -d <device_id>
//
// Reads:  <appDocDir>/ladder_benchmark.jsonl        (same file as the baseline harness)
// Writes: <appDocDir>/ladder_results_multitool.json

import 'dart:convert';
import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:natural_farming_chat/services/bioaccumulator_ratio_service.dart';
import 'package:natural_farming_chat/services/embedding_service.dart';
import 'package:natural_farming_chat/services/model_service.dart';
import 'package:natural_farming_chat/services/plant_lookup_service.dart';
import 'package:natural_farming_chat/services/recipe_lookup_service.dart';
import 'package:natural_farming_chat/services/region_plant_service.dart';
import 'package:natural_farming_chat/services/tool_arg_extractor.dart';
import 'package:natural_farming_chat/services/tool_router.dart' as tool_router;
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

/// Same prompt as the baseline harness, with any viable domain-tool output
/// inserted just before the "Answer:" cue.
String buildPromptWithContext(Map<String, dynamic> item, String toolContext) {
  final base = buildPrompt(item);
  if (toolContext.trim().isEmpty) return base;
  const marker = '\n\nAnswer:';
  final idx = base.lastIndexOf(marker);
  final head = idx >= 0 ? base.substring(0, idx) : base;
  return '$head\n\nRelevant tool information:\n$toolContext$marker';
}

// Mirrors evaluate.py's extract_answer exactly (same as ladder_benchmark_test.dart).
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

const _domainToolNames = {'bioaccumulator_ratio', 'regional_recipe_lookup'};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('natural_fertilizers 210-item ladder with multi-tool augmentation',
      (tester) async {
    final modelService = ModelService();
    await modelService.downloadModel(onProgress: (progress, status) {
      // ignore: avoid_print
      print('[LADDER_MT] chat model download/init: $status ($progress)');
    });
    await modelService.initializeModel();

    // Routing-audit RRF scores are skipped in this harness: initializing a
    // second live CactusLM context (the embedding model) alongside the
    // already-initialized chat model context reproducibly crashes the
    // native engine on-device (confirmed twice: "[CACTUS_INIT_DETAIL] C++
    // error: Failed to create model" immediately after the chat model
    // finishes initializing, killing the whole test process) -- the same
    // failure mode `model_service.dart` already documents for why semantic
    // tool filtering is disabled ("tries to generate embeddings using the
    // chat model which causes hangs"). Selection here never depended on
    // routing anyway (every viable tool is injected regardless of rank, per
    // #175's inject-all-viable finding), so this only costs the audit's
    // RRF-score field, not tool coverage.
    final embeddingService = EmbeddingService();
    const embeddingReady = false;

    final plantLookupService = PlantLookupService();
    await plantLookupService.initialize();
    final regionPlantService = RegionPlantService();
    await regionPlantService.initialize();
    final bioaccumulatorRatioService =
        BioaccumulatorRatioService(plantLookupService: plantLookupService);
    await bioaccumulatorRatioService.initialize();
    final recipeLookupService =
        RecipeLookupService(regionPlantService: regionPlantService);
    await recipeLookupService.initialize();

    final argExtractor = ToolArgExtractor(
      cropNames: bioaccumulatorRatioService.cropNames,
      plantNames: plantLookupService.allPlantNames,
      regionNames: regionPlantService.locationTerms,
    );

    final domainTools = ModelService.farmingTools
        .where((t) => _domainToolNames.contains(t.name))
        .toList();

    final docDir = await getApplicationDocumentsDirectory();
    final benchmarkFile = File('${docDir.path}/ladder_benchmark.jsonl');
    expect(await benchmarkFile.exists(), isTrue,
        reason: 'push the 210-item benchmark JSONL to '
            '${benchmarkFile.path} before running this test');

    final lines = await benchmarkFile.readAsLines();
    final results = <Map<String, dynamic>>[];
    var done = 0;
    var itemsWithViableTool = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final item = jsonDecode(line) as Map<String, dynamic>;

      final query = [item['question'], item['A'], item['B'], item['C'], item['D']]
          .map((v) => v?.toString() ?? '')
          .join(' ');

      // Extract + execute + gate-by-viability for each domain tool.
      final toolCallAudit = <Map<String, dynamic>>[];
      final viableResults = <String, String>{}; // tool name -> formatted message

      for (final tool in domainTools) {
        final args = argExtractor.extractArgs(tool.name, query);
        if (args == null) {
          toolCallAudit.add({'name': tool.name, 'args_available': false});
          continue;
        }

        String message;
        bool viable;
        if (tool.name == 'bioaccumulator_ratio') {
          final r = bioaccumulatorRatioService.compute(
            args['crop']!,
            args['candidate_plant']!,
          );
          viable = r.success && r.ratios.isNotEmpty;
          message = r.toMessage();
        } else {
          final r = recipeLookupService.lookup(
            crop: args['crop'],
            region: args['region'],
            problem: args['problem'],
          );
          viable = r.success &&
              (r.regionMatches.isNotEmpty ||
                  r.regionsGrowingCrop.isNotEmpty ||
                  r.matchingRecipes.isNotEmpty);
          message = r.toMessage();
        }

        toolCallAudit.add({
          'name': tool.name,
          'args_available': true,
          'args': args,
          'viable': viable,
        });
        if (viable) viableResults[tool.name] = message;
      }

      // Routing is audit/log only here (see file header) -- selection is
      // "inject all viable", so a routing failure never blocks the item.
      if (embeddingReady && viableResults.length > 1) {
        try {
          final viableTools =
              domainTools.where((t) => viableResults.containsKey(t.name)).toList();
          final routing = await tool_router.selectRelevantTools(
            query,
            viableTools,
            embedFn: embeddingService.generateEmbedding,
          );
          for (final s in routing.scores) {
            final idx = toolCallAudit.indexWhere((a) => a['name'] == s.name);
            if (idx != -1) toolCallAudit[idx]['rrf_score'] = s.rrfScore;
          }
        } catch (e) {
          // ignore: avoid_print
          print('[LADDER_MT] routing audit failed for ${item['question_id']} (non-fatal): $e');
        }
      }

      if (viableResults.isNotEmpty) itemsWithViableTool += 1;

      final toolContext =
          viableResults.entries.map((e) => '[${e.key}] ${e.value}').join('\n\n');
      final prompt = buildPromptWithContext(item, toolContext);

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
        'tools_used': viableResults.keys.toList(),
        'tool_calls': toolCallAudit,
      });

      done += 1;
      // Same incremental-write rationale as the baseline harness: flutter
      // test uninstalls the app immediately after this function returns,
      // wiping app-private storage before a host-side adb pull can happen.
      final outFile = File('${docDir.path}/ladder_results_multitool.json');
      await outFile.writeAsString(jsonEncode(results));
      if (done % 10 == 0) {
        // ignore: avoid_print
        print('[LADDER_MT] $done/${lines.length} done ($itemsWithViableTool with a viable tool so far)');
      }
    }

    // ignore: avoid_print
    print('[LADDER_MT] DONE ${results.length}/${lines.length}, '
        '$itemsWithViableTool items had at least one viable domain tool');

    // ignore: avoid_print
    print('[LADDER_MT] holding 60s for adb pull -- results file is final now');
    await Future.delayed(const Duration(seconds: 60));
  }, timeout: const Timeout(Duration(hours: 3)));
}
