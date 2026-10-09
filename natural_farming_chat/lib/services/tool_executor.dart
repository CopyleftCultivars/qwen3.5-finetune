import 'package:cactus/cactus.dart' show ToolCall;

import 'bioaccumulator_ratio_service.dart';
import 'calculator_service.dart';
import 'fertilizer_formulation_service.dart';
import 'plant_lookup_service.dart';
import 'recipe_lookup_service.dart';

/// Service for executing tool calls requested by the LLM.
/// Dispatches tool calls to appropriate handlers (plant lookups, calculations,
/// fertilizer formulations, and the two domain tools from chainlink #177:
/// bioaccumulator ratio and regional/recipe lookup).
class ToolExecutor {
  final PlantLookupService _plantLookupService;
  final CalculatorService _calculatorService;
  final FertilizerFormulationService _formulationService;
  final BioaccumulatorRatioService? _bioaccumulatorRatioService;
  final RecipeLookupService? _recipeLookupService;

  ToolExecutor({
    required PlantLookupService plantLookupService,
    required CalculatorService calculatorService,
    required FertilizerFormulationService formulationService,
    BioaccumulatorRatioService? bioaccumulatorRatioService,
    RecipeLookupService? recipeLookupService,
  })  : _plantLookupService = plantLookupService,
        _calculatorService = calculatorService,
        _formulationService = formulationService,
        _bioaccumulatorRatioService = bioaccumulatorRatioService,
        _recipeLookupService = recipeLookupService;

  /// Execute a tool call and return the result
  Future<ToolResult> execute(ToolCall toolCall) async {
    print('[TOOL_DEBUG] Executing tool: ${toolCall.name}');
    print('[TOOL_DEBUG] Arguments: ${toolCall.arguments}');

    ToolResult result;
    switch (toolCall.name) {
      case 'npk_lookup':
        result = _executeNPKLookup(toolCall.arguments);
        break;
      case 'calculate':
        result = _executeCalculation(toolCall.arguments);
        break;
      case 'local_fertilizer_plants':
        result = _executeFormulation(toolCall.arguments);
        break;
      case 'bioaccumulator_ratio':
        result = _executeBioaccumulatorRatio(toolCall.arguments);
        break;
      case 'regional_recipe_lookup':
        result = _executeRegionalRecipeLookup(toolCall.arguments);
        break;
      default:
        result = ToolResult(
          toolName: toolCall.name,
          success: false,
          result: 'Unknown tool: ${toolCall.name}',
        );
    }

    print('[TOOL_DEBUG] Tool result - success: ${result.success}');
    print('[TOOL_DEBUG] Tool result - output: ${result.result.substring(0, result.result.length.clamp(0, 200))}...');
    return result;
  }

  /// Execute multiple tool calls and return all results
  Future<List<ToolResult>> executeAll(List<ToolCall> toolCalls) async {
    final results = <ToolResult>[];
    for (final call in toolCalls) {
      results.add(await execute(call));
    }
    return results;
  }

  /// Execute NPK/mineral lookup using direct JSON plant database
  ToolResult _executeNPKLookup(Map<String, String> arguments) {
    final plant = arguments['plant'];
    if (plant == null || plant.isEmpty) {
      return ToolResult(
        toolName: 'npk_lookup',
        success: false,
        result: 'Missing required parameter: plant',
      );
    }

    final lookupResult = _plantLookupService.lookup(plant);

    return ToolResult(
      toolName: 'npk_lookup',
      success: lookupResult.found,
      result: lookupResult.message,
      metadata: {
        'plant': plant,
        if (lookupResult.plantName != null) 'matched': lookupResult.plantName!,
      },
    );
  }

  /// Execute calculation using calculator service
  ToolResult _executeCalculation(Map<String, String> arguments) {
    final expression = arguments['expression'];
    if (expression == null || expression.isEmpty) {
      return ToolResult(
        toolName: 'calculate',
        success: false,
        result: 'Missing required parameter: expression',
      );
    }

    final context = arguments['context'];
    final calcResult = _calculatorService.evaluate(expression);
    final isError = calcResult.startsWith('Error:');

    return ToolResult(
      toolName: 'calculate',
      success: !isError,
      result: calcResult,
      metadata: {
        'expression': expression,
        if (context != null) 'context': context,
      },
    );
  }

