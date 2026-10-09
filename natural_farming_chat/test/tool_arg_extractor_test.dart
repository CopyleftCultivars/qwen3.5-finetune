import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/tool_arg_extractor.dart';

// Mirrors rlm_slice/multi_tool_context.py's extract_args/_find_in_text
// tests conceptually -- pure logic, no assets/model needed.
void main() {
  group('findInText', () {
    test('finds the longest matching vocab term', () {
      final vocab = sortVocabLongestFirst(['Corn', 'Sweet Corn']);
      expect(findInText('growing Sweet Corn in my garden', vocab), 'Sweet Corn');
    });

    test('case-insensitive', () {
      final vocab = sortVocabLongestFirst(['Comfrey']);
      expect(findInText('what about COMFREY as green manure', vocab), 'Comfrey');
    });

    test('skips terms of length <= 2', () {
      final vocab = sortVocabLongestFirst(['ok', 'Okra']);
      expect(findInText('growing ok things', vocab), isNull);
    });

    test('returns null when nothing matches', () {
      final vocab = sortVocabLongestFirst(['Corn', 'Rice']);
      expect(findInText('what about wheat', vocab), isNull);
    });
  });

  group('ToolArgExtractor.extractArgs', () {
    late ToolArgExtractor extractor;

    setUp(() {
      extractor = ToolArgExtractor(
        cropNames: ['Corn', 'Rice'],
        plantNames: ['Comfrey', 'Okra'],
        regionNames: ['Kenya', 'California'],
      );
    });

    test('bioaccumulator_ratio requires both crop and plant', () {
      final args = extractor.extractArgs(
        'bioaccumulator_ratio',
        'Is Comfrey a good bioaccumulator for Corn?',
      );
      expect(args, {'crop': 'Corn', 'candidate_plant': 'Comfrey'});
    });

    test('bioaccumulator_ratio returns null when plant is missing', () {
      final args = extractor.extractArgs('bioaccumulator_ratio', 'Nitrogen needs for Corn');
      expect(args, isNull);
    });

    test('regional_recipe_lookup always includes problem (the raw query)', () {
      final args = extractor.extractArgs('regional_recipe_lookup', 'nitrogen deficiency in Kenya');
      expect(args!['region'], 'Kenya');
      expect(args['problem'], 'nitrogen deficiency in Kenya');
      expect(args.containsKey('crop'), isFalse);
    });

    test('regional_recipe_lookup can fire with no crop or region found', () {
      final args = extractor.extractArgs('regional_recipe_lookup', 'general nitrogen deficiency question');
      expect(args, isNotNull);
      expect(args!.containsKey('crop'), isFalse);
      expect(args.containsKey('region'), isFalse);
      expect(args['problem'], 'general nitrogen deficiency question');
    });

    test('unknown tool name returns null', () {
      expect(extractor.extractArgs('npk_lookup', 'anything'), isNull);
    });
  });
}
