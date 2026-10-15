import 'dart:async';
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
const String runContextStrategy = String.fromEnvironment(
  'BIOACCUMULATOR_CONTEXT_STRATEGY',
  defaultValue: 'full_history',
);
const String runKvCacheStrategy = String.fromEnvironment(
  'BIOACCUMULATOR_KV_CACHE_STRATEGY',
  defaultValue: 'reset_each_decision',
);
const int turnTimeoutSeconds = int.fromEnvironment(
  'BIOACCUMULATOR_TURN_TIMEOUT_SECONDS',
  defaultValue: 300,
);
const int startupTimeoutSeconds = int.fromEnvironment(
  'BIOACCUMULATOR_STARTUP_TIMEOUT_SECONDS',
  defaultValue: 300,
);
const int runTimeoutSeconds = int.fromEnvironment(
  'BIOACCUMULATOR_RUN_TIMEOUT_SECONDS',
  defaultValue: 21600,
);

Map<String, dynamic> asStringMap(dynamic value) =>
    (value as Map).map((key, item) => MapEntry(key.toString(), item));

String sha256Text(String value) => sha256.convert(utf8.encode(value)).toString();

String checkpointKey(String caseId, int turn) => '$caseId::$turn';

const Set<String> contextStrategies = {
  'full_history',
  'bounded_history',
  'structured_state',
  'trim_tool_results',
};
const Set<String> kvCacheStrategies = {
  'reset_each_decision',
  'prefill_system_reuse',
};

const int boundedHistoryMessageLimit = 2;

class PromptContextSelection {
  final List<ChatMessage>? history;
  final String? context;
  final Map<String, dynamic> profile;

  const PromptContextSelection({
    required this.history,
    required this.context,
    required this.profile,
  });
}

List<String> matchingNames(String text, Iterable<String> vocabulary) {
  final candidates = <({String name, int start, int end})>[];
  final ordered = vocabulary.toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final name in ordered) {
    if (name.trim().isEmpty) continue;
    final pattern = RegExp(RegExp.escape(name), caseSensitive: false);
    for (final match in pattern.allMatches(text)) {
      final start = match.start;
      final end = match.end;
      final before = start == 0 ? '' : text[start - 1];
      final after = end == text.length ? '' : text[end];
      bool isWord(String value) =>
          value.isNotEmpty && RegExp(r'[A-Za-z0-9]').hasMatch(value);
      if (isWord(before) || isWord(after)) continue;
      candidates.add((name: name, start: start, end: end));
    }
  }
  candidates.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    return b.name.length.compareTo(a.name.length);
  });
  final selected = <({String name, int start, int end})>[];
  for (final candidate in candidates) {
    if (selected.any(
      (other) => candidate.start < other.end && candidate.end > other.start,
    )) {
      continue;
    }
    selected.add(candidate);
  }
  selected.sort((a, b) => a.start.compareTo(b.start));
  final names = <String>[];
  for (final candidate in selected) {
    if (!names.any(
      (name) => name.toLowerCase() == candidate.name.toLowerCase(),
    )) {
      names.add(candidate.name);
    }
  }
  return names;
}

({List<String> crops, List<String> plants}) entityMentionsIn(
  String text,
  List<String> cropVocabulary,
  List<String> plantVocabulary,
) {
  var crops = matchingNames(text, cropVocabulary);
  var plants = matchingNames(text, plantVocabulary);
  final mentionsCrop = RegExp(
    r'\b(crop|vegetable|fruit|bed|requirements)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final mentionsPlant = RegExp(
    r'\b(plant|tissue|sample|accumulator|species|growing)\b',
    caseSensitive: false,
  ).hasMatch(text);
  bool sameName(String left, String right) =>
      left.toLowerCase() == right.toLowerCase();
  if (mentionsCrop && !mentionsPlant) {
    plants = plants
        .where((plant) => !crops.any((crop) => sameName(crop, plant)))
        .toList();
  } else if (mentionsPlant && !mentionsCrop) {
    crops = crops
        .where((crop) => !plants.any((plant) => sameName(crop, plant)))
        .toList();
  } else if (mentionsCrop && mentionsPlant) {
    final plantSpecific = plants
        .where((plant) => !crops.any((crop) => sameName(plant, crop)))
        .toList();
    if (plantSpecific.isNotEmpty) plants = plantSpecific;
  }
  return (crops: crops, plants: plants);
}

