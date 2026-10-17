import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cactus/cactus.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:path_provider/path_provider.dart';

import 'embedding_service.dart';
import 'tool_router.dart' as tool_router;

/// Service for managing CactusLM model operations
class ModelService {
  CactusLM? _lm;
  bool _isInitialized = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';

  /// Default maximum tokens for completions (increased from 512 to prevent truncation)
  static const int defaultMaxTokens = 2048;

  // Keep the production Qwen3 model and experimental Qwen3.5 bundle isolated
  // by Android flavor. Qwen3.5 is staged locally until a hosted bundle is set up.
  static const String _productionModelSlug =
      'qwen3-nf-distill-v2-cact-int4-ios';
  static const String _qwen35ModelSlug = 'qwen35-combined-cq4';
  static const String _qwen35StagingPath =
      '/data/local/tmp/qwen35-combined-cq4';
  static const String _productionModelDownloadUrl =
      'https://huggingface.co/CopyleftCultivars/localNFchatbot-cactus/resolve/main/qwen3-distill-v2-calibrated-cact-int4-ios.zip';

  static bool get _isQwen35Flavor => appFlavor == 'qwen35';
  static String get modelSlug =>
      _isQwen35Flavor ? _qwen35ModelSlug : _productionModelSlug;
  static const String systemPrompt = '''
You are a helpful farming assistant specializing in natural farming practices.
Answer questions based on the provided context. If you don't know the answer,
say so honestly. Provide practical, actionable advice when possible.''';

  /// Farming tools available for function calling
  static final List<CactusTool> farmingTools = [
    CactusTool(
      name: 'npk_lookup',
      description:
          'Look up the mineral profile of a plant including calcium, iron, potassium, phosphorus, magnesium, and other minerals across different plant parts (leaf, fruit, seed, root, etc.)',
      parameters: ToolParametersSchema(
        properties: {
          'plant': ToolParameter(
            type: 'string',
            description: 'Common name or scientific name of the plant',
            required: true,
          ),
        },
      ),
    ),
    CactusTool(
      name: 'calculate',
      description:
          'Perform mathematical calculations for fertilizer amounts, nutrient ratios, coverage area, or dilution rates',
      parameters: ToolParametersSchema(
        properties: {
          'expression': ToolParameter(
            type: 'string',
            description: 'Mathematical expression to evaluate',
            required: true,
          ),
          'context': ToolParameter(
            type: 'string',
            description:
                'Optional context describing what the calculation is for',
            required: false,
          ),
        },
      ),
    ),
    CactusTool(
      name: 'local_fertilizer_plants',
      description:
          'Create an organic fertilizer formulation using plants available '
          'in the user\'s region. Returns a complete blend with percentages, '
          'NPK values, and preparation instructions.',
      parameters: ToolParametersSchema(
        properties: {
          'location': ToolParameter(
            type: 'string',
            description: 'Country or region name',
            required: true,
          ),
          'nutrient': ToolParameter(
            type: 'string',
            description:
                'Target nutrient or growth stage: "nitrogen" (leafy/vegetative), '
                '"phosphorus" (flowering/roots), "potassium" (fruiting), '
                '"balanced", "vegetative", "flowering", "fruiting", or "seedling"',
            required: true,
          ),
        },
      ),
    ),
    // Two domain tools ported from the GPU-side multi-tool epic (chainlink
    // #174/#175/#177): bioaccumulator ratio calculation and combined
    // regional/recipe lookup. #175's dual-relevant eval found injecting the
    // right tool's content significantly improves MCQ accuracy over
    // retrieval-alone (McNemar chi2=6.125, p<0.05).
    CactusTool(
      name: 'bioaccumulator_ratio',
      description:
          'Compare a crop\'s NPK requirement against a candidate bioaccumulator '
          'plant\'s tissue mineral content (phosphorus and potassium only -- '
          'nitrogen is never comparable). Returns a relative ratio, not a '
          'calibrated fertilizer dosing formula, useful for judging whether a '
          'plant is nutrient-dense enough to cut as green manure or steep into '
          'a liquid feed.',
      parameters: ToolParametersSchema(
        properties: {
          'crop': ToolParameter(
            type: 'string',
            description: 'Crop name',
            required: true,
          ),
          'candidate_plant': ToolParameter(
            type: 'string',
            description:
                'Candidate bioaccumulator plant common or scientific name',
            required: true,
          ),
        },
      ),
    ),
    CactusTool(
      name: 'regional_recipe_lookup',
      description:
          'Look up candidate bioaccumulator plants native to a region and/or '
          'matching Korean Natural Farming (KNF) / JADAM technique or recipe '
          'for a crop or stated nutrient problem. At least one of crop, '
          'region, or problem must be given.',
      parameters: ToolParametersSchema(
        properties: {
          'crop': ToolParameter(
            type: 'string',
            description: 'Crop name, optional',
            required: false,
          ),
          'region': ToolParameter(
            type: 'string',
            description: 'Region or location name, optional',
            required: false,
          ),
          'problem': ToolParameter(
            type: 'string',
            description: 'Stated problem, optional',
            required: false,
          ),
        },
      ),
    ),
  ];

