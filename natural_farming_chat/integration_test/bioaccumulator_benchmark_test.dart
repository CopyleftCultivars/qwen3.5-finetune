import 'dart:convert';
import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:natural_farming_chat/services/bioaccumulator_ratio_service.dart';
import 'package:natural_farming_chat/services/calculator_service.dart';
import 'package:natural_farming_chat/services/fertilizer_formulation_service.dart';
import 'package:natural_farming_chat/services/model_service.dart';
import 'package:natural_farming_chat/services/plant_lookup_service.dart';
import 'package:natural_farming_chat/services/recipe_lookup_service.dart';
import 'package:natural_farming_chat/services/region_plant_service.dart';
import 'package:natural_farming_chat/services/tool_executor.dart';
import 'package:path_provider/path_provider.dart';

const String runMode = String.fromEnvironment(
  'BIOACCUMULATOR_MODE',
  defaultValue: 'decision',
);
const String runSplit = String.fromEnvironment(
  'BIOACCUMULATOR_SPLIT',
  defaultValue: 'development',
);
const String runTrial = String.fromEnvironment(
  'BIOACCUMULATOR_TRIAL',
  defaultValue: '1',
);

Map<String, dynamic> asStringMap(dynamic value) =>
    (value as Map).map((key, item) => MapEntry(key.toString(), item));

String sha256Text(String value) => sha256.convert(utf8.encode(value)).toString();

String checkpointKey(String caseId, int turn) => '$caseId::$turn';

Future<void> saveCheckpoint(File file, Map<String, dynamic> checkpoint) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  checkpoint['updated_at_utc'] = DateTime.now().toUtc().toIso8601String();
  await temporary.writeAsString(jsonEncode(checkpoint), flush: true);
  await temporary.rename(file.path);
}

Map<String, dynamic> serializeToolResult(ToolResult result) => {
      'tool_name': result.toolName,
      'success': result.success,
      'result': result.result,
      if (result.metadata != null) 'metadata': result.metadata,
    };

Map<String, dynamic> serializeMessage(ChatMessage message) => {
      'role': message.role,
      'content': message.content,
    };

Map<String, dynamic> nativeMetrics({
  required double wallTimeMs,
  required double timeToFirstTokenMs,
  required double totalTimeMs,
  required double tokensPerSecond,
  required int prefillTokens,
  required int decodeTokens,
  required int totalTokens,
}) => {
      'wall_time_ms': wallTimeMs,
      'time_to_first_token_ms': timeToFirstTokenMs,
      'cactus_total_time_ms': totalTimeMs,
      'tokens_per_second': tokensPerSecond,
      'prefill_tokens': prefillTokens,
      'decode_tokens': decodeTokens,
      'total_tokens': totalTokens,
    };

