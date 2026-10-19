import 'dart:convert';

import 'package:cactus/cactus.dart'
    show CactusTool, ToolParameter, ToolParametersSchema;

/// The exact system prompt and tool catalog of the benchmark runner's
/// `trigger_recipe_v1` profile.
///
/// Candidate 4 was trained and gated on these bytes. Keep this file in lockstep
/// with `bioaccumulator-benchmark-workspace/scripts/run_hf_gpu_tool_benchmark.py`:
/// the three sha256 pins are asserted by `test/recipe_prompt_parity_test.dart`.
const String recipeBaseSystemPrompt =
    'You are a helpful farming assistant specializing in natural farming practices.\n'
    'Answer questions based on the provided context. If you don\'t know the answer,\n'
    'say so honestly. Provide practical, actionable advice when possible.';

const String recipeToolInstructions =
    '\n'
    'You have access to tools for looking up plant nutrients, performing calculations, and creating fertilizer formulations.\n'
    'When the user asks about NPK ratios or nutrient requirements, use npk_lookup.\n'
    'When the user asks about making organic fertilizer:\n'
    '- If they haven\'t specified their location, ask where they are farming.\n'
    '- Once you know location and crop type, use local_fertilizer_plants to get a formulation.\n'
    '- Choose the nutrient parameter based on growth stage: "nitrogen" for leafy greens or vegetative growth, "phosphorus" for flowering or root development, "potassium" for fruiting, "balanced" for general use, or "seedling" for transplants.\n'
    'After receiving tool results, provide a helpful summary to the user.';

const String recipeSystemPrompt =
    recipeBaseSystemPrompt + recipeToolInstructions;

const String recipeToolName = 'bioaccumulator_recipe';
const String recipeToolDescription =
    'Computes a bioaccumulator recipe for a crop area: the nitrogen, phosphorus and potassium ratio; a nutrition track with the fresh plant-material amount, its method steps and the nutrient coverage; and a booster track with the standard recipe batch. Call it only for the fixed trigger template.';

/// The served parameter descriptions from the #57 serving protocol. They name
/// no example entity or value.
const String recipeCandidatePlantDescription =
    'Catalog common or scientific name of the bioaccumulator plant.';
const String recipeCropDescription =
    'Crop requirement catalog common or scientific crop name.';
const String recipeQuantityDescription = 'Positive area in square metres.';
const String recipeUnitDescription = 'Canonical unit m2.';

const String toolPromptHeader =
    '# Tools\n\n'
    'You may call one or more functions to assist with the user query.\n\n'
    'You are provided with function signatures within <tools></tools> XML tags:\n'
    '<tools>';

const String toolPromptFooter =
    '\n</tools>\n\nFor each function call, return a json object with function name and '
    'arguments within <tool_call></tool_call> XML tags:\n<tool_call>\n'
    '{"name": <function-name>, "arguments": <args-json-object>}\n</tool_call>';

/// The `bioaccumulator_recipe` function definition, derived from the #57
/// serving protocol exactly as the runner derives it.
CactusTool buildRecipeTool() {
  return CactusTool(
    name: recipeToolName,
    description: recipeToolDescription,
    parameters: ToolParametersSchema(
      properties: {
        'candidate_plant': ToolParameter(
          type: 'string',
          description: recipeCandidatePlantDescription,
          required: true,
        ),
        'crop': ToolParameter(
          type: 'string',
          description: recipeCropDescription,
          required: true,
        ),
        'quantity': ToolParameter(
          type: 'number',
          description: recipeQuantityDescription,
          required: true,
        ),
        'unit': ToolParameter(
          type: 'string',
          description: recipeUnitDescription,
          required: true,
        ),
      },
    ),
  );
}

/// Mirror `run_hf_gpu_tool_benchmark.serialize_cactus_tools` byte for byte.
String serializeCactusTools(List<CactusTool> tools) {
  final lines = <String>[];
  for (final tool in tools) {
    lines.add(_respaceJson(jsonEncode(tool.toJson())));
  }
  return '$toolPromptHeader\n${lines.join('\n')}$toolPromptFooter';
}

/// The compact JSON list the runner hashes as `tool_schema_sha256`.
String serializeToolSchemaJson(List<CactusTool> tools) {
  return jsonEncode([for (final tool in tools) tool.toJson()]);
}

/// Mirror cactus-engine `chat_tools.h::respace_json`.
String _respaceJson(String raw) {
  final out = StringBuffer();
  var inString = false;
  var escaped = false;
  for (var i = 0; i < raw.length; i++) {
    final char = raw[i];
    if (inString) {
      out.write(char);
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
      out.write(char);
      continue;
    }
    if (RegExp(r'\s').hasMatch(char)) {
      continue;
    }
    out.write(char);
    if (char == ',' || char == ':') {
      out.write(' ');
    }
  }
  return out.toString();
}