  bool get isInitialized => _isInitialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get downloadStatus => _downloadStatus;

  /// Get the underlying CactusLM instance for use by RagService
  /// Returns null if model is not downloaded yet
  CactusLM? get lm => _lm;

  /// Download the fine-tuned model directly from HuggingFace storage.
  /// Bypasses Cactus's Supabase slug registry since our model is not
  /// a built-in Cactus model.
  Future<void> downloadModel({
    required void Function(double progress, String status) onProgress,
  }) async {
    if (_isDownloading) return;

    _isDownloading = true;
    // NOTE: semantic tool filtering disabled - it tries to generate embeddings
    // using the chat model which causes hangs. With 3 tools, keyword-based
    // filtering could help but isn't critical yet.
    _lm = CactusLM(enableToolFiltering: false);

    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final modelFolder = Directory('${appDocDir.path}/models/$modelSlug');

      final configFile = File('${modelFolder.path}/config.txt');
      if (await configFile.exists()) {
        onProgress(1.0, 'Model already downloaded');
        return;
      }

      // The Qwen3.5 bundle is staged locally until it is hosted. Validate it
      // before replacing an incomplete private copy.
      final qwen35StagingFolder = Directory(_qwen35StagingPath);
      if (_isQwen35Flavor) {
        for (final requiredPath in [
          'config.txt',
          'vocab.txt',
          'components/manifest.json',
        ]) {
          if (!await File(
            '${qwen35StagingFolder.path}/$requiredPath',
          ).exists()) {
            throw ModelServiceException(
              'Qwen3.5 bundle is missing $requiredPath under '
              '${qwen35StagingFolder.path}. Stage outputs/qwen35-combined-cactus-cq4 there with adb push.',
            );
          }
        }
      }

      // Clean up any partial download/copy before starting fresh.
      if (await modelFolder.exists()) {
        await modelFolder.delete(recursive: true);
      }
      await modelFolder.create(recursive: true);

      if (_isQwen35Flavor) {
        await _copyQwen35Bundle(
          source: qwen35StagingFolder,
          destination: modelFolder,
          onProgress: onProgress,
        );
        return;
      }

      // Production Qwen3 bundle download.
      final zipPath = '${appDocDir.path}/models/$modelSlug.zip';
      final client = HttpClient();
      try {
        onProgress(0.0, 'Starting download...');
        final request = await client.getUrl(
          Uri.parse(_productionModelDownloadUrl),
        );
        final response = await request.close();

        if (response.statusCode != 200) {
          throw ModelServiceException(
            'Download failed: HTTP ${response.statusCode}',
          );
        }

        final contentLength = response.contentLength;
        final sink = File(zipPath).openWrite();
        int bytesReceived = 0;

        await for (final chunk in response) {
          sink.add(chunk);
          bytesReceived += chunk.length;
          if (contentLength > 0) {
            // Reserve 0–0.85 for download, 0.85–1.0 for extraction
            final downloadProgress = (bytesReceived / contentLength) * 0.85;
            _downloadProgress = downloadProgress;
            _downloadStatus =
                'Downloaded ${bytesReceived ~/ (1024 * 1024)} MB...';
            onProgress(_downloadProgress, _downloadStatus);
          }
        }
        await sink.close();
      } finally {
        client.close();
      }

      // Extract zip directly into the model folder
      onProgress(0.85, 'Extracting model files...');
      final inputStream = InputFileStream(zipPath);
      try {
        final archive = ZipDecoder().decodeStream(inputStream);
        for (final file in archive) {
          if (!file.isFile) continue;
          final outPath = '${modelFolder.path}/${file.name}';
          await File(outPath).parent.create(recursive: true);
          final outStream = OutputFileStream(outPath);
          file.writeContent(outStream);
          outStream.closeSync();
        }
      } finally {
        inputStream.close();
      }

      await File(zipPath).delete();
      onProgress(1.0, 'Download complete');
    } finally {
      _isDownloading = false;
    }
  }

  Future<void> _copyQwen35Bundle({
    required Directory source,
    required Directory destination,
    required void Function(double progress, String status) onProgress,
  }) async {
    final files = <File>[];
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) files.add(entity);
    }

    if (!files.any((file) => file.path.endsWith('.weights'))) {
      throw ModelServiceException(
        'Qwen3.5 bundle has no .weights files under ${source.path}.',
      );
    }

    final configFile = File('${source.path}/config.txt');
    files.removeWhere((file) => file.path == configFile.path);
    files.add(configFile); // Copy the completion marker last.

    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await file.length();
    }

    var copiedBytes = 0;
    for (final file in files) {
      final relativePath = file.path.substring(source.path.length + 1);
      final destinationFile = File('${destination.path}/$relativePath');
      await destinationFile.parent.create(recursive: true);
      final fileBytes = await file.length();
      await file.copy(destinationFile.path);
      copiedBytes += fileBytes;
      onProgress(
        totalBytes == 0 ? 1.0 : copiedBytes / totalBytes,
        'Copied ${copiedBytes ~/ (1024 * 1024)} MB of the Qwen3.5 model...',
      );
    }
  }

  /// Initialize the model for inference
  Future<void> initializeModel() async {
    if (_lm == null) {
      throw ModelServiceException(
        'Model not downloaded. Call downloadModel first.',
      );
    }

    if (_isInitialized) return;

    // Pass the published artifact slug explicitly — CactusInitParams defaults
    // to 'qwen3-0.6', which would point to the wrong model folder.
    try {
      await _lm!.initializeModel(params: CactusInitParams(model: modelSlug));
    } catch (e) {
      // Surface the native C++ error message for diagnosis
      final nativeError = _getLastNativeError();
      print('[MODEL_INIT_ERROR] Flutter exception: $e');
      print('[MODEL_INIT_ERROR] Native C++ error: $nativeError');
      rethrow;
    }
    _isInitialized = true;
  }

  /// Read the last error from libcactus.so via direct FFI
  static String _getLastNativeError() {
    try {
      final lib = DynamicLibrary.open(
        Platform.isAndroid ? 'libcactus.so' : 'cactus.framework/cactus',
      );
      final getLastError = lib
          .lookup<NativeFunction<Pointer<Utf8> Function()>>(
            'cactus_get_last_error',
          )
          .asFunction<Pointer<Utf8> Function()>();
      final ptr = getLastError();
      if (ptr.address == 0) return '(no error message)';
      return ptr.toDartString();
    } catch (e) {
      return '(could not read native error: $e)';
    }
  }

  /// Generate a completion with optional context and conversation history
  Future<CompletionResult> generateCompletion({
    required String question,
    String? context,
    bool agenticMode = false,
    List<ChatMessage>? conversationHistory,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }

    final systemContent = _buildSystemContent(context, agenticMode);

    final messages = [
      ChatMessage(content: systemContent, role: 'system'),
      if (conversationHistory != null) ...conversationHistory,
      ChatMessage(content: question, role: 'user'),
    ];

    final result = await _lm!.generateCompletion(
      messages: messages,
      params: CactusCompletionParams(maxTokens: defaultMaxTokens),
    );

    if (!result.success) {
      throw ModelServiceException('Generation failed: ${result.response}');
    }

    final cleanedResponse = _cleanResponse(result.response);

    return CompletionResult(
      response: cleanedResponse,
      tokensPerSecond: result.tokensPerSecond,
      prefillTokensPerSecond: result.prefillTokensPerSecond,
      decodeTokensPerSecond: result.decodeTokensPerSecond,
      rawResponse: result.response,
      timeToFirstTokenMs: result.timeToFirstTokenMs,
      totalTimeMs: result.totalTimeMs,
      prefillTokens: result.prefillTokens,
      decodeTokens: result.decodeTokens,
      totalTokens: result.totalTokens,
    );
  }

  /// Generate a streaming completion
  Future<Stream<String>> generateCompletionStream({
    required String question,
    String? context,
    bool agenticMode = false,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }

    final systemContent = _buildSystemContent(context, agenticMode);

    final messages = [
      ChatMessage(content: systemContent, role: 'system'),
      ChatMessage(content: question, role: 'user'),
    ];

    final streamedResult = await _lm!.generateCompletionStream(
      messages: messages,
      params: CactusCompletionParams(maxTokens: defaultMaxTokens),
    );

    return streamedResult.stream;
  }

  Map<String, dynamic> _bioaccumulatorPromptProfile({
    required String systemContent,
    required String question,
    String? context,
    List<ChatMessage>? conversationHistory,
    List<CactusTool>? tools,
  }) {
    final charsByRole = <String, int>{};
    final messagesByRole = <String, int>{};
    var historyChars = 0;
    var historyTurnCount = 0;
    for (final message in conversationHistory ?? const <ChatMessage>[]) {
      final role = message.role.toString();
      final length = message.content.length;
      charsByRole[role] = (charsByRole[role] ?? 0) + length;
      messagesByRole[role] = (messagesByRole[role] ?? 0) + 1;
      historyChars += length;
      if (role == 'user') historyTurnCount += 1;
    }
    charsByRole['system'] = (charsByRole['system'] ?? 0) + systemContent.length;
    charsByRole['user'] = (charsByRole['user'] ?? 0) + question.length;
    messagesByRole['system'] = (messagesByRole['system'] ?? 0) + 1;
    messagesByRole['user'] = (messagesByRole['user'] ?? 0) + 1;
    return {
      'schema_version': 'bioaccumulator_prompt_profile_v1',
      'message_count': (conversationHistory?.length ?? 0) + 2,
      'history_message_count': conversationHistory?.length ?? 0,
      'history_turn_count': historyTurnCount,
      'history_turn_count_definition': 'user_messages_in_conversation_history',
      'history_chars': historyChars,
      'prompt_content_chars': historyChars + systemContent.length + question.length,
      'system_content_chars': systemContent.length,
      'provided_context_chars': context?.length ?? 0,
      'current_user_chars': question.length,
      'message_counts_by_role': messagesByRole,
      'message_chars_by_role': charsByRole,
      'tool_count': tools?.length ?? 0,
      'tool_names': tools?.map((tool) => tool.name).toList() ?? const <String>[],
    };
  }

  /// Stream a completion while retaining the final native timing and token metrics.
  Future<CompletionStreamResult<CompletionResult>> generateCompletionStreamWithMetrics({
    required String question,
    String? context,
    bool agenticMode = false,
    List<ChatMessage>? conversationHistory,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }

    final systemContent = _buildSystemContent(context, agenticMode);
    final messages = [
      ChatMessage(content: systemContent, role: 'system'),
      if (conversationHistory != null) ...conversationHistory,
      ChatMessage(content: question, role: 'user'),
    ];
    final promptProfile = _bioaccumulatorPromptProfile(
      systemContent: systemContent,
      question: question,
      context: context,
      conversationHistory: conversationHistory,
    );
    final streamed = await _lm!.generateCompletionStream(
      messages: messages,
      params: CactusCompletionParams(maxTokens: defaultMaxTokens),
    );

    return CompletionStreamResult<CompletionResult>(
      stream: streamed.stream,
      result: streamed.result.then((result) {
        if (!result.success) {
          throw ModelServiceException('Generation failed: ${result.response}');
        }
        return CompletionResult(
          response: _cleanResponse(result.response),
          tokensPerSecond: result.tokensPerSecond,
          prefillTokensPerSecond: result.prefillTokensPerSecond,
          decodeTokensPerSecond: result.decodeTokensPerSecond,
          promptProfile: promptProfile,
          rawResponse: result.response,
          timeToFirstTokenMs: result.timeToFirstTokenMs,
          totalTimeMs: result.totalTimeMs,
          prefillTokens: result.prefillTokens,
          decodeTokens: result.decodeTokens,
          totalTokens: result.totalTokens,
        );
      }),
    );
  }

  /// Stream a tool decision and retain the parsed calls and native metrics.
  Future<CompletionStreamResult<CompletionResultWithTools>> generateCompletionWithToolsStream({
    required String question,
    String? context,
    List<CactusTool>? tools,
    List<ChatMessage>? conversationHistory,
    EmbeddingService? embeddingService,
    bool resetContextBeforeTools = true,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }

    final systemContent = _buildSystemContentForTools(context);
    final effectiveTools =
        tools ?? await _routeTools(question, embeddingService);
    final messages = [
      ChatMessage(content: systemContent, role: 'system'),
      if (conversationHistory != null) ...conversationHistory,
      ChatMessage(content: question, role: 'user'),
    ];
    final promptProfile = _bioaccumulatorPromptProfile(
      systemContent: systemContent,
      question: question,
      context: context,
      conversationHistory: conversationHistory,
      tools: effectiveTools,
    );
    final streamed = await _lm!.generateCompletionStream(
      messages: messages,
      params: CactusCompletionParams(
        maxTokens: defaultMaxTokens,
        tools: effectiveTools,
      ),
      resetContextBeforeTools: resetContextBeforeTools,
    );

    return CompletionStreamResult<CompletionResultWithTools>(
      stream: streamed.stream,
      result: streamed.result.then((result) {
        if (!result.success) {
          throw ModelServiceException('Generation failed: ${result.response}');
        }
        return CompletionResultWithTools(
          response: _cleanResponse(result.response),
          tokensPerSecond: result.tokensPerSecond,
          toolCalls: result.toolCalls,
          prefillTokensPerSecond: result.prefillTokensPerSecond,
          decodeTokensPerSecond: result.decodeTokensPerSecond,
          promptProfile: promptProfile,
          availableTools: effectiveTools.map((tool) => tool.name).toList(),
          rawResponse: result.response,
          timeToFirstTokenMs: result.timeToFirstTokenMs,
          totalTimeMs: result.totalTimeMs,
          prefillTokens: result.prefillTokens,
          decodeTokens: result.decodeTokens,
          totalTokens: result.totalTokens,
        );
      }),
    );
  }

  /// Benchmark-only context control for matched cache reuse runs.
  void resetInferenceContext() {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }
    _lm!.reset();
  }

  /// Prime the fixed decision system/tool prefix used by the Pixel pilot.
  static List<CactusTool> benchmarkPrefillTools({
    bool mismatchToolSchema = false,
  }) {
    if (!mismatchToolSchema) return farmingTools;
    return farmingTools.asMap().entries.map((entry) {
      final tool = entry.value;
      if (entry.key != 0) return tool;
      return CactusTool(
        name: tool.name,
        description: '${tool.description} (intentional cache-miss probe)',
        parameters: tool.parameters,
      );
    }).toList();
  }

  Future<Map<String, dynamic>> prefillToolDecisionPrefixForBenchmark({
    bool mismatchToolSchema = false,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }
    return await _lm!.prefill(
      messages: [
        ChatMessage(content: _buildSystemContentForTools(null), role: 'system'),
      ],
      params: CactusCompletionParams(
        maxTokens: defaultMaxTokens,
        tools: benchmarkPrefillTools(mismatchToolSchema: mismatchToolSchema),
      ),
    );
  }

  /// Generate a completion with tool calling support
  /// Returns both the response and any tool calls the model wants to make
  Future<CompletionResultWithTools> generateCompletionWithTools({
    required String question,
    String? context,
    List<CactusTool>? tools,
    List<ChatMessage>? conversationHistory,
    EmbeddingService? embeddingService,
    bool resetContextBeforeTools = true,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }

    final systemContent = _buildSystemContentForTools(context);
    final effectiveTools =
        tools ?? await _routeTools(question, embeddingService);

    print('[TOOL_DEBUG] generateCompletionWithTools called');
    print('[TOOL_DEBUG] Question: $question');
    print('[TOOL_DEBUG] Context length: ${context?.length ?? 0}');
    print('[TOOL_DEBUG] History turns: ${conversationHistory?.length ?? 0}');
    print(
      '[TOOL_DEBUG] Available tools: ${effectiveTools.map((t) => t.name).toList()}',
    );

    final messages = [
      ChatMessage(content: systemContent, role: 'system'),
      if (conversationHistory != null) ...conversationHistory,
      ChatMessage(content: question, role: 'user'),
    ];

    print('[TOOL_DEBUG] Calling generateCompletion WITH tools...');
    final result = await _lm!.generateCompletion(
      messages: messages,
      params: CactusCompletionParams(
        maxTokens: defaultMaxTokens,
        tools: effectiveTools,
      ),
      resetContextBeforeTools: resetContextBeforeTools,
    );

    print('[TOOL_DEBUG] Generation success: ${result.success}');
    print('[TOOL_DEBUG] Raw response length: ${result.response.length}');
    print('[TOOL_DEBUG] Tool calls returned: ${result.toolCalls.length}');
    for (final tc in result.toolCalls) {
      print('[TOOL_DEBUG]   - Tool: ${tc.name}, Args: ${tc.arguments}');
    }

    if (!result.success) {
      throw ModelServiceException('Generation failed: ${result.response}');
    }

    final cleanedResponse = _cleanResponse(result.response);

    return CompletionResultWithTools(
      response: cleanedResponse,
      tokensPerSecond: result.tokensPerSecond,
      toolCalls: result.toolCalls,
      prefillTokensPerSecond: result.prefillTokensPerSecond,
      decodeTokensPerSecond: result.decodeTokensPerSecond,
      availableTools: effectiveTools.map((tool) => tool.name).toList(),
      rawResponse: result.response,
      timeToFirstTokenMs: result.timeToFirstTokenMs,
      totalTimeMs: result.totalTimeMs,
      prefillTokens: result.prefillTokens,
      decodeTokens: result.decodeTokens,
      totalTokens: result.totalTokens,
    );
  }

  /// Select which of [farmingTools] are relevant to `question`, using our
  /// own query-based router (`tool_router.dart`, a faithful Dart port of
  /// `qwen3-finetune/rlm_slice/tool_router.py`) -- NOT Cactus's own
  /// `select_relevant_tools`/`ToolFilterService`, both of which are known-
  /// weak and unused elsewhere in this app (chainlink #177 investigation).
  ///
  /// #175's dual-relevant eval found routed top-1 selection and inject-all-
  /// viable statistically indistinguishable, so the exact top-k/threshold
  /// here doesn't need fine-tuning. top-2 is used as a defensible default:
  /// wide enough that a query relevant to a domain tool doesn't lose it to
  /// an overly strict top-1 cut against the three original utility tools,
  /// narrow enough to keep the now-5-tool list small for the 0.6B model
  /// (which G9/#156 already found cannot reliably self-initiate tool calls
  /// at all -- fewer, more relevant options matters more here than an
  /// optimally-tuned k).
  ///
  /// Retrieval (`RagService`) is intentionally NOT part of this list --
  /// it stays a separate, always-on step, mirroring how the GPU harness
  /// kept `retrieve_rag_context` and `select_relevant_tools` as two
  /// distinct mechanisms (see `multi_tool_context.py`'s docstring).
  Future<List<CactusTool>> _routeTools(
    String question,
    EmbeddingService? embeddingService,
  ) async {
    if (embeddingService == null || !embeddingService.isInitialized) {
      // No embedding model available to route with -- fail open to the
      // full tool list rather than silently dropping tool access.
      return farmingTools;
    }

    try {
      final routing = await tool_router.selectRelevantTools(
        question,
        farmingTools,
        embedFn: embeddingService.generateEmbedding,
      );
      final selectedNames = routing.selected(topK: 2).toSet();
      final selected = farmingTools
          .where((t) => selectedNames.contains(t.name))
          .toList();
      return selected.isEmpty ? farmingTools : selected;
    } catch (e) {
      // Routing is a refinement, not a requirement -- if embedding
      // generation fails for any reason, fail open to the full tool list.
      print('[TOOL_ROUTER] routing failed, falling back to full tool list: $e');
      return farmingTools;
    }
  }

  String _buildSystemContentForTools(String? context) {
    var content = systemPrompt;

    content += '''

You have access to tools for looking up plant nutrients, performing calculations, and creating fertilizer formulations.
When the user asks about NPK ratios or nutrient requirements, use npk_lookup.
When the user asks about making organic fertilizer:
- If they haven't specified their location, ask where they are farming.
- Once you know location and crop type, use local_fertilizer_plants to get a formulation.
- Choose the nutrient parameter based on growth stage: "nitrogen" for leafy greens or vegetative growth, "phosphorus" for flowering or root development, "potassium" for fruiting, "balanced" for general use, or "seedling" for transplants.
After receiving tool results, provide a helpful summary to the user.''';

    if (context != null && context.isNotEmpty) {
      content += '\n\nRelevant Context:\n$context';
    }

    return content;
  }

  String _buildSystemContent(String? context, bool agenticMode) {
    var content = systemPrompt;

    if (agenticMode) {
      content += '''

AGENTIC MODE:
You have access to a calculator. Use <calculate>expression</calculate> for math.
I will parse this tag, run the math, and return the result.
Make multiple iterations if necessary.''';
    }

    if (context != null && context.isNotEmpty) {
      content += '\n\nRelevant Context:\n$context';
    }

    return content;
  }

  /// Clean the response to remove prompt leakage and thinking tags
  String _cleanResponse(String response) {
    var cleaned = response;

    // Remove Qwen3 thinking tags and content
    cleaned = cleaned.replaceAll(
      RegExp(r'<think>.*?</think>', dotAll: true),
      '',
    );

    // Remove native tool-call blocks -- the model may emit these when it
    // decides mid-answer that it needs a tool; callers that care about tool
    // calls read them from CactusCompletionResult.toolCalls before this
    // cleaning step runs, so the user-facing text never shows the raw JSON.
    cleaned = cleaned.replaceAll(
      RegExp(r'<tool_call>.*?</tool_call>', dotAll: true),
      '',
    );

    // Remove prompt structure tags
    cleaned = cleaned.replaceAll(RegExp(r'\[/?CONTEXT\]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\[/?QUESTION\]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\[/?ANSWER\]'), '');

    // Remove common prompt leakage patterns
    final leakPatterns = [
      r'Previous conversation:.*?(?=\n\n|$)',
      r'Relevant knowledge:.*?(?=\n\n|$)',
      r'Current question:.*?(?=\n\n|$)',
      r'Please provide a helpful.*?(?=\n\n|$)',
      r'AGENTIC MODE:.*?(?=\n\n|$)',
      r'(You are|I am) a helpful farming assistant[^\n]*',
      r'USER:.*?ASSISTANT:',
    ];

    for (final pattern in leakPatterns) {
      cleaned = cleaned.replaceAll(
        RegExp(pattern, caseSensitive: false, dotAll: true),
        '',
      );
    }

    // Remove reasoning starts - truncate from these points
    final reasoningStarts = [
      RegExp(r"\n\s*Okay, let's see", caseSensitive: false),
      RegExp(r'\n\s*Let me think', caseSensitive: false),
      RegExp(r'\n\s*Wait, (the user|I should|maybe)', caseSensitive: false),
      RegExp(r'\n\s*My job is to', caseSensitive: false),
      RegExp(r'\n\s*I need to recall', caseSensitive: false),
      RegExp(r'\n\s*First, I need to', caseSensitive: false),
    ];

    for (final pattern in reasoningStarts) {
      final match = pattern.firstMatch(cleaned);
      if (match != null) {
        cleaned = cleaned.substring(0, match.start);
      }
    }

    // Remove prompt structure markers at start
    cleaned = cleaned.replaceFirst(
      RegExp(r'^(ASSISTANT:|AI:|Response:)\s*', caseSensitive: false),
      '',
    );

    // Clean up excessive whitespace
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return cleaned.trim();
  }

  /// Combined initialize method - downloads and initializes the model
  Future<void> initialize({
    required void Function(double progress, String status) onProgress,
  }) async {
    if (_isInitialized) return;

    // Download model if not already downloaded
    await downloadModel(onProgress: onProgress);

    // Initialize model for inference
    onProgress(0.95, 'Initializing inference engine...');
    await initializeModel();

    onProgress(1.0, 'Model ready');
  }

  /// Generate text with streaming via callback
  Future<void> generate({
    required String prompt,
    required void Function(String token) onToken,
    int maxTokens = defaultMaxTokens,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initialize first.',
      );
    }

    // Use simple completion for prompt-based generation
    final messages = [ChatMessage(content: prompt, role: 'user')];

    final streamedResult = await _lm!.generateCompletionStream(
      messages: messages,
      params: CactusCompletionParams(maxTokens: maxTokens),
    );

    await for (final token in streamedResult.stream) {
      onToken(token);
    }
  }

  /// Get device info - returns basic info about the model/device
  Future<Map<String, String>> getDeviceInfo() async {
    // CactusLM doesn't expose a public getDeviceInfo API
    // Return what we know from our configuration
    return {
      'device': 'Mobile (on-device inference)',
      'model': modelSlug,
      'status': _isInitialized ? 'Ready' : 'Not initialized',
    };
  }

  /// Generate a raw completion with an optional custom system prompt.
  ///
  /// Used by the app so callers can supply
  /// their own system prompt (e.g. "Answer with only A/B/C/D").
  Future<String> generateRaw({
    required String prompt,
    String? systemPrompt,
    int maxTokens = 512,
  }) async {
    if (!_isInitialized) {
      throw ModelServiceException(
        'Model not initialized. Call initializeModel first.',
      );
    }

    final messages = [
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        ChatMessage(content: systemPrompt, role: 'system'),
      ChatMessage(content: prompt, role: 'user'),
    ];

    final result = await _lm!.generateCompletion(
      messages: messages,
      params: CactusCompletionParams(maxTokens: maxTokens),
    );

    if (!result.success) {
      throw ModelServiceException('Generation failed: ${result.response}');
    }

    return _cleanResponse(result.response);
  }

  /// Unload the model and free resources
  void dispose() {
    _lm?.unload();
    _lm = null;
    _isInitialized = false;
    _downloadProgress = 0.0;
    _downloadStatus = '';
  }
}

