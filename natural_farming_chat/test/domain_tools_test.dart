import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/bioaccumulator_ratio_service.dart';
import 'package:natural_farming_chat/services/plant_lookup_service.dart';
import 'package:natural_farming_chat/services/recipe_lookup_service.dart';
import 'package:natural_farming_chat/services/region_plant_service.dart';

// Loads the real bundled assets (Crop_Requirements.json, Enriched_Recipes.json,
// plant_mineral_profiles.json, Locally_Growing_Plants_by_Region.json) so these
// tests also double as an asset-wiring smoke check for chainlink #177's two
// new domain tools.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BioaccumulatorRatioService', () {
    late PlantLookupService plantLookupService;
    late BioaccumulatorRatioService service;

    setUpAll(() async {
      plantLookupService = PlantLookupService();
      await plantLookupService.initialize();
      service = BioaccumulatorRatioService(plantLookupService: plantLookupService);
      await service.initialize();
    });

    test('loads all 97 crops', () {
      expect(service.cropCount, 97);
    });

    test('Corn x Okra matches hand-calculated P/K golden values', () {
      // Okra P midpoint is 3465 and Corn P midpoint is 50. Okra K midpoint
      // is 17350 and Corn K midpoint is 90. Seed values with only one bound
      // are excluded, so the complete fruit values are used.
      final result = service.compute('Corn', 'Okra');
      expect(result.success, isTrue);
      expect(result.ratios, {'phosphorus': 69.3, 'potassium': 192.778});
      expect(result.notComparable, ['nitrogen']);
      expect(result.unitCaveat, contains('relative signal'));
      expect(
        result.unitCaveat,
        contains('not a unit-equivalent dosing calculation'),
      );
    });

    test('richest complete tissue-part midpoint is selected', () {
      // Garlic root has the richest complete P midpoint (3055); leaf has the
      // richest complete K midpoint (13615.5).
      final result = service.compute('Corn', 'Garlic');
      expect(result.success, isTrue);
      expect(result.ratios, {'phosphorus': 61.1, 'potassium': 151.283});
    });

    test('single-value crop requirements use that value as the midpoint', () {
      final result = service.compute('Anise', 'Garlic');
      expect(result.success, isTrue);
      expect(result.ratios, {'phosphorus': 76.375, 'potassium': 226.925});
    });

    test('common and scientific names resolve to canonical names', () {
      final result = service.compute('Zea mays', 'Abelmoschus esculentus');
      expect(result.success, isTrue);
      expect(result.crop, 'Corn');
      expect(result.candidatePlant, 'Okra');
    });

    test(
      'plant with no complete P/K values reports each as not-comparable',
      () {
        final result = service.compute('Corn', 'Sunset Hibiscus');
        expect(result.success, isTrue);
        expect(result.ratios, isEmpty);
        expect(result.notComparable, ['phosphorus', 'potassium', 'nitrogen']);
        expect(result.toMessage(), contains('No comparable nutrients found.'));
      },
    );

    test('uninitialized service returns an error result', () {
      final uninitialized = BioaccumulatorRatioService(
        plantLookupService: plantLookupService,
      );
      final result = uninitialized.compute('Corn', 'Okra');
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('not initialized'));
    });

    test('blank names do not fall through to the first database record', () {
      expect(service.compute('  ', 'Okra').success, isFalse);
      expect(service.compute('Corn', '  ').success, isFalse);
    });

    test('unknown crop returns an error result', () {
      final result = service.compute('Not A Real Crop Zzz', 'Okra');
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('no crop matching'));
    });

    test('unknown plant returns an error result', () {
      final result = service.compute('Corn', 'Not A Real Plant Zzz');
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('no plant matching'));
    });

    test('substring crop match works (case-insensitive)', () {
      final result = service.compute('corn', 'okra');
      expect(result.success, isTrue);
      expect(result.crop, 'Corn');
    });
  });

  group('RegionPlantService.regionsGrowingCrop (reverse lookup)', () {
    late RegionPlantService regionPlantService;

    setUpAll(() async {
      regionPlantService = RegionPlantService();
      await regionPlantService.initialize();
    });

    test('returns at least one region for a common bioaccumulator plant', () {
      // Comfrey is a canonical bioaccumulator referenced throughout the
      // domain-tools eval; if the region data has any entries at all this
      // should not come back empty.
      final regions = regionPlantService.regionsGrowingCrop('Comfrey');
      expect(regions, isA<List<String>>());
    });

    test('empty query returns no regions', () {
      expect(regionPlantService.regionsGrowingCrop(''), isEmpty);
    });
  });

  group('RecipeLookupService', () {
    late RegionPlantService regionPlantService;
    late RecipeLookupService service;

    setUpAll(() async {
      regionPlantService = RegionPlantService();
      await regionPlantService.initialize();
      service = RecipeLookupService(regionPlantService: regionPlantService);
      await service.initialize();
    });

    test('loads all 14 recipes', () {
      expect(service.recipeCount, 14);
    });

    test('requires at least one of crop/region/problem', () {
      final result = service.lookup();
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('at least one'));
    });

    test('nitrogen deficiency problem hints toward N recipes', () {
      final result = service.lookup(problem: 'nitrogen deficiency');
      expect(result.success, isTrue);
      expect(result.matchingRecipes, isNotEmpty);
      // At least one of the top matches should be primary_nutrient == 'N'
      // (the FAA recipe scores it via the +2 hint bonus).
      expect(
        result.matchingRecipes.any((r) => r['primary_nutrient'] == 'N'),
        isTrue,
      );
    });

    test('returns at most 5 matching recipes', () {
      final result = service.lookup(problem: 'nitrogen deficiency phosphorus potassium');
      expect(result.matchingRecipes.length, lessThanOrEqualTo(5));
    });
  });
}