  /// Execute fertilizer formulation using region + mineral profile data
  ToolResult _executeFormulation(Map<String, String> arguments) {
    final location = arguments['location'];
    if (location == null || location.isEmpty) {
      return ToolResult(
        toolName: 'local_fertilizer_plants',
        success: false,
        result: 'Missing required parameter: location',
      );
    }

    final nutrient = arguments['nutrient'];
    if (nutrient == null || nutrient.isEmpty) {
      return ToolResult(
        toolName: 'local_fertilizer_plants',
        success: false,
        result: 'Missing required parameter: nutrient',
      );
    }

    final formulation = _formulationService.formulate(location, nutrient);

    return ToolResult(
      toolName: 'local_fertilizer_plants',
      success: formulation.success,
      result: formulation.message,
      metadata: {
        'location': location,
        'nutrient': nutrient,
        'region_matched': formulation.regionName,
      },
    );
  }

  /// Execute bioaccumulator ratio comparison using crop requirements +
  /// plant mineral profile data (chainlink #177).
  ToolResult _executeBioaccumulatorRatio(Map<String, String> arguments) {
    final crop = arguments['crop'];
    if (crop == null || crop.isEmpty) {
      return ToolResult(
        toolName: 'bioaccumulator_ratio',
        success: false,
        result: 'Missing required parameter: crop',
      );
    }

    final candidatePlant = arguments['candidate_plant'];
    if (candidatePlant == null || candidatePlant.isEmpty) {
      return ToolResult(
        toolName: 'bioaccumulator_ratio',
        success: false,
        result: 'Missing required parameter: candidate_plant',
      );
    }

    if (_bioaccumulatorRatioService == null) {
      return ToolResult(
        toolName: 'bioaccumulator_ratio',
        success: false,
        result: 'Bioaccumulator ratio service not available',
      );
    }

    final ratioResult = _bioaccumulatorRatioService.compute(crop, candidatePlant);

    return ToolResult(
      toolName: 'bioaccumulator_ratio',
      success: ratioResult.success,
      result: ratioResult.toMessage(),
      metadata: {
        'crop': crop,
        'candidate_plant': candidatePlant,
      },
    );
  }

  /// Execute combined regional/recipe lookup (chainlink #177).
  ToolResult _executeRegionalRecipeLookup(Map<String, String> arguments) {
    final crop = arguments['crop'];
    final region = arguments['region'];
    final problem = arguments['problem'];

    if ((crop == null || crop.isEmpty) &&
        (region == null || region.isEmpty) &&
        (problem == null || problem.isEmpty)) {
      return ToolResult(
        toolName: 'regional_recipe_lookup',
        success: false,
        result: 'At least one of crop, region, or problem is required',
      );
    }

    if (_recipeLookupService == null) {
      return ToolResult(
        toolName: 'regional_recipe_lookup',
        success: false,
        result: 'Recipe lookup service not available',
      );
    }

    final lookupResult = _recipeLookupService.lookup(
      crop: crop,
      region: region,
      problem: problem,
    );

    return ToolResult(
      toolName: 'regional_recipe_lookup',
      success: lookupResult.success,
      result: lookupResult.toMessage(),
      metadata: {
        if (crop != null) 'crop': crop,
        if (region != null) 'region': region,
        if (problem != null) 'problem': problem,
      },
    );
  }

  /// Format tool results for inclusion in follow-up prompt
  String formatResultsForPrompt(List<ToolResult> results) {
    if (results.isEmpty) return '';

    final buffer = StringBuffer('Tool Results:\n');

    for (final result in results) {
      buffer.writeln('--- ${result.toolName} ---');
      if (result.success) {
        buffer.writeln(result.result);
      } else {
        buffer.writeln('Error: ${result.result}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }
}

/// Result from executing a tool
class ToolResult {
  final String toolName;
  final bool success;
  final String result;
  final Map<String, String>? metadata;

  ToolResult({
    required this.toolName,
    required this.success,
    required this.result,
    this.metadata,
  });

  @override
  String toString() => 'ToolResult($toolName: ${success ? "OK" : "FAIL"} - $result)';
}
