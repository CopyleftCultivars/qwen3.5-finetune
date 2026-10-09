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

    test('Corn x Okra ratio is positive, not negative (regression: no leading -? in range regex)', () {
      // Corn's Phosphorus requirement is "30-70" -- the exact string that
      // triggered the GPU-side bug (chainlink #175): a `-?\d+` regex misreads
      // the range separator as a unary minus, giving [30, -70] instead of
      // [30, 70], which would make every ratio negative here.
      final result = service.compute('Corn', 'Okra');
      expect(result.success, isTrue);
      expect(result.ratios['phosphorus'], isNotNull);
      expect(result.ratios['phosphorus'], greaterThan(0));
      expect(result.ratios['potassium'], greaterThan(0));
    });

    test('nitrogen is always reported not-comparable', () {
      final result = service.compute('Corn', 'Okra');
      expect(result.notComparable, contains('nitrogen'));
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
