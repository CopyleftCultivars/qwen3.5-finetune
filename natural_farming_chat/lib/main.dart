import 'dart:convert';
import 'package:cactus/cactus.dart' as cactus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/model_service.dart';
import 'services/plant_lookup_service.dart';
import 'services/calculator_service.dart';
import 'services/fertilizer_formulation_service.dart';
import 'services/region_plant_service.dart';
import 'services/tool_executor.dart';
import 'services/bioaccumulator_ratio_service.dart';
import 'services/recipe_lookup_service.dart';
import 'services/recipe_prompt.dart';
import 'services/recipe_tool_service.dart';
import 'services/embedding_service.dart';
import 'widgets/recipe_card.dart';

void main() {
  runApp(const NaturalFarmingChatApp());
}

class NaturalFarmingChatApp extends StatelessWidget {
  const NaturalFarmingChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Natural Farming Chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

/// Represents a chat message
class ChatMessage {
  final String content;
  final bool isUser;
  final DateTime timestamp;

  /// Full deterministic recipe-tool result for the "Show full recipe" card.
  final Map<String, dynamic>? recipe;

  ChatMessage({
    required this.content,
    required this.isUser,
    DateTime? timestamp,
    this.recipe,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Convert to JSON for persistence
  Map<String, dynamic> toJson() => {
    'content': content,
    'isUser': isUser,
    'timestamp': timestamp.toIso8601String(),
    if (recipe != null) 'recipe': recipe,
  };

  /// Create from JSON
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    content: json['content'] as String,
    isUser: json['isUser'] as bool,
    timestamp: DateTime.parse(json['timestamp'] as String),
    recipe: json['recipe'] as Map<String, dynamic>?,
  );
}

/// Main chat screen
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  final ModelService _modelService = ModelService();
  final PlantLookupService _plantLookupService = PlantLookupService();
  final CalculatorService _calculatorService = CalculatorService();
  final RegionPlantService _regionPlantService = RegionPlantService();
  late final BioaccumulatorRatioService _bioaccumulatorRatioService;
  late final RecipeLookupService _recipeLookupService;
  final RecipeToolService _recipeToolService = RecipeToolService();
  final EmbeddingService _embeddingService = EmbeddingService();
  late final FertilizerFormulationService _formulationService;
  late final ToolExecutor _toolExecutor;

  bool _isLoading = false;
  bool _isInitialized = false;
  String _initStatus = 'Starting...';
  double _initProgress = 0.0;
  String? _deviceInfo;

  /// QUICK lets the model write instructions from the compact served view.
  /// DETAILED renders the deterministic recipe card without a model call.
  bool _detailedRecipeMode = false;

  // Persistence keys
  static const String _chatHistoryKey = 'chat_history';
  static const String _qwen35ModelSlugKey = 'qwen35_model_slug';

  @override
  void initState() {
    super.initState();
    _formulationService = FertilizerFormulationService(
      regionService: _regionPlantService,
      plantLookupService: _plantLookupService,
    );
    _bioaccumulatorRatioService = BioaccumulatorRatioService(
      plantLookupService: _plantLookupService,
    );
    _recipeLookupService = RecipeLookupService(
      regionPlantService: _regionPlantService,
    );
    _toolExecutor = ToolExecutor(
      plantLookupService: _plantLookupService,
      calculatorService: _calculatorService,
      formulationService: _formulationService,
      bioaccumulatorRatioService: _bioaccumulatorRatioService,
      recipeLookupService: _recipeLookupService,
      recipeToolService: _recipeToolService,
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadPersistedSettings();
    await _initializeServices();
  }

  /// Load persisted settings from SharedPreferences
  Future<void> _loadPersistedSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final configuredModel = prefs.getString(_qwen35ModelSlugKey);
    if (configuredModel != null && configuredModel.trim().isNotEmpty) {
      ModelService.configureQwen35Model(configuredModel);
    }

    // Load chat history
    final savedHistory = prefs.getString(_chatHistoryKey);
    if (savedHistory != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(savedHistory);
        final loadedMessages = jsonList
            .map((json) => ChatMessage.fromJson(json as Map<String, dynamic>))
            .toList();
        if (loadedMessages.isNotEmpty) {
          setState(() {
            _messages.clear();
            _messages.addAll(loadedMessages);
          });
        }
      } catch (e) {
        // Ignore invalid saved data
      }
    }
  }

