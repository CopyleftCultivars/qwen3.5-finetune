import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/model_service.dart';

void main() {
  group('ModelService Qwen3.5 default slug', () {
    tearDown(() {
      ModelService.resetQwen35Model();
    });

    test('default slug is the calibrated candidate-4 bundle', () {
      ModelService.resetQwen35Model();
      expect(
        ModelService.qwen35ModelSlug,
        'qwen35-recipe-v5-cactus-cq4-hessian',
      );
    });

    test('qwen35StagingPath follows the slug', () {
      ModelService.resetQwen35Model();
      expect(
        ModelService.qwen35StagingPath,
        '/data/local/tmp/qwen35-recipe-v5-cactus-cq4-hessian',
      );
    });

    test('configureQwen35Model and resetQwen35Model keep working', () {
      ModelService.configureQwen35Model('  custom-slug  ');
      expect(ModelService.qwen35ModelSlug, 'custom-slug');

      ModelService.resetQwen35Model();
      expect(
        ModelService.qwen35ModelSlug,
        'qwen35-recipe-v5-cactus-cq4-hessian',
      );

      // Empty/whitespace slugs are ignored.
      ModelService.configureQwen35Model('   ');
      expect(
        ModelService.qwen35ModelSlug,
        'qwen35-recipe-v5-cactus-cq4-hessian',
      );
    });
  });
}