List<String> _uniqueInOrder(Iterable<String> values) {
  final result = <String>[];
  for (final value in values) {
    if (!result.any(
      (existing) => existing.toLowerCase() == value.toLowerCase(),
    )) {
      result.add(value);
    }
  }
  return result;
}

String? compactToolResult(Map<String, dynamic> result) {
  final toolName = result['tool_name']?.toString() ?? 'tool';
  final success = result['success'] == true;
  final raw = result['result']?.toString().trim() ?? '';
  if (toolName == 'bioaccumulator_ratio' && success) {
    final header = RegExp(
      r'^Bioaccumulator ratio:\s*(.+?)\s+vs\.\s+(.+)$',
      multiLine: true,
    ).firstMatch(raw);
    final ratios = <String>[];
    for (final match in RegExp(
      r'^\s*(phosphorus|potassium):\s*([^\n]+)$',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(raw)) {
      ratios.add('${match.group(1)!.toLowerCase()}=${match.group(2)!.trim()}');
    }
    final notComparable = RegExp(
      r'^Not comparable:\s*([^\n]+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(raw)?.group(1)?.trim();
    final entities = header == null
        ? ''
        : '${header.group(1)} vs ${header.group(2)}';
    return 'Completed bioaccumulator comparison: $entities; '
        '${ratios.join('; ')}'
        '${notComparable == null ? '' : '; not comparable: $notComparable'}. '
        'Relative signal, not a fertilizer dose.';
  }
  final normalized = raw.replaceAll(RegExp(r'\s+'), ' ');
  final excerpt = normalized.length <= 240
      ? normalized
      : '${normalized.substring(0, 237)}...';
  return 'Earlier $toolName result (${success ? 'success' : 'error'}): $excerpt';
}

String? compactTurnToolResults(Map<String, dynamic> record) {
  final rawResults = record['tool_results'];
  if (rawResults is! List || rawResults.isEmpty) return null;
  final summaries = rawResults
      .whereType<Map>()
      .map((value) => compactToolResult(asStringMap(value)))
      .whereType<String>()
      .toList();
  return summaries.isEmpty ? null : summaries.join('\n');
}

PromptContextSelection selectPromptContext({
  required List<ChatMessage> history,
  required Map<int, String> toolResultSummaries,
  required String currentQuestion,
  required List<String> cropNames,
  required List<String> cropScientificNames,
  required List<String> plantNames,
}) {
  final originalChars = history.fold<int>(
    0,
    (total, message) => total + message.content.length,
  );
  var selectedHistory = List<ChatMessage>.of(history);
  String? context;
  if (runContextStrategy == 'bounded_history' &&
      selectedHistory.length > boundedHistoryMessageLimit) {
    selectedHistory = selectedHistory.sublist(
      selectedHistory.length - boundedHistoryMessageLimit,
    );
  } else if (runContextStrategy == 'trim_tool_results') {
    selectedHistory = [
      for (var index = 0; index < history.length; index++)
        toolResultSummaries.containsKey(index)
            ? ChatMessage(
                content: toolResultSummaries[index]!,
                role: history[index].role,
              )
            : history[index],
    ];
  } else if (runContextStrategy == 'structured_state') {
    final userTexts =
        history
            .where((message) => message.role == 'user')
            .map((message) => message.content)
            .toList()
          ..add(currentQuestion);
    final cropVocabulary = [...cropNames, ...cropScientificNames];
    final observedEntities = userTexts
        .map((text) => entityMentionsIn(text, cropVocabulary, plantNames))
        .toList();
    final cropMentions = _uniqueInOrder(
      observedEntities.expand((entities) => entities.crops),
    );
    final plantMentions = _uniqueInOrder(
      observedEntities.expand((entities) => entities.plants),
    );
    final currentEntities = entityMentionsIn(
      currentQuestion,
      cropVocabulary,
      plantNames,
    );
    final currentCrops = currentEntities.crops;
    final currentPlants = currentEntities.plants;
    final assistantMessages = history
        .where((message) => message.role == 'assistant')
        .toList();
    final priorClarification = assistantMessages.isEmpty
        ? null
        : assistantMessages.last;
    final clarifiedSlot = priorClarification == null
        ? null
        : _clarificationSlot(priorClarification.content);
    final activeCrops = clarifiedSlot == 'crop' && currentCrops.length == 1
        ? currentCrops
        : currentCrops.isNotEmpty
        ? currentCrops
        : cropMentions;
    final activePlants =
        clarifiedSlot == 'candidate_plant' && currentPlants.length == 1
        ? currentPlants
        : currentPlants.isNotEmpty
        ? currentPlants
        : plantMentions;
    final isComparisonRequest = RegExp(
      r'\b(compare|comparison|bioaccumulat\w*|ratio|against|P/K|phosphorus|potassium)\b',
      caseSensitive: false,
    ).hasMatch(currentQuestion);
    final unresolved = <String>[];
    if (isComparisonRequest || clarifiedSlot != null) {
      if (activeCrops.isEmpty || activeCrops.length > 1) {
        unresolved.add('crop');
      }
      if (activePlants.isEmpty || activePlants.length > 1) {
        unresolved.add('candidate_plant');
      }
    }
    final correctionMessages = userTexts
        .where(
          (text) => RegExp(
            r'\b(correction|correct(?:ion)?|actually|instead|i meant|rather than)\b',
            caseSensitive: false,
          ).hasMatch(text),
        )
        .toList();
    final completedResults = toolResultSummaries.values
        .toList()
        .reversed
        .toList();
    final lines = <String>[
      'Conversation state derived from prior user messages and actual tool results:',
      'crop: ${activeCrops.isEmpty ? 'unknown' : activeCrops.join(' | ')}',
      'candidate_plant: ${activePlants.isEmpty ? 'unknown' : activePlants.join(' | ')}',
      'unresolved slots: ${unresolved.isEmpty ? 'none identified' : unresolved.join(', ')}',
      'corrections: ${correctionMessages.isEmpty ? 'none identified' : correctionMessages.take(3).join(' | ')}',
      'completed tool results: ${completedResults.isEmpty ? 'none' : completedResults.take(3).join(' | ')}',
      'Use the latest explicit correction; ask about unresolved or ambiguous slots before calculating.',
    ];
    context = lines.join('\n');
    selectedHistory = <ChatMessage>[];
  }
  final selectedChars = selectedHistory.fold<int>(
    0,
    (total, message) => total + message.content.length,
  );
  return PromptContextSelection(
    history: selectedHistory.isEmpty ? null : selectedHistory,
    context: context,
    profile: {
      'strategy': runContextStrategy,
      'history_message_count_before': history.length,
      'history_message_count_used': selectedHistory.length,
      'history_chars_before': originalChars,
      'history_chars_used': selectedChars,
      'context_chars_added': context?.length ?? 0,
      'tool_result_messages_transformed':
          runContextStrategy == 'trim_tool_results'
          ? toolResultSummaries.length
          : 0,
      'tool_results_carried_in_state': runContextStrategy == 'structured_state'
          ? toolResultSummaries.length
          : 0,
      if (runContextStrategy == 'bounded_history')
        'bounded_history_message_limit': boundedHistoryMessageLimit,
    },
  );
}

String? _clarificationSlot(String text) {
  final asks = RegExp(
    r'\b(which|what|specify|provide|tell me|name)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (!asks) return null;
  if (RegExp(
    r'\b(crop|vegetable|fruit)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'crop';
  }
  if (RegExp(
    r'\b(plant|species|accumulator|candidate)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'candidate_plant';
  }
  return null;
}

void appendHistoryTurn(
  List<ChatMessage> history,
  Map<int, String> toolResultSummaries,
  String user,
  String assistant, {
  String? toolResultSummary,
}) {
  final assistantIndex = history.length + 1;
  history.add(ChatMessage(content: user, role: 'user'));
  history.add(ChatMessage(content: assistant, role: 'assistant'));
  if (toolResultSummary != null) {
    toolResultSummaries[assistantIndex] = toolResultSummary;
  }
}

Future<void> saveCheckpoint(File file, Map<String, dynamic> checkpoint) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  checkpoint['updated_at_utc'] = DateTime.now().toUtc().toIso8601String();
  await temporary.writeAsString(jsonEncode(checkpoint), flush: true);
  await temporary.rename(file.path);
}

void printLifecycleEvent(
  String stage,
  String status, {
  String? launchId,
  Map<String, dynamic> details = const <String, dynamic>{},
}) {
  final event = <String, dynamic>{
    'stage': stage,
    'status': status,
    if (launchId != null) 'launch_id': launchId,
    'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
    if (details.isNotEmpty) 'details': details,
  };
  // ignore: avoid_print
  print('[BIOACCUMULATOR_LIFECYCLE] ${jsonEncode(event)}');
}

Future<void> recordLifecycleEvent(
  Map<String, dynamic> checkpoint,
  File checkpointFile,
  String stage,
  String status, {
  Map<String, dynamic> details = const <String, dynamic>{},
}) async {
  final events = (checkpoint['lifecycle_events'] as List?) ?? <dynamic>[];
  final event = <String, dynamic>{
    'stage': stage,
    'status': status,
    if (checkpoint['app_launch_id'] is String)
      'launch_id': checkpoint['app_launch_id'],
    'timestamp_utc': DateTime.now().toUtc().toIso8601String(),
    if (details.isNotEmpty) 'details': details,
  };
  events.add(event);
  checkpoint['lifecycle_events'] = events;
  await saveCheckpoint(checkpointFile, checkpoint);
  // ignore: avoid_print
  print('[BIOACCUMULATOR_LIFECYCLE] ${jsonEncode(event)}');
}

Future<void> saveResults(File resultsFile, Map<String, dynamic> checkpoint) async {
  await resultsFile.writeAsString(jsonEncode(checkpoint), flush: true);
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
  required double prefillTokensPerSecond,
  required double decodeTokensPerSecond,
  required int prefillTokens,
  required int decodeTokens,
  required int totalTokens,
  required Map<String, dynamic> promptProfile,
  double? firstStreamChunkMs,
  int streamChunkCount = 0,
  int streamOutputChars = 0,
}) {
  final estimatedPrefillMs = prefillTokensPerSecond > 0
      ? prefillTokens * 1000.0 / prefillTokensPerSecond
      : null;
  final estimatedDecodeMs = decodeTokensPerSecond > 0
      ? decodeTokens * 1000.0 / decodeTokensPerSecond
      : null;
  return {
    'metrics_schema_version': 2,
    'wall_time_ms': wallTimeMs,
    'time_to_first_token_ms': timeToFirstTokenMs,
    'cactus_total_time_ms': totalTimeMs,
    'wall_minus_cactus_total_ms': wallTimeMs - totalTimeMs,
    'tokens_per_second': tokensPerSecond,
    'prefill_tokens_per_second': prefillTokensPerSecond,
    'decode_tokens_per_second': decodeTokensPerSecond,
    'prefill_tokens': prefillTokens,
    'decode_tokens': decodeTokens,
    'total_tokens': totalTokens,
    'native_prefill_duration_estimate_ms': estimatedPrefillMs,
    'native_decode_duration_estimate_ms': estimatedDecodeMs,
    'ttft_minus_prefill_duration_estimate_ms': estimatedPrefillMs == null
        ? null
        : timeToFirstTokenMs - estimatedPrefillMs,
    'first_stream_chunk_minus_ttft_ms': firstStreamChunkMs == null
        ? null
        : firstStreamChunkMs - timeToFirstTokenMs,
    'prompt_profile': promptProfile,
    'first_stream_chunk_ms': firstStreamChunkMs,
    'stream_chunk_count': streamChunkCount,
    'stream_output_chars': streamOutputChars,
  };
}

class InferenceProgressReporter {
  final String stage;
  final Stopwatch watch;
  final Map<String, dynamic> checkpoint;
  final Map<String, dynamic> turnRecord;
  final File checkpointFile;
  late final Timer _heartbeat;
  Future<void> _pendingWrites = Future<void>.value();
  int _streamChunkCount = 0;
  int _streamOutputChars = 0;
  double? _firstStreamChunkMs;
  bool _finished = false;

  InferenceProgressReporter({
    required this.stage,
    required this.watch,
    required this.checkpoint,
    required this.turnRecord,
    required this.checkpointFile,
  }) {
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_finished) {
        timer.cancel();
      } else {
        _queueWrite();
      }
    });
  }

  void addChunk(String chunk) {
    if (_finished) return;
    _firstStreamChunkMs ??= watch.elapsedMicroseconds / 1000.0;
    _streamChunkCount += 1;
    _streamOutputChars += chunk.length;
    if (_streamChunkCount == 1 || _streamChunkCount % 64 == 0) {
      _queueWrite();
    }
  }

  double? get firstStreamChunkMs => _firstStreamChunkMs;
  int get streamChunkCount => _streamChunkCount;
  int get streamOutputChars => _streamOutputChars;

  Future<void> finish({String state = 'complete'}) async {
    _finished = true;
    _heartbeat.cancel();
    _queueWrite(stateOverride: state);
    await _pendingWrites;
  }

  void _queueWrite({String? stateOverride}) {
    final state = stateOverride ??
        (_firstStreamChunkMs == null
            ? 'waiting_for_first_chunk'
            : 'generating');
    final progress = <String, dynamic>{
      'stage': stage,
      'state': state,
      'elapsed_ms': watch.elapsedMicroseconds / 1000.0,
      'first_stream_chunk_ms': _firstStreamChunkMs,
      'stream_chunk_count': _streamChunkCount,
      'stream_output_chars': _streamOutputChars,
      'updated_at_utc': DateTime.now().toUtc().toIso8601String(),
    };
    _pendingWrites = _pendingWrites.then((_) async {
      turnRecord['inference_progress'] = progress;
      await saveCheckpoint(checkpointFile, checkpoint);
      // ignore: avoid_print
      print('[BIOACCUMULATOR_PROGRESS] ${jsonEncode(progress)}');
    }).catchError((Object error) {
      // Keep a progress-write error visible without hiding the native completion.
      // ignore: avoid_print
      print('[BIOACCUMULATOR_PROGRESS_ERROR] $error');
    });
  }
}

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
      final appStartupStartedAt = DateTime.now().toUtc().toIso8601String();
      final appLaunchId = appStartupStartedAt;
      printLifecycleEvent('app_startup', 'started', launchId: appLaunchId);
      CactusConfig.isTelemetryEnabled = false;
      expect(['decision', 'app_e2e'].contains(runMode), isTrue,
          reason: 'BIOACCUMULATOR_MODE must be decision or app_e2e');
      expect(['development', 'validation', 'test'].contains(runSplit), isTrue,
          reason: 'BIOACCUMULATOR_SPLIT must be a frozen dataset split');
      expect(contextStrategies.contains(runContextStrategy), isTrue,
          reason: 'BIOACCUMULATOR_CONTEXT_STRATEGY must be one of ${contextStrategies.join(', ')}');
      expect(kvCacheStrategies.contains(runKvCacheStrategy), isTrue,
          reason: 'BIOACCUMULATOR_KV_CACHE_STRATEGY must be one of ${kvCacheStrategies.join(', ')}');
      expect(
        runKvCacheStrategy != 'prefill_system_reuse' ||
            (runMode == 'decision' && runContextStrategy == 'full_history'),
        isTrue,
        reason: 'prefill_system_reuse requires decision mode and full_history',
      );

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
      final cropRows = (jsonDecode(cropAsset) as List).cast<Map>();
      final cropNames = cropRows
          .map((row) => row['Crop']?.toString() ?? '')
          .where((name) => name.trim().isNotEmpty)
          .toSet()
          .toList();
      final cropScientificNames = cropRows
          .map((row) => row['Scientific Name']?.toString() ?? '')
          .where((name) => name.trim().isNotEmpty)
          .toSet()
          .toList();
      final appCommit = hostMetadata['app_commit']?.toString() ?? 'unknown';
      final modelHash =
          hostMetadata['model_artifact_sha256']?.toString() ?? 'unknown';

      final stableMetadata = <String, dynamic>{
        ...hostMetadata,
        'run_mode': runMode,
        'split': runSplit,
        'trial': runTrial,
        'kv_cache_strategy': runKvCacheStrategy,
        'kv_cache_strategy_version': 'cactus-prefix-pilot-v1',
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
          'context_strategy': runContextStrategy,
          'context_strategy_version': 'context-strategies-v1',
          'context_strategy_parameters': {
            if (runContextStrategy == 'bounded_history')
              'max_history_messages': boundedHistoryMessageLimit,
            if (runContextStrategy == 'structured_state')
              'state_builder': 'dialogue-and-actual-tool-results-v1',
          },
        },
        'inference_settings': {
          'max_tokens': ModelService.defaultMaxTokens,
          'temperature': null,
          'top_k': null,
          'top_p': null,
          'completion_mode': 'local',
          'model_slug': ModelService.modelSlug,
        },
        'timing_budget_seconds': {
          'startup': startupTimeoutSeconds,
          'turn': turnTimeoutSeconds,
          'run': runTimeoutSeconds,
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
        'prompt': stableMetadata['prompt'],
        'kv_cache_strategy': stableMetadata['kv_cache_strategy'],
        'timing_budget_seconds': stableMetadata['timing_budget_seconds'],
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
      checkpoint['app_launch_id'] = appLaunchId;
      await saveCheckpoint(checkpointFile, checkpoint);
      await recordLifecycleEvent(
        checkpoint,
        checkpointFile,
        'app_startup',
        'started',
        details: {'started_at_utc': appStartupStartedAt},
      );
      await recordLifecycleEvent(
        checkpoint,
        checkpointFile,
        'app_startup',
        'complete',
        details: {'started_at_utc': appStartupStartedAt},
      );

      try {
        var initializationStage = 'model_download';
        try {
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            initializationStage,
            'started',
          );
          await modelService.downloadModel(onProgress: (progress, status) {
            if (status.contains('complete') || progress >= 0.99) {
              // ignore: avoid_print
              print('[BIOACCUMULATOR] model: $status ($progress)');
            }
          });
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            initializationStage,
            'complete',
          );

          initializationStage = 'model_initialization';
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            initializationStage,
            'started',
          );
          await modelService.initializeModel();
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            initializationStage,
            'complete',
          );

          initializationStage = 'tool_service_initialization';
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            initializationStage,
            'started',
          );
          await plantLookup.initialize();
          await regionPlants.initialize();
          await ratioService.initialize();
          await recipeLookup.initialize();
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            initializationStage,
            'complete',
          );
        } catch (error) {
          final message = error.toString();
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            initializationStage,
            'failed',
            details: {'error': message},
          );
          checkpoint['run_status'] = 'incomplete_or_interrupted';
          checkpoint['run_failure'] = {
            'classification':
                initializationStage == 'tool_service_initialization'
                    ? 'tool_service_initialization_failure'
                    : initializationStage == 'model_download'
                        ? 'model_download_failure'
                        : 'model_initialization_failure',
            'stage': initializationStage,
            'error': message,
          };
          await saveCheckpoint(checkpointFile, checkpoint);
          await saveResults(resultsFile, checkpoint);
          rethrow;
        }

        var completedTurns = 0;
        var interruptedTurns = 0;
        var decisionGenerationErrors = 0;
        var synthesisGenerationErrors = 0;
        var toolExecutionErrors = 0;

        for (final scenario in scenarios) {
          final caseId = scenario['case_id'].toString();
          final turns = (scenario['turns'] as List).cast<Map>();
          final history = <ChatMessage>[];
          final toolResultSummaries = <int, String>{};
          var scenarioInterrupted = false;

          if (runMode == 'decision') {
            modelService.resetInferenceContext();
            if (runKvCacheStrategy == 'prefill_system_reuse') {
              final prefillWatch = Stopwatch()..start();
              final prefill =
                  await modelService.prefillToolDecisionPrefixForBenchmark();
              prefillWatch.stop();
              final prefills = asStringMap(
                checkpoint['kv_cache_prefills'] ?? <String, dynamic>{},
              );
              prefills[caseId] = {
                'host_wall_ms': prefillWatch.elapsedMicroseconds / 1000.0,
                'prefix': 'fixed decision system message plus fixed tool catalog',
                'tool_schema_sha256': stableMetadata['tool_schema_sha256'],
                'tool_count': ModelService.farmingTools.length,
                'native': prefill,
              };
              checkpoint['kv_cache_prefills'] = prefills;
              await saveCheckpoint(checkpointFile, checkpoint);
              if (prefill['success'] != true) {
                final prefillError =
                    prefill['error']?.toString() ?? 'unknown error';
                throw StateError('Native cactus_prefill failed: $prefillError');
              }
            }
          }

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
              appendHistoryTurn(
                history,
                toolResultSummaries,
                turn['user'].toString(),
                answer,
                toolResultSummary: compactTurnToolResults(record),
              );
              completedTurns += 1;
              continue;
            }
            if (record['status'] == 'interrupted' ||
                record['status'] == 'timed_out' ||
                record['decision_status'] == 'started' ||
                record['synthesis_status'] == 'started') {
              if (record['status'] != 'interrupted' &&
                  record['status'] != 'timed_out') {
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
                'context_strategy': runContextStrategy,
                'kv_cache_strategy': runKvCacheStrategy,
                'decision_reset_before_completion':
                    runKvCacheStrategy == 'reset_each_decision',
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
              final progress = InferenceProgressReporter(
                stage: 'decision',
                watch: watch,
                checkpoint: checkpoint,
                turnRecord: record,
                checkpointFile: checkpointFile,
              );
              try {
                final promptContext = selectPromptContext(
                  history: history,
                  toolResultSummaries: toolResultSummaries,
                  currentQuestion: turn['user'].toString(),
                  cropNames: cropNames,
                  cropScientificNames: cropScientificNames,
                  plantNames: plantLookup.allPlantNames,
                );
                record['decision_context_profile'] = promptContext.profile;
                await saveCheckpoint(checkpointFile, checkpoint);
                final streamed = await modelService.generateCompletionWithToolsStream(
                  question: turn['user'].toString(),
                  context: promptContext.context,
                  conversationHistory: promptContext.history,
                  tools: runMode == 'decision' ? ModelService.farmingTools : null,
                  resetContextBeforeTools:
                      runKvCacheStrategy == 'reset_each_decision',
                );
                await for (final chunk in streamed.stream) {
                  progress.addChunk(chunk);
                }
                final result = await streamed.result;
                watch.stop();
                await progress.finish();
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
                    prefillTokensPerSecond: result.prefillTokensPerSecond,
                    decodeTokensPerSecond: result.decodeTokensPerSecond,
                    prefillTokens: result.prefillTokens,
                    decodeTokens: result.decodeTokens,
                    totalTokens: result.totalTokens,
                    promptProfile: result.promptProfile,
                    firstStreamChunkMs: progress.firstStreamChunkMs,
                    streamChunkCount: progress.streamChunkCount,
                    streamOutputChars: progress.streamOutputChars,
                  ),
                };
                record['decision'] = decision;
                record['decision_status'] = 'complete';
                record['latency']['decision_wall_ms'] =
                    watch.elapsedMicroseconds / 1000.0;
                await saveCheckpoint(checkpointFile, checkpoint);
              } catch (error) {
                watch.stop();
                await progress.finish(state: 'failed');
                final message = error.toString();
                record['decision_status'] = 'failed';
                record['latency']['decision_wall_ms'] =
                    watch.elapsedMicroseconds / 1000.0;
                final priorErrors = (record['errors'] as List?) ?? const [];
                record['errors'] = [...priorErrors, message];
                record['final_answer'] = 'Sorry, I encountered an error: $message';
                record['status'] = 'complete';
                decisionGenerationErrors += 1;
                await saveCheckpoint(checkpointFile, checkpoint);
                appendHistoryTurn(
                  history,
                  toolResultSummaries,
                  turn['user'].toString(),
                  record['final_answer'].toString(),
                );
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
                  toolExecutionErrors += 1;
                  await saveCheckpoint(checkpointFile, checkpoint);
                  appendHistoryTurn(
                    history,
                    toolResultSummaries,
                    turn['user'].toString(),
                    finalAnswer,
                  );
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
                final progress = InferenceProgressReporter(
                  stage: 'synthesis',
                  watch: synthesisWatch,
                  checkpoint: checkpoint,
                  turnRecord: record,
                  checkpointFile: checkpointFile,
                );
                try {
                  final promptContext = selectPromptContext(
                    history: history,
                    toolResultSummaries: toolResultSummaries,
                    currentQuestion: turn['user'].toString(),
                    cropNames: cropNames,
                    cropScientificNames: cropScientificNames,
                    plantNames: plantLookup.allPlantNames,
                  );
                  promptContext.profile['tool_result_context_chars'] =
                      record['tool_result_context'].toString().length;
                  record['synthesis_context_profile'] = promptContext.profile;
                  final synthesisContext = promptContext.context == null
                      ? record['tool_result_context'].toString()
                      : '${record['tool_result_context']}\n\n${promptContext.context}';
                  await saveCheckpoint(checkpointFile, checkpoint);
                  final streamed = await modelService.generateCompletionStreamWithMetrics(
                    question: turn['user'].toString(),
                    context: synthesisContext,
                    conversationHistory: promptContext.history,
                  );
                  await for (final chunk in streamed.stream) {
                    progress.addChunk(chunk);
                  }
                  final synthesis = await streamed.result;
                  synthesisWatch.stop();
                  await progress.finish();
                  finalAnswer = synthesis.response;
                  record['synthesis'] = {
                    'cleaned_response': synthesis.response,
                    'native_response': synthesis.rawResponse,
                    'metrics': nativeMetrics(
                      wallTimeMs: synthesisWatch.elapsedMicroseconds / 1000.0,
                      timeToFirstTokenMs: synthesis.timeToFirstTokenMs,
                      totalTimeMs: synthesis.totalTimeMs,
                      tokensPerSecond: synthesis.tokensPerSecond,
                      prefillTokensPerSecond:
                          synthesis.prefillTokensPerSecond,
                      decodeTokensPerSecond:
                          synthesis.decodeTokensPerSecond,
                      prefillTokens: synthesis.prefillTokens,
                      decodeTokens: synthesis.decodeTokens,
                      totalTokens: synthesis.totalTokens,
                      promptProfile: synthesis.promptProfile,
                      firstStreamChunkMs: progress.firstStreamChunkMs,
                      streamChunkCount: progress.streamChunkCount,
                      streamOutputChars: progress.streamOutputChars,
                    ),
                  };
                  record['synthesis_status'] = 'complete';
                  record['latency']['synthesis_wall_ms'] =
                      synthesisWatch.elapsedMicroseconds / 1000.0;
                  await saveCheckpoint(checkpointFile, checkpoint);
                } catch (error) {
                  synthesisWatch.stop();
                  await progress.finish(state: 'failed');
                  final message = error.toString();
                  record['synthesis_status'] = 'failed';
                  record['latency']['synthesis_wall_ms'] =
                      synthesisWatch.elapsedMicroseconds / 1000.0;
                  final priorErrors = (record['errors'] as List?) ?? const [];
                  record['errors'] = [...priorErrors, message];
                  finalAnswer = 'Sorry, I encountered an error: $message';
                  synthesisGenerationErrors += 1;
                  record['final_answer'] = finalAnswer;
                  record['status'] = 'complete';
                  await saveCheckpoint(checkpointFile, checkpoint);
                  appendHistoryTurn(
                    history,
                    toolResultSummaries,
                    turn['user'].toString(),
                    finalAnswer,
                    toolResultSummary: compactTurnToolResults(record),
                  );
                  completedTurns += 1;
                  continue;
                }
              }
            }

            record['final_answer'] = finalAnswer;
            record['status'] = 'complete';
            await saveCheckpoint(checkpointFile, checkpoint);
            appendHistoryTurn(
              history,
              toolResultSummaries,
              turn['user'].toString(),
              finalAnswer,
              toolResultSummary: compactTurnToolResults(record),
            );
            completedTurns += 1;

            if (completedTurns % 5 == 0) {
              // ignore: avoid_print
              print(
                '[BIOACCUMULATOR] $completedTurns turns checkpointed; '
                'decision_errors=$decisionGenerationErrors, '
                'synthesis_errors=$synthesisGenerationErrors, '
                'tool_errors=$toolExecutionErrors, '
                'interrupted=$interruptedTurns',
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
          'generation_errors_this_launch':
              decisionGenerationErrors + synthesisGenerationErrors,
          'decision_generation_errors_this_launch': decisionGenerationErrors,
          'synthesis_generation_errors_this_launch': synthesisGenerationErrors,
          'tool_execution_errors_this_launch': toolExecutionErrors,
          'interrupted_turns_this_launch': interruptedTurns,
        };
        await saveCheckpoint(checkpointFile, checkpoint);
        await saveResults(resultsFile, checkpoint);
        // ignore: avoid_print
        print('[BIOACCUMULATOR] checkpoint: ${checkpointFile.path}');
        // ignore: avoid_print
        print('[BIOACCUMULATOR] results: ${resultsFile.path}');
        // Keep the app alive briefly so the host runner can snapshot private result files.
        await Future.delayed(const Duration(seconds: 10));
      } finally {
        await recordLifecycleEvent(
          checkpoint,
          checkpointFile,
          'app_teardown',
          'started',
        );
        try {
          modelService.dispose();
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            'app_teardown',
            'complete',
          );
        } catch (error) {
          await recordLifecycleEvent(
            checkpoint,
            checkpointFile,
            'app_teardown',
            'failed',
            details: {'error': error.toString()},
          );
        }
        await saveResults(resultsFile, checkpoint);
      }
    },
    timeout: const Timeout(Duration(hours: 48)),
  );
}