/// Result from a completion request
class CompletionResult {
  final String response;
  final double tokensPerSecond;
  final double prefillTokensPerSecond;
  final double decodeTokensPerSecond;
  final Map<String, dynamic> promptProfile;
  final String rawResponse;
  final double timeToFirstTokenMs;
  final double totalTimeMs;
  final int prefillTokens;
  final int decodeTokens;
  final int totalTokens;

  CompletionResult({
    required this.response,
    required this.tokensPerSecond,
    this.prefillTokensPerSecond = 0.0,
    this.decodeTokensPerSecond = 0.0,
    this.promptProfile = const <String, dynamic>{},
    this.rawResponse = '',
    this.timeToFirstTokenMs = 0,
    this.totalTimeMs = 0,
    this.prefillTokens = 0,
    this.decodeTokens = 0,
    this.totalTokens = 0,
  });
}

/// Result from a completion request with tool calling support
class CompletionResultWithTools {
  final String response;
  final double tokensPerSecond;
  final List<ToolCall> toolCalls;
  final double prefillTokensPerSecond;
  final double decodeTokensPerSecond;
  final Map<String, dynamic> promptProfile;
  final List<String> availableTools;
  final String rawResponse;
  final double timeToFirstTokenMs;
  final double totalTimeMs;
  final int prefillTokens;
  final int decodeTokens;
  final int totalTokens;

  CompletionResultWithTools({
    required this.response,
    required this.tokensPerSecond,
    required this.toolCalls,
    this.prefillTokensPerSecond = 0.0,
    this.decodeTokensPerSecond = 0.0,
    this.promptProfile = const <String, dynamic>{},
    this.availableTools = const [],
    this.rawResponse = '',
    this.timeToFirstTokenMs = 0,
    this.totalTimeMs = 0,
    this.prefillTokens = 0,
    this.decodeTokens = 0,
    this.totalTokens = 0,
  });

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// Exception thrown by ModelService
class ModelServiceException implements Exception {
  final String message;

  ModelServiceException(this.message);

  @override
  String toString() => 'ModelServiceException: $message';
}

/// Stream chunks during inference and expose the completed native result.
class CompletionStreamResult<T> {
  final Stream<String> stream;
  final Future<T> result;

  CompletionStreamResult({required this.stream, required this.result});
}