  /// Save chat history to SharedPreferences
  Future<void> _saveChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _messages.map((m) => m.toJson()).toList();
    await prefs.setString(_chatHistoryKey, jsonEncode(jsonList));
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize the chat model (45% of init)
      await _modelService.initialize(
        onProgress: (progress, status) {
          setState(() {
            _initProgress = progress * 0.45;
            _initStatus = status;
          });
        },
      );

      // Get device info
      final deviceInfo = await _modelService.getDeviceInfo();
      _deviceInfo = deviceInfo['device'] ?? 'Unknown';

      // Initialize plant mineral database from bundled JSON (8% of init)
      setState(() {
        _initProgress = 0.45;
        _initStatus = 'Loading plant mineral database...';
      });

      await _plantLookupService.initialize(
        onProgress: (progress, status) {
          setState(() {
            _initProgress = 0.45 + (progress * 0.08);
            _initStatus = status;
          });
        },
      );

      // Initialize region plant database (8% of init)
      setState(() {
        _initProgress = 0.53;
        _initStatus = 'Loading region plant database...';
      });

      await _regionPlantService.initialize(
        onProgress: (progress, status) {
          setState(() {
            _initProgress = 0.53 + (progress * 0.08);
            _initStatus = status;
          });
        },
      );

      // Initialize the two chainlink #177 domain-tool data sources (8% of init)
      setState(() {
        _initProgress = 0.61;
        _initStatus = 'Loading crop requirements database...';
      });

      await _bioaccumulatorRatioService.initialize(
        onProgress: (progress, status) {
          setState(() {
            _initProgress = 0.61 + (progress * 0.04);
            _initStatus = status;
          });
        },
      );

      setState(() {
        _initProgress = 0.65;
        _initStatus = 'Loading enriched recipe database...';
      });

      await _recipeLookupService.initialize(
        onProgress: (progress, status) {
          setState(() {
            _initProgress = 0.65 + (progress * 0.02);
            _initStatus = status;
          });
        },
      );

      setState(() {
        _initProgress = 0.67;
        _initStatus = 'Loading recipe-tool contract...';
      });

      await _recipeToolService.initialize();
      setState(() {
        _initProgress = 0.69;
        _initStatus = 'Recipe tool ready';
      });

      if (appFlavor == 'qwen35') {
        // A second CactusLM context can fail on this device/engine. The Qwen3.5
        // flavor uses the full local tool list when the embedding router is off.
        print('[TOOL_ROUTER] Skipping embedding model for qwen35 flavor');
        setState(() {
          _initProgress = 1.0;
          _initStatus = 'Local tools ready';
        });
      } else {
        // Initialize the dedicated embedding model for tool routing.
        setState(() {
          _initProgress = 0.69;
          _initStatus = 'Loading embedding model for tool routing...';
        });

        try {
          await _embeddingService.initialize(
            onProgress: (progress, status) {
              setState(() {
                _initProgress = 0.69 + (progress * 0.31);
                _initStatus = status;
              });
            },
          );
        } catch (e) {
          print(
            '[TOOL_ROUTER] embedding model init failed, tool routing will fail open: $e',
          );
        }
      }

