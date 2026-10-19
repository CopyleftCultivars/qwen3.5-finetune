import 'dart:convert';

import 'package:flutter/material.dart';

/// Deterministic DETAILED-mode recipe card.
///
/// It renders the full `recipe-tool-result-v2` object (all amounts, steps,
/// assumptions and sources) without a model call. QUICK mode shows the same
/// card behind the "Show full recipe" control.
class RecipeCard extends StatelessWidget {
  final Map<String, dynamic> result;
  final ScrollController? scrollController;

  const RecipeCard({super.key, required this.result, this.scrollController});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (result['status'] != 'ok') {
      final error = (result['error'] as Map<String, dynamic>?) ?? const {};
      return ListView(
        controller: scrollController,
        padding: const EdgeInsets.all(20),
        children: [
          Text('Recipe tool error', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text('${error['code']}'),
          const SizedBox(height: 8),
          Text('${error['message']}'),
          if (error['details'] != null) ...[
            const SizedBox(height: 16),
            _JsonBlock(value: error['details']),
          ],
        ],
      );
    }

    final candidate = result['candidate_plant'] as Map<String, dynamic>;
    final crop = result['crop'] as Map<String, dynamic>;
    final input = result['input'] as Map<String, dynamic>;
    final ratios = result['ratios'] as Map<String, dynamic>;
    final nutrition = result['nutrition_track'] as Map<String, dynamic>;
    final nutrients = nutrition['nutrients'] as Map<String, dynamic>;
    final methods = (nutrition['methods'] as List).cast<Map<String, dynamic>>();
    final boosterTrack = result['booster_track'] as Map<String, dynamic>;
    final boosterRecipes = (boosterTrack['recipes'] as List)
        .cast<Map<String, dynamic>>();
    final assumptions = result['assumptions'] as Map<String, dynamic>;
    final warnings = (result['warnings'] as List).cast<String>();

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Text('Full recipe', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${candidate['common_name']} for ${crop['common_name']}, '
          '${_fmt(input['quantity'])} m2',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 2),
        Text(
          'Target fraction ${_fmt(input['target_fraction'])} · '
          '${candidate['scientific_name']} · ${crop['scientific_name']}',
          style: theme.textTheme.bodySmall,
        ),
        const _SectionGap(),
        _Section(
          title: 'Ratios',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final nutrient in const ['N', 'P', 'K'])
                _Row(
                  label: nutrient,
                  value: ratios[nutrient]['comparable'] == true
                      ? '${_fmt(ratios[nutrient]['value'])} ${ratios[nutrient]['unit']} '
                            '(${ratios[nutrient]['part']} tissue)'
                      : 'not comparable — ${ratios[nutrient]['reason']}',
                ),
            ],
          ),
        ),
        _Section(
          title: 'Nutrition track (no overshoot)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Row(
                label: 'Sizing nutrient',
                value: '${nutrition['sizing_nutrient']}',
              ),
              _Row(
                label: 'Fresh material',
                value:
                    '${_fmt(nutrition['sizing_fresh_plant_material_kg'])} kg '
                    '(${_fmt(nutrition['sizing_fresh_plant_material_kg_per_m2'])} kg/m2)',
              ),
              _Row(
                label: 'Coverage',
                value: [
                  for (final nutrient in const ['N', 'P', 'K'])
                    if (nutrients[nutrient]['coverage_percent'] != null)
                      '$nutrient ${_fmt(nutrients[nutrient]['coverage_percent'])}%',
                ].join(', '),
              ),
              const SizedBox(height: 8),
              Text(
                nutrition['basis'] as String,
                style: theme.textTheme.bodySmall,
              ),
              for (final nutrient in const ['N', 'P', 'K'])
                _NutrientRow(body: nutrients[nutrient] as Map<String, dynamic>),
              if ((nutrition['top_up_notes'] as List).isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Top-up notes', style: theme.textTheme.titleSmall),
                for (final note
                    in (nutrition['top_up_notes'] as List).cast<String>())
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('• $note', style: theme.textTheme.bodySmall),
                  ),
              ],
            ],
          ),
        ),
        for (final method in methods)
          _Section(
            title:
                '${method['label']} (${_fmt(method['fresh_plant_material_kg'])} kg)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < (method['steps'] as List).length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${i + 1}. ${(method['steps'] as List)[i]}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                _MethodAmounts(method: method),
                _Sources(sources: method['sources'] as List?),
              ],
            ),
          ),
        _Section(
          title: 'Booster track',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                boosterTrack['basis'] as String,
                style: theme.textTheme.bodySmall,
              ),
              for (final recipe in boosterRecipes)
                _BoosterRecipe(recipe: recipe),
            ],
          ),
        ),
        _Section(
          title: 'Warnings',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final warning in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $warning', style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
        _AssumptionsSection(assumptions: assumptions),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          child,
          const Divider(height: 24),
        ],
      ),
    );
  }
}

