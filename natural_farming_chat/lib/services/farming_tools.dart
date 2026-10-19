import 'package:cactus/models/tools.dart';

import 'recipe_prompt.dart';

/// The six-tool catalog candidate 4 was trained and gated on.
///
/// This file is deliberately free of Flutter imports so the prompt-parity
/// exporter (`tool/export_recipe_turn_messages.dart`) can load exactly the
/// tools the app sends, not a copy. Keep the order identical to the
/// `trigger_recipe_v1` runner profile.
final List<CactusTool> farmingToolsCatalog = [
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
          description: 'Optional context describing what the calculation is for',
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
          description: 'Candidate bioaccumulator plant common or scientific name',
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
  // The deterministic trigger-recipe tool from bioaccumulator #56/#57. Its
  // name, description and parameter text are byte-identical to the
  // benchmark runner's `trigger_recipe_v1` profile.
  buildRecipeTool(),
];