      setState(() {
        _isInitialized = true;
        // Only add welcome message if no history was loaded
        if (_messages.isEmpty) {
          _messages.add(
            ChatMessage(
              content:
                  'Hello! I\'m your Natural Farming assistant. '
                  'Ask me anything about organic farming, composting, '
                  'fermented plant juice, or nutrient requirements for plants.',
              isUser: false,
            ),
          );
        }
      });
    } catch (e) {
      setState(() {
        _initStatus = 'Error: $e';
      });
    }
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _isLoading) return;

    final userMessage = ChatMessage(content: text.trim(), isUser: true);
    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
    });
    _textController.clear();
    _scrollToBottom();

    try {
      String response;
      Map<String, dynamic>? recipe;
      if (_recipeToolService.isInitialized &&
          _recipeToolService.hasTriggerPrefix(text)) {
        final recipeOutcome = await _handleRecipeTrigger(text.trim());
        response = recipeOutcome.text;
        recipe = recipeOutcome.recipe;
      } else {
        // Always use tool-calling flow
        response = await _generateWithTools(text);
      }

      setState(() {
        _messages.add(
          ChatMessage(content: response, isUser: false, recipe: recipe),
        );
        _isLoading = false;
      });
      _saveChatHistory();
    } catch (e) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: 'Sorry, I encountered an error: $e',
            isUser: false,
          ),
        );
        _isLoading = false;
      });
      _saveChatHistory();
    }

    _scrollToBottom();
  }

  /// Deterministic trigger-recognition path.
  ///
  /// QUICK executes the recipe tool, gives the model only the compact served
  /// view, and keeps the full JSON for the card. DETAILED renders the full
  /// result deterministically with no model call at all.
  Future<({String text, Map<String, dynamic>? recipe})> _handleRecipeTrigger(
    String text,
  ) async {
    final RecipeTrigger trigger;
    try {
      trigger = _recipeToolService.parseTrigger(text);
    } on RecipeTriggerException catch (error) {
      return (
        text:
            'Recipe trigger not used (${error.code}): ${error.message}\n\n'
            'Fixed phrase: ${RecipeToolService.triggerTemplate}',
        recipe: null,
      );
    }

    final full = _recipeToolService.calculate(trigger.toArguments());
    final served = _recipeToolService.servedView(full);
    if (_detailedRecipeMode || full['status'] != 'ok') {
      return (text: _deterministicRecipeSummary(full), recipe: full);
    }

    final toolContext =
        'Tool Results:\n--- bioaccumulator_recipe ---\n${canonicalJson(served)}\n';
    final instructions = await _modelService.generateCompletion(
      question: text,
      context: toolContext,
      conversationHistory: _buildConversationHistory(maxChars: 800),
      systemPrompt: recipeSystemPrompt,
    );
    final response = instructions.response.trim();
    return (
      text: response.isEmpty
          ? 'The recipe tool returned:\n${canonicalJson(served)}'
          : response,
      recipe: full,
    );
  }

  String _deterministicRecipeSummary(Map<String, dynamic> result) {
    if (result['status'] != 'ok') {
      final error = (result['error'] as Map<String, dynamic>?) ?? const {};
      return 'Recipe tool error (${error['code']}): ${error['message']}';
    }
    final candidate = result['candidate_plant'] as Map<String, dynamic>;
    final crop = result['crop'] as Map<String, dynamic>;
    final input = result['input'] as Map<String, dynamic>;
    final nutrition = result['nutrition_track'] as Map<String, dynamic>;
    final nutrients = nutrition['nutrients'] as Map<String, dynamic>;
    final coverageText = ['N', 'P', 'K']
        .where((nutrient) => nutrients[nutrient]['coverage_percent'] != null)
        .map(
          (nutrient) =>
              '$nutrient ${(nutrients[nutrient]['coverage_percent'] as num).toDouble().toStringAsFixed(1)}%',
        )
        .join(', ');
    final recipes = ((result['booster_track'] as Map<String, dynamic>)['recipes']
            as List)
        .cast<Map<String, dynamic>>();
    final booster = recipes
        .where((recipe) => recipe['computable'] == true)
        .map((recipe) => '${recipe['recipe_abbrev']} (${recipe['recipe_name']})')
        .join(', ');
    return 'Bioaccumulator recipe for ${candidate['common_name']} on '
        '${crop['common_name']}, ${input['quantity']} m2.\n'
        'Nutrition (no overshoot): ${nutrition['sizing_nutrient']} sizing, '
        '${nutrition['sizing_fresh_plant_material_kg']} kg fresh material '
        '(${nutrition['sizing_fresh_plant_material_kg_per_m2']} kg/m2). '
        'Coverage: $coverageText.\n'
        'Booster: ${booster.isEmpty ? 'no standard batch is computable' : booster}.';
  }

  /// Build conversation history from recent messages for model context.
  /// Returns cactus ChatMessage objects with user/assistant roles.
  /// Limits to roughly [maxChars] of content to stay within context window.
  List<cactus.ChatMessage> _buildConversationHistory({int maxChars = 2000}) {
    // Skip the welcome message (index 0 if it's an assistant message)
    // and the current user message (last in _messages, already sent separately)
    final historyMessages = _messages.where((m) {
      // Exclude the welcome message
      if (m == _messages.first && !m.isUser) return false;
      return true;
    }).toList();

    // Build from most recent backwards, respecting character budget
    final history = <cactus.ChatMessage>[];
    var charCount = 0;

    for (var i = historyMessages.length - 1; i >= 0; i--) {
      final msg = historyMessages[i];
      if (charCount + msg.content.length > maxChars) break;
      history.insert(
        0,
        cactus.ChatMessage(
          content: msg.content,
          role: msg.isUser ? 'user' : 'assistant',
        ),
      );
      charCount += msg.content.length;
    }

    return history;
  }

  /// Two-phase generation with tool calling support.
  /// Phase 1: Generate with tools — model decides if tools are needed.
  /// Phase 2: If tools were called, execute them and generate again WITHOUT
  ///          tools so the model must synthesize a text response from the data.
  Future<String> _generateWithTools(String question) async {
    print('[TOOL_DEBUG] _generateWithTools started for: $question');

    final history = _buildConversationHistory();
    print(
      '[TOOL_DEBUG] Conversation history: ${history.length} turns, ${history.fold<int>(0, (sum, m) => sum + m.content.length)} chars',
    );

    // Phase 1: Generate with tools available
    final result = await _modelService.generateCompletionWithTools(
      question: question,
      conversationHistory: history,
      embeddingService: _embeddingService,
    );

    print('[TOOL_DEBUG] hasToolCalls: ${result.hasToolCalls}');
    print(
      '[TOOL_DEBUG] Response preview: ${result.response.substring(0, result.response.length.clamp(0, 100))}...',
    );

    // If no tool calls, return the response directly
    if (!result.hasToolCalls) {
      print('[TOOL_DEBUG] No tool calls, returning response');
      return result.response;
    }

    // Execute tool calls
    print('[TOOL_DEBUG] Executing ${result.toolCalls.length} tool calls');
    final toolResults = await _toolExecutor.executeAll(result.toolCalls);
    final toolContext = _toolExecutor.formatResultsForPrompt(toolResults);
    print('[TOOL_DEBUG] Tool results formatted (${toolContext.length} chars)');

    // Phase 2: Generate WITHOUT tools, passing tool results as context
    // Use shorter history budget since tool context takes space
    final phase2History = _buildConversationHistory(maxChars: 800);
    print('[TOOL_DEBUG] Phase 2: generating response from tool results');
    final synthesis = await _modelService.generateCompletion(
      question: question,
      context: toolContext,
      conversationHistory: phase2History,
    );

    print(
      '[TOOL_DEBUG] Synthesis complete (${synthesis.response.length} chars)',
    );
    return synthesis.response;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearHistory() {
    setState(() {
      _messages.clear();
      _messages.add(
        ChatMessage(
          content: 'Chat cleared. How can I help you?',
          isUser: false,
        ),
      );
    });
    _saveChatHistory();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _modelService.dispose();
    _embeddingService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return _buildLoadingScreen();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Natural Farming Chat'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          _buildRecipeHint(),
          Expanded(child: _buildMessageList()),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildLoadingScreen() {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.eco, size: 80, color: Colors.green),
              const SizedBox(height: 24),
              const Text(
                'Natural Farming Chat',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              LinearProgressIndicator(value: _initProgress),
              const SizedBox(height: 16),
              Text(
                _initStatus,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.eco, size: 48, color: Colors.green),
                SizedBox(height: 8),
                Text(
                  'Natural Farming AI',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Text(
                  '100% Local • Privacy First',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('Device'),
            subtitle: Text(_deviceInfo ?? 'Unknown'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear Chat History'),
            onTap: () {
              _clearHistory();
              Navigator.pop(context);
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'Democratizing access to farming knowledge',
              style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length && _isLoading) {
          return const _TypingIndicator();
        }
        return _MessageBubble(message: _messages[index]);
      },
    );
  }

  Widget _buildRecipeHint() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.eco_outlined, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Recipe trigger (fixed phrase)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              SegmentedButton<bool>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(value: false, label: Text('QUICK')),
                  ButtonSegment(value: true, label: Text('DETAILED')),
                ],
                selected: {_detailedRecipeMode},
                onSelectionChanged: (selection) {
                  setState(() => _detailedRecipeMode = selection.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            RecipeToolService.triggerTemplate,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            _detailedRecipeMode
                ? 'DETAILED: the app renders the full recipe card without a model call.'
                : 'QUICK: the model reads the compact served view and writes the instructions.',
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: 'Ask about natural farming...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: _sendMessage,
                enabled: !_isLoading,
                maxLines: null,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _isLoading
                  ? null
                  : () => _sendMessage(_textController.text),
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chat message bubble widget
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isUser
              ? colorScheme.primaryContainer
              : colorScheme.secondaryContainer,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.content,
              style: TextStyle(
                color: isUser
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSecondaryContainer,
              ),
            ),
            if (!isUser && message.recipe != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (context) => DraggableScrollableSheet(
                      expand: false,
                      initialChildSize: 0.9,
                      minChildSize: 0.4,
                      maxChildSize: 0.98,
                      builder: (context, scrollController) => RecipeCard(
                        result: message.recipe!,
                        scrollController: scrollController,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.receipt_long, size: 18),
                label: const Text('Show full recipe'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Typing indicator shown while waiting for response
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              'Thinking...',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
