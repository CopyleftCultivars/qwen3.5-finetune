import 'package:cactus/cactus.dart' show ToolCall;
import 'package:flutter/material.dart';

import '../services/recipe_form.dart';
import '../services/recipe_form_evaluator.dart';
import '../services/recipe_prompt.dart';
import '../services/recipe_tool_service.dart';
import '../services/region_plant_service.dart';
import '../services/tool_executor.dart';
import '../services/tool_result_context.dart';
import 'recipe_card.dart';

/// Runs the QUICK instruction pass for a form submission.
///
/// The callback is supplied by the chat screen so both paths call the model
/// with the same message shape and tool catalog. It is invoked only after the
/// user submits. Typing and the live pre-submit calculation never call it.
typedef GenerateRecipeInstructions =
    Future<String> Function({
      required String userMessage,
      required String assistantToolCallResponse,
      required String toolResultContext,
    });

/// Seeds a new chat session from the form result.
typedef ContinueChatFromRecipe =
    Future<void> Function({
      required String userMessage,
      required String assistantReply,
      required Map<String, dynamic> recipe,
    });

/// The recipe form tab (#20).
///
/// Fields are validated by [RecipeToolService]'s own resolvers, the pair is
/// calculated deterministically as soon as it is complete, and submit renders
/// the result as a chat reply. No model call happens until submit, and then
/// only in QUICK mode for the instruction pass.
class RecipeFormTab extends StatefulWidget {
  final RecipeToolService recipeToolService;
  final RegionPlantService regionPlantService;
  final ToolExecutor toolExecutor;
  final bool quickMode;
  final ValueChanged<bool> onModeChanged;
  final GenerateRecipeInstructions generateInstructions;
  final ContinueChatFromRecipe onContinueChat;

  const RecipeFormTab({
    super.key,
    required this.recipeToolService,
    required this.regionPlantService,
    required this.toolExecutor,
    required this.quickMode,
    required this.onModeChanged,
    required this.generateInstructions,
    required this.onContinueChat,
  });

  @override
  State<RecipeFormTab> createState() => _RecipeFormTabState();
}

class _RecipeFormTabState extends State<RecipeFormTab> {
  final TextEditingController _cropController = TextEditingController();
  final TextEditingController _plantController = TextEditingController();
  final TextEditingController _areaController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();

  RecipeFormEvaluation _evaluation = const RecipeFormEvaluation(
    status: RecipeFormStatus.incomplete,
  );
  _RecipeFormSubmission? _submission;
  bool _isSubmitting = false;
  String? _submitError;