class _SectionGap extends StatelessWidget {
  const _SectionGap();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 8);
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _NutrientRow extends StatelessWidget {
  final Map<String, dynamic> body;

  const _NutrientRow({required this.body});

  @override
  Widget build(BuildContext context) {
    if (body['computable'] != true) {
      return Text(
        '• ${body['reason']}',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        '• ${body['part']} (${body['part_category']}): '
        '${_fmt(body['fresh_plant_material_kg'])} kg total, '
        '${_fmt(body['fresh_plant_material_kg_per_m2'])} kg/m2, '
        'coverage ${_fmt(body['coverage_percent'])}%, '
        'shortfall ${_fmt(body['shortfall_nutrient_kg'])} kg nutrient',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _MethodAmounts extends StatelessWidget {
  final Map<String, dynamic> method;

  const _MethodAmounts({required this.method});

  @override
  Widget build(BuildContext context) {
    const keys = [
      'mulch_depth_cm',
      'implied_depth_cm',
      'steep_water_l',
      'concentrate_l',
      'dilution_ratio',
      'diluted_volume_l',
      'rate_l_per_m2',
      'standard_rate_l_per_m2',
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 2,
      children: [
        for (final key in keys)
          if (method[key] != null)
            Text(
              '$key: ${_fmt(method[key])}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
      ],
    );
  }
}

class _Sources extends StatelessWidget {
  final List<dynamic>? sources;

  const _Sources({this.sources});

  @override
  Widget build(BuildContext context) {
    if (sources == null || sources!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sources', style: Theme.of(context).textTheme.titleSmall),
          for (final raw in sources!)
            if (raw is Map<String, dynamic>)
              Text(
                '${raw['corpus_file']}:${raw['line']} — "${raw['quote']}"',
                style: Theme.of(context).textTheme.bodySmall,
              ),
        ],
      ),
    );
  }
}

class _BoosterRecipe extends StatelessWidget {
  final Map<String, dynamic> recipe;

  const _BoosterRecipe({required this.recipe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final batch = recipe['standard_batch'] as Map<String, dynamic>?;
    final application = recipe['application'] as Map<String, dynamic>?;
    final template = recipe['template'] as Map<String, dynamic>?;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text(
        '${recipe['recipe_abbrev']} — ${recipe['recipe_name']} (${recipe['target_nutrient']})',
      ),
      subtitle: Text(
        '${recipe['selection']} · ${recipe['computable'] == true ? 'computable' : 'not computable'}',
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Selection: ${recipe['selection_note']}',
                style: theme.textTheme.bodySmall,
              ),
              if (recipe['tissue'] != null)
                Text(
                  'Tissue: ${recipe['tissue']['part']} '
                  '${_fmt(recipe['tissue']['midpoint_ppm'])} ppm '
                  '(min ${_fmt(recipe['tissue']['min_ppm'])}, '
                  'max ${_fmt(recipe['tissue']['max_ppm'])})',
                  style: theme.textTheme.bodySmall,
                ),
              if (batch != null) ...[
                const SizedBox(height: 6),
                Text('Standard batch', style: theme.textTheme.titleSmall),
                Text(
                  '${_fmt(batch['plant_material_fresh_kg'])} kg fresh plant material; '
                  'plant:extractant ${_fmt(batch['plant_to_extractant_ratio'])}; '
                  '${batch['sugar_or_extractant']['name']} '
                  '${_fmt(batch['sugar_or_extractant']['amount'])} '
                  '${batch['sugar_or_extractant']['unit']}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (application != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Application for this area',
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  '${_fmt(application['concentrate_ml'])} mL concentrate into '
                  '${_fmt(application['diluted_volume_l'])} L diluted at '
                  '${application['ratio']} (${application['method']}); '
                  '${_fmt(application['rate_l_per_m2'])} L/m2 vs standard '
                  '${_fmt(application['standard_rate_l_per_m2'])} L/m2; '
                  'plant material ${_fmt(application['plant_material_fresh_kg'])} kg; '
                  'nutrient supplied ${_fmt(application['nutrient_supplied_kg'])} kg '
                  '(${_fmt(application['fraction_of_requirement'])} of requirement, '
                  'information only)',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (template != null) ...[
                const SizedBox(height: 6),
                Text('Template', style: theme.textTheme.titleSmall),
                Text(
                  'Dilutions: ${template['dilution_ratios']}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  'Ingredients: ${(template['ingredients'] as List).join(', ')}',
                  style: theme.textTheme.bodySmall,
                ),
                for (final step
                    in (template['steps'] as List).cast<Map<String, dynamic>>())
                  Text(
                    '${step['order']}. ${step['text']}',
                    style: theme.textTheme.bodySmall,
                  ),
                Text(
                  'Source: ${template['source']}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              for (final note in (recipe['assumptions'] as List? ?? const []))
                Text('• $note', style: theme.textTheme.bodySmall),
              if (recipe['template_adaptation'] != null &&
                  recipe['template_adaptation']['adapted'] == true)
                Text(
                  'Adaptation: ${recipe['template_adaptation']['note']}',
                  style: theme.textTheme.bodySmall,
                ),
              _Sources(
                sources: [
                  if (template?['source'] is Map<String, dynamic>)
                    {
                      'corpus_file': template!['source']['file'],
                      'line': template['source']['recipe_abbrev'],
                      'quote': 'sha256 ${template['source']['sha256']}',
                    },
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

class _AssumptionsSection extends StatelessWidget {
  final Map<String, dynamic> assumptions;

  const _AssumptionsSection({required this.assumptions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signoff = assumptions['owner_signoff'] as Map<String, dynamic>;
    return _Section(
      title: 'Assumptions and sign-off',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in signoff.entries)
            Text(
              '${entry.key}: ${entry.value is Map ? (entry.value as Map)['status'] : entry.value}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 6),
          Text(
            assumptions['track_model']['dose_rule'] as String,
            style: theme.textTheme.bodySmall,
          ),
          for (final limitation
              in (assumptions['limitations'] as List).cast<String>())
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('• $limitation', style: theme.textTheme.bodySmall),
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Full assumptions JSON'),
            children: [_JsonBlock(value: assumptions)],
          ),
        ],
      ),
    );
  }
}

class _JsonBlock extends StatelessWidget {
  final dynamic value;

  const _JsonBlock({required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        const JsonEncoder.withIndent('  ').convert(value),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }
}

String _fmt(dynamic value) {
  if (value == null) return '—';
  if (value is num) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }
  return value.toString();
}