Future<void> markInterrupted(
  Map<String, dynamic> checkpoint,
  Map<String, dynamic> turnRecord,
  File checkpointFile,
  String phase,
) async {
  final error =
      'Interrupted during $phase. This generation was not repeated on resume.';
  turnRecord['status'] = 'interrupted';
  final errors = (turnRecord['errors'] as List?) ?? const [];
  turnRecord['errors'] = [...errors, error];
  await saveCheckpoint(checkpointFile, checkpoint);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Bioaccumulator benchmark $runMode / $runSplit / trial $runTrial',
    (tester) async {
      expect(['decision', 'app_e2e'].contains(runMode), isTrue,
          reason: 'BIOACCUMULATOR_MODE must be decision or app_e2e');
      expect(['development', 'validation', 'test'].contains(runSplit), isTrue,
          reason: 'BIOACCUMULATOR_SPLIT must be a frozen dataset split');

      final docs = await getApplicationDocumentsDirectory();
      final inputFile =
          File('${docs.path}/bioaccumulator_scenarios_$runSplit.jsonl');
      final hostMetadataFile = File('${docs.path}/bioaccumulator_run_metadata.json');
      expect(await inputFile.exists(), isTrue,
          reason: 'Use scripts/run_pixel7_benchmark.py to stage scenarios.');
      expect(await hostMetadataFile.exists(), isTrue,
          reason: 'Stage bioaccumulator_run_metadata.json with the runner.');

      final inputBytes = await inputFile.readAsBytes();
      final scenarioSha256 = sha256.convert(inputBytes).toString();
      final scenarios = utf8
          .decode(inputBytes)
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .map((line) => asStringMap(jsonDecode(line)))
          .toList();
      expect(scenarios, isNotEmpty);

      final hostMetadata =
          asStringMap(jsonDecode(await hostMetadataFile.readAsString()));
      final toolSchemaJson =
          jsonEncode(ModelService.farmingTools.map((tool) => tool.toJson()).toList());
      final cropAsset = await rootBundle.loadString(
        'assets/plant_data/Crop_Requirements.json',
      );
      final plantAsset = await rootBundle.loadString(
        'assets/plant_data/plant_mineral_profiles.json',
      );
      final appCommit = hostMetadata['app_commit']?.toString() ?? 'unknown';
      final modelHash =
          hostMetadata['model_artifact_sha256']?.toString() ?? 'unknown';

      final stableMetadata = <String, dynamic>{
        ...hostMetadata,
        'run_mode': runMode,
        'split': runSplit,
        'trial': runTrial,
        'model_slug': ModelService.modelSlug,
        'scenario_sha256': scenarioSha256,
        'tool_schema_sha256': sha256Text(toolSchemaJson),
        'app_data_sha256': {
          'Crop_Requirements.json': sha256Text(cropAsset),
          'plant_mineral_profiles.json': sha256Text(plantAsset),
        },
        'prompt': {
          'base_system_prompt_sha256': sha256Text(ModelService.systemPrompt),
          'path': 'ModelService.generateCompletionWithTools production prompt',
        },
        'inference_settings': {
          'max_tokens': ModelService.defaultMaxTokens,
          'temperature': null,
          'top_k': null,
          'top_p': null,
          'completion_mode': 'local',
          'model_slug': ModelService.modelSlug,
        },
        'execution': {
          'device_os': Platform.operatingSystem,
          'device_os_version': Platform.operatingSystemVersion,
          'dart_version': Platform.version,
          'qwen35_flavor': true,
          'embedding_router_initialized': false,
        },
        'tool_routing': runMode == 'decision'
            ? 'fixed ModelService.farmingTools passed explicitly'
            : 'production _routeTools called; Qwen3.5 flavor fails open to all tools without embeddings',
        'model_artifact_sha256': modelHash,
        'app_commit': appCommit,
      };
      final fingerprintInput = <String, dynamic>{
        'run_mode': stableMetadata['run_mode'],
        'split': stableMetadata['split'],
        'trial': stableMetadata['trial'],
        'model_slug': stableMetadata['model_slug'],
        'model_artifact_sha256': stableMetadata['model_artifact_sha256'],
        'app_commit': stableMetadata['app_commit'],
        'app_component_sha256': stableMetadata['app_component_sha256'],
        'app_build_inputs_sha256': stableMetadata['app_build_inputs_sha256'],
        'benchmark_commit': stableMetadata['benchmark_commit'],
        'scenario_sha256': stableMetadata['scenario_sha256'],
        'scenario_manifest_sha256': stableMetadata['scenario_manifest_sha256'],
        'tool_schema_sha256': stableMetadata['tool_schema_sha256'],
        'app_data_sha256': stableMetadata['app_data_sha256'],
        'device': stableMetadata['device'],
        'inference_settings': stableMetadata['inference_settings'],
      };
      final runFingerprint = sha256Text(jsonEncode(fingerprintInput));

      final suffix = '${runMode}_${runSplit}_trial_$runTrial';
      final checkpointFile =
          File('${docs.path}/bioaccumulator_$suffix.checkpoint.json');
      final resultsFile = File('${docs.path}/bioaccumulator_$suffix.results.json');
      final modelService = ModelService();
      final plantLookup = PlantLookupService();
      final regionPlants = RegionPlantService();
      final ratioService =
          BioaccumulatorRatioService(plantLookupService: plantLookup);
      final recipeLookup = RecipeLookupService(regionPlantService: regionPlants);
      final formulation = FertilizerFormulationService(
        regionService: regionPlants,
        plantLookupService: plantLookup,
      );
      final executor = ToolExecutor(
        plantLookupService: plantLookup,
        calculatorService: CalculatorService(),
        formulationService: formulation,
        bioaccumulatorRatioService: ratioService,
        recipeLookupService: recipeLookup,
      );

      var checkpoint = <String, dynamic>{
        'format_version': 1,
        'run_fingerprint': runFingerprint,
        'metadata': stableMetadata,
        'run_status': 'running',
        'created_at_utc': DateTime.now().toUtc().toIso8601String(),
        'turns': <String, dynamic>{},
      };
      if (await checkpointFile.exists()) {
        checkpoint = asStringMap(jsonDecode(await checkpointFile.readAsString()));
        expect(checkpoint['run_fingerprint'], runFingerprint,
            reason:
                'Checkpoint metadata differs. Use a new trial or remove the old checkpoint.');
      }
      final turnRecords = asStringMap(checkpoint['turns'] ?? <String, dynamic>{});
      checkpoint['turns'] = turnRecords;
      await saveCheckpoint(checkpointFile, checkpoint);

      try {
        await modelService.downloadModel(onProgress: (progress, status) {
          if (status.contains('complete') || progress >= 0.99) {
            // ignore: avoid_print
            print('[BIOACCUMULATOR] model: $status ($progress)');
          }
        });
        await modelService.initializeModel();
        await plantLookup.initialize();
        await regionPlants.initialize();
        await ratioService.initialize();
        await recipeLookup.initialize();

        var completedTurns = 0;
        var interruptedTurns = 0;
        var errors = 0;

        for (final scenario in scenarios) {
          final caseId = scenario['case_id'].toString();
          final turns = (scenario['turns'] as List).cast<Map>();
          final history = <ChatMessage>[];
          var scenarioInterrupted = false;

          for (final rawTurn in turns) {
            final turn = asStringMap(rawTurn);
            final turnNumber = (turn['turn'] as num).toInt();
            final key = checkpointKey(caseId, turnNumber);
            var record = turnRecords[key] == null
                ? <String, dynamic>{}
                : asStringMap(turnRecords[key]);
            if (turnRecords[key] != null) {
              turnRecords[key] = record;
            }

            if (record['status'] == 'complete') {
              final answer = record['final_answer']?.toString() ?? '';
              history.add(ChatMessage(content: turn['user'].toString(), role: 'user'));
              history.add(ChatMessage(content: answer, role: 'assistant'));
              completedTurns += 1;
              continue;
            }
            if (record['status'] == 'interrupted' ||
                record['decision_status'] == 'started' ||
                record['synthesis_status'] == 'started') {
              if (record['status'] != 'interrupted') {
                final phase = record['decision_status'] == 'started'
                    ? 'decision generation'
                    : 'final-answer generation';
                await markInterrupted(checkpoint, record, checkpointFile, phase);
                turnRecords[key] = record;
              }
              scenarioInterrupted = true;
              interruptedTurns += 1;
              break;
            }

            if (turnRecords[key] == null) {
              record = {
                'case_id': caseId,
                'split': scenario['split'],
                'template_family': scenario['template_family'],
                'slices': scenario['slices'],
                'turn': turnNumber,
                'user': turn['user'],
                'expected_action': turn['expected_action'],
                'earliest_eligible_call_turn':
                    turn['earliest_eligible_call_turn'],
                'expected_call': turn['expected_call'],
                'expected_tool_result': turn['expected_tool_result'],
                'final_answer_constraints': turn['final_answer_constraints'],
                'conversation_before': history.map(serializeMessage).toList(),
                'mode': runMode,
                'status': 'running',
                'errors': <String>[],
                'latency': <String, dynamic>{},
              };
              turnRecords[key] = record;
              await saveCheckpoint(checkpointFile, checkpoint);
            } else {
              record.putIfAbsent(
                'conversation_before',
                () => history.map(serializeMessage).toList(),
              );
            }

            Map<String, dynamic> decision = <String, dynamic>{};
            if (record['decision_status'] == 'complete') {
              decision = asStringMap(record['decision']);
            } else {
              record['decision_status'] = 'started';
              record['decision_started_at_utc'] =
                  DateTime.now().toUtc().toIso8601String();
              await saveCheckpoint(checkpointFile, checkpoint);
              final watch = Stopwatch()..start();
              try {
                final result = await modelService.generateCompletionWithTools(
                  question: turn['user'].toString(),
                  conversationHistory: history.isEmpty ? null : history,
                  tools: runMode == 'decision' ? ModelService.farmingTools : null,
                );
                watch.stop();
                decision = {
                  'cleaned_response': result.response,
                  'native_response': result.rawResponse,
                  'tool_calls': result.toolCalls.map((call) => call.toJson()).toList(),
                  'available_tools': result.availableTools,
                  'metrics': nativeMetrics(
                    wallTimeMs: watch.elapsedMicroseconds / 1000.0,
                    timeToFirstTokenMs: result.timeToFirstTokenMs,
                    totalTimeMs: result.totalTimeMs,
                    tokensPerSecond: result.tokensPerSecond,
                    prefillTokens: result.prefillTokens,
                    decodeTokens: result.decodeTokens,
                    totalTokens: result.totalTokens,
                  ),
                };
                record['decision'] = decision;
                record['decision_status'] = 'complete';
                record['latency']['decision_wall_ms'] =
                    watch.elapsedMicroseconds / 1000.0;
                await saveCheckpoint(checkpointFile, checkpoint);
              } catch (error) {
                watch.stop();
                final message = error.toString();
                record['decision_status'] = 'failed';
                record['latency']['decision_wall_ms'] =
                    watch.elapsedMicroseconds / 1000.0;
                final priorErrors = (record['errors'] as List?) ?? const [];
                record['errors'] = [...priorErrors, message];
                record['final_answer'] = 'Sorry, I encountered an error: $message';
                record['status'] = 'complete';
                errors += 1;
                await saveCheckpoint(checkpointFile, checkpoint);
                history.add(ChatMessage(content: turn['user'].toString(), role: 'user'));
                history.add(ChatMessage(
                  content: record['final_answer'].toString(),
                  role: 'assistant',
                ));
                completedTurns += 1;
                continue;
              }
            }

            final callJson = (decision['tool_calls'] as List? ?? const [])
                .map((item) => asStringMap(item))
                .toList();
            final calls = callJson.map(ToolCall.fromJson).toList();
            var finalAnswer = decision['cleaned_response']?.toString() ?? '';

            if (calls.isNotEmpty) {
              if (record['executor_status'] != 'complete') {
                record['executor_status'] = 'started';
                record['executor_started_at_utc'] =
                    DateTime.now().toUtc().toIso8601String();
                await saveCheckpoint(checkpointFile, checkpoint);
                final watch = Stopwatch()..start();
                try {
                  final toolResults = await executor.executeAll(calls);
                  watch.stop();
                  record['tool_results'] =
                      toolResults.map(serializeToolResult).toList();
                  record['executor_status'] = 'complete';
                  record['latency']['tool_execution_wall_ms'] =
                      watch.elapsedMicroseconds / 1000.0;
                  record['tool_result_context'] =
                      executor.formatResultsForPrompt(toolResults);
                  await saveCheckpoint(checkpointFile, checkpoint);
                } catch (error) {
                  watch.stop();
                  final message = error.toString();
                  record['executor_status'] = 'failed';
                  record['latency']['tool_execution_wall_ms'] =
                      watch.elapsedMicroseconds / 1000.0;
                  final priorErrors = (record['errors'] as List?) ?? const [];
                  record['errors'] = [...priorErrors, message];
                  finalAnswer = 'Sorry, I encountered an error: $message';
                  record['final_answer'] = finalAnswer;
                  record['status'] = 'complete';
                  errors += 1;
                  await saveCheckpoint(checkpointFile, checkpoint);
                  history.add(ChatMessage(content: turn['user'].toString(), role: 'user'));
                  history.add(ChatMessage(content: finalAnswer, role: 'assistant'));
                  completedTurns += 1;
                  continue;
                }
              }

              if (record['synthesis_status'] == 'started') {
                await markInterrupted(
                  checkpoint,
                  record,
                  checkpointFile,
                  'final-answer generation',
                );
                scenarioInterrupted = true;
                interruptedTurns += 1;
                break;
              }
              if (record['synthesis_status'] == 'complete') {
                finalAnswer = record['synthesis']['cleaned_response'].toString();
              } else {
                record['synthesis_status'] = 'started';
                record['synthesis_started_at_utc'] =
                    DateTime.now().toUtc().toIso8601String();
                await saveCheckpoint(checkpointFile, checkpoint);
                final synthesisWatch = Stopwatch()..start();
                try {
                  final synthesis = await modelService.generateCompletion(
                    question: turn['user'].toString(),
                    context: record['tool_result_context'].toString(),
                    conversationHistory: history.isEmpty ? null : history,
                  );
                  synthesisWatch.stop();
                  finalAnswer = synthesis.response;
                  record['synthesis'] = {
                    'cleaned_response': synthesis.response,
                    'native_response': synthesis.rawResponse,
                    'metrics': nativeMetrics(
                      wallTimeMs: synthesisWatch.elapsedMicroseconds / 1000.0,
                      timeToFirstTokenMs: synthesis.timeToFirstTokenMs,
                      totalTimeMs: synthesis.totalTimeMs,
                      tokensPerSecond: synthesis.tokensPerSecond,
                      prefillTokens: synthesis.prefillTokens,
                      decodeTokens: synthesis.decodeTokens,
                      totalTokens: synthesis.totalTokens,
                    ),
                  };
                  record['synthesis_status'] = 'complete';
                  record['latency']['synthesis_wall_ms'] =
                      synthesisWatch.elapsedMicroseconds / 1000.0;
                  await saveCheckpoint(checkpointFile, checkpoint);
                } catch (error) {
                  synthesisWatch.stop();
                  final message = error.toString();
                  record['synthesis_status'] = 'failed';
                  record['latency']['synthesis_wall_ms'] =
                      synthesisWatch.elapsedMicroseconds / 1000.0;
                  final priorErrors = (record['errors'] as List?) ?? const [];
                  record['errors'] = [...priorErrors, message];
                  finalAnswer = 'Sorry, I encountered an error: $message';
                  errors += 1;
                  record['final_answer'] = finalAnswer;
                  record['status'] = 'complete';
                  await saveCheckpoint(checkpointFile, checkpoint);
                  history.add(ChatMessage(
                    content: turn['user'].toString(),
                    role: 'user',
                  ));
                  history.add(ChatMessage(content: finalAnswer, role: 'assistant'));
                  completedTurns += 1;
                  continue;
                }
              }
            }

            record['final_answer'] = finalAnswer;
            record['status'] = 'complete';
            await saveCheckpoint(checkpointFile, checkpoint);
            history.add(ChatMessage(content: turn['user'].toString(), role: 'user'));
            history.add(ChatMessage(content: finalAnswer, role: 'assistant'));
            completedTurns += 1;

            if (completedTurns % 5 == 0) {
              // ignore: avoid_print
              print(
                '[BIOACCUMULATOR] $completedTurns turns checkpointed; '
                'errors=$errors, interrupted=$interruptedTurns',
              );
            }
          }

          if (scenarioInterrupted) {
            // Do not generate later turns without the missing assistant context.
            continue;
          }
        }

        final allTurnRecords = asStringMap(checkpoint['turns']);
        final statusCounts = <String, int>{};
        for (final item in allTurnRecords.values) {
          final status = asStringMap(item)['status']?.toString() ?? 'missing';
          statusCounts[status] = (statusCounts[status] ?? 0) + 1;
        }
        final expectedTurnCount = scenarios.fold<int>(
          0,
          (sum, scenario) => sum + (scenario['turns'] as List).length,
        );
        checkpoint['run_status'] = allTurnRecords.length == expectedTurnCount &&
                statusCounts.keys.every((status) => status == 'complete')
            ? 'complete'
            : 'incomplete_or_interrupted';
        checkpoint['summary'] = {
          'scenario_count': scenarios.length,
          'expected_turn_count': expectedTurnCount,
          'checkpointed_turn_count': allTurnRecords.length,
          'turn_status_counts': statusCounts,
          'generation_errors_this_launch': errors,
          'interrupted_turns_this_launch': interruptedTurns,
        };
        await saveCheckpoint(checkpointFile, checkpoint);
        await resultsFile.writeAsString(jsonEncode(checkpoint), flush: true);
        // ignore: avoid_print
        print('[BIOACCUMULATOR] checkpoint: ${checkpointFile.path}');
        // ignore: avoid_print
        print('[BIOACCUMULATOR] results: ${resultsFile.path}');
        // Give the host runner time to pull the private app files after Flutter exits.
        await Future.delayed(const Duration(minutes: 2));
      } finally {
        modelService.dispose();
      }
    },
    timeout: const Timeout(Duration(hours: 48)),
  );
}