  @override
  void dispose() {
    _cropController.dispose();
    _plantController.dispose();
    _areaController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _recompute() {
    final regionalNames = widget.regionPlantService.plantNameTermsForLocation(
      _locationController.text,
    );
    setState(() {
      _evaluation = evaluateRecipeForm(
        service: widget.recipeToolService,
        candidatePlant: _plantController.text,
        crop: _cropController.text,
        areaText: _areaController.text,
        regionalPlantNames: regionalNames,
      );
      _submitError = null;
    });
  }

  void _choosePlantSuggestion(String suggestion) {
    // Scientific-index suggestions are rendered as "Common (Scientific)"; the
    // resolver accepts the common name, so fill that rather than the label.
    final common = suggestion.split(' (').first.trim();
    _plantController.text = common.isEmpty ? suggestion : common;
    _recompute();
  }

  Future<void> _submit() async {
    if (!_evaluation.canSubmit || _isSubmitting) return;
    final plant = _plantController.text.trim();
    final crop = _cropController.text.trim();
    final quantity = double.tryParse(_areaController.text.trim());
    if (quantity == null || quantity <= 0) return;

    final triggerText = buildRecipeTriggerText(
      candidatePlant: plant,
      crop: crop,
      quantity: quantity,
    );
    final assistantToolCall = buildRecipeToolCallResponse(
      candidatePlant: plant,
      crop: crop,
      quantity: quantity,
    );

    setState(() {
      _isSubmitting = true;
      _submission = null;
      _submitError = null;
    });

    try {
      // Same dispatch as a model-requested call: the form only replaces the
      // model's tool-decision turn with its validated fields.
      final toolResult = await widget.toolExecutor.execute(
        ToolCall(
          name: recipeToolName,
          arguments: {
            'candidate_plant': plant,
            'crop': crop,
            'quantity': _areaController.text.trim(),
            'unit': 'm2',
          },
        ),
      );
      final full = toolResult.data;
      if (full == null) {
        throw StateError('The recipe tool returned no full result.');
      }
      final toolContext = formatToolResultsForPrompt([
        PromptToolResult(
          toolName: toolResult.toolName,
          success: toolResult.success,
          text: toolResult.result,
        ),
      ]);

      var reply = buildDeterministicRecipeSummary(full);
      if (widget.quickMode) {
        try {
          final instructions = (await widget.generateInstructions(
            userMessage: triggerText,
            assistantToolCallResponse: assistantToolCall,
            toolResultContext: toolContext,
          )).trim();
          if (instructions.isNotEmpty) reply = instructions;
        } catch (error) {
          reply = '$reply\n\nQUICK instructions failed: $error';
        }
      }

      if (!mounted) return;
      setState(() {
        _submission = _RecipeFormSubmission(
          triggerText: triggerText,
          assistantReply: reply,
          result: full,
        );
        _isSubmitting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submitError = 'Could not run the recipe tool: $error';
      });
    }
  }

  Future<void> _continueChat() async {
    final submission = _submission;
    if (submission == null || _isSubmitting) return;
    await widget.onContinueChat(
      userMessage: submission.triggerText,
      assistantReply: submission.assistantReply,
      recipe: submission.result,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            const Icon(Icons.edit_note, size: 20),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Recipe form',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SegmentedButton<bool>(
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(value: true, label: Text('QUICK')),
                ButtonSegment(value: false, label: Text('DETAILED')),
              ],
              selected: {widget.quickMode},
              onSelectionChanged: (selection) =>
                  widget.onModeChanged(selection.first),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'The catalog resolvers validate each name without a model call. '
          'The form builds the fixed trigger and runs the same recipe tool.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          controller: _cropController,
          label: 'Crop',
          hint: 'Crop name',
          icon: Icons.grass,
          onChanged: (_) => _recompute(),
        ),
        _buildCropStatus(theme),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _plantController,
          label: 'Candidate plant',
          hint: 'Plant name',
          icon: Icons.local_florist,
          onChanged: (_) => _recompute(),
        ),
        _buildPlantStatus(theme),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _areaController,
          label: 'Area (m2)',
          hint: 'Area in square metres',
          icon: Icons.square_foot,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => _recompute(),
        ),
        if (_areaController.text.trim().isNotEmpty)
          _statusLine(
            theme,
            _evaluation.status == RecipeFormStatus.invalidArea,
            _evaluation.status == RecipeFormStatus.invalidArea
                ? 'Area must be a positive number.'
                : 'Area is a positive number.',
          ),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _locationController,
          label: 'Location (optional)',
          hint: 'Country or region',
          icon: Icons.public,
          onChanged: (_) => _recompute(),
        ),
        if (_locationController.text.trim().isNotEmpty)
          _statusLine(
            theme,
            widget.regionPlantService
                .plantNameTermsForLocation(_locationController.text)
                .isNotEmpty,
            widget.regionPlantService
                    .plantNameTermsForLocation(_locationController.text)
                    .isNotEmpty
                ? 'Location only ranks plant suggestions; it is not sent to the tool.'
                : 'Location not in the regional list; suggestions are unranked.',
          ),
        const SizedBox(height: 12),
        _buildPreSubmit(theme),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _evaluation.canSubmit && !_isSubmitting ? _submit : null,
          icon: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          label: Text(_isSubmitting ? 'Running recipe tool...' : 'Submit'),
        ),
        if (_submitError != null) ...[
          const SizedBox(height: 8),
          Text(_submitError!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_submission != null) ...[
          const SizedBox(height: 20),
          _buildResult(theme, _submission!),
        ],
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required ValueChanged<String> onChanged,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: TextInputAction.next,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _buildCropStatus(ThemeData theme) {
    final text = _cropController.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final crop = widget.recipeToolService.resolveCrop(text);
    if (crop == null) {
      return _statusLine(
        theme,
        false,
        'Unknown crop: not in the crop catalog.',
      );
    }
    final name = crop['Crop']?.toString() ?? text;
    return _statusLine(theme, true, 'Resolved crop: $name.');
  }

  Widget _buildPlantStatus(ThemeData theme) {
    final text = _plantController.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final resolution = widget.recipeToolService.resolvePlant(text);
    final plant = resolution.plant;
    if (plant != null) {
      final common = plant['common_name']?.toString() ?? text;
      final scientific = plant['scientific_name']?.toString() ?? '';
      return _statusLine(
        theme,
        true,
        scientific.isEmpty
            ? 'Resolved plant: $common.'
            : 'Resolved plant: $common ($scientific).',
      );
    }
    if (resolution.suggestions.isEmpty) {
      return _statusLine(
        theme,
        false,
        'Unknown candidate plant: not in the plant catalog.',
      );
    }
    final regionalNames = widget.regionPlantService.plantNameTermsForLocation(
      _locationController.text,
    );
    final suggestions = rankPlantSuggestionsByLocation(
      resolution.suggestions,
      regionalNames,
    );
    final regionalCount = suggestions.where((suggestion) {
      final lowered = suggestion.toLowerCase();
      final base = lowered.split(' (').first;
      return regionalNames.contains(lowered) ||
          regionalNames.contains(base) ||
          regionalNames.any(
            (name) => lowered.contains(name) || base.contains(name),
          );
    }).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statusLine(
          theme,
          false,
          'Ambiguous candidate plant: ${suggestions.length} '
          'suggestion${suggestions.length == 1 ? '' : 's'}.',
        ),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          children: [
            for (final suggestion in suggestions)
              ActionChip(
                label: Text(suggestion),
                onPressed: () => _choosePlantSuggestion(suggestion),
              ),
          ],
        ),
        if (regionalCount > 0)
          Text(
            '$regionalCount listed for the optional location.',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  Widget _statusLine(ThemeData theme, bool good, String text) {
    final color = good ? Colors.green.shade700 : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            good ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreSubmit(ThemeData theme) {
    final canSubmit = _evaluation.canSubmit;
    final color = canSubmit
        ? (_evaluation.computable
              ? Colors.green.shade700
              : theme.colorScheme.tertiary)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            canSubmit ? Icons.calculate_outlined : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _evaluation.summary,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(ThemeData theme, _RecipeFormSubmission submission) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _FormBubble(content: submission.triggerText, isUser: true),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _FormBubble(
            content: submission.assistantReply,
            isUser: false,
            recipe: submission.result,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _isSubmitting ? null : _continueChat,
          icon: const Icon(Icons.forum_outlined),
          label: const Text('Continue chat?'),
        ),
      ],
    );
  }
}

class _RecipeFormSubmission {
  final String triggerText;
  final String assistantReply;
  final Map<String, dynamic> result;

  const _RecipeFormSubmission({
    required this.triggerText,
    required this.assistantReply,
    required this.result,
  });
}

class _FormBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final Map<String, dynamic>? recipe;

  const _FormBubble({required this.content, required this.isUser, this.recipe});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.82,
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
            content,
            style: TextStyle(
              color: isUser
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSecondaryContainer,
            ),
          ),
          if (!isUser && recipe != null) ...[
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
                      result: recipe!,
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
    );
  }
}
