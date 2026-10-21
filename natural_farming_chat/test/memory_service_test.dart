import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/memory_service.dart';

void main() {
  group('createMemoryService', () {
    test('selects keyword memory for qwen35', () {
      expect(createMemoryService('qwen35'), isA<KeywordMemoryService>());
    });

    test('selects no-op memory for production', () {
      expect(createMemoryService('production'), isA<NoopMemoryService>());
    });

    test('selects no-op memory when there is no app flavor', () {
      expect(createMemoryService(null), isA<NoopMemoryService>());
    });
  });

  test('no-op service preserves empty and write-free behavior', () async {
    const service = NoopMemoryService();
    await service.initialize();

    expect(service.enabled, isFalse);
    expect(await service.recall('Valle del Cauca'), isEmpty);
    expect(await service.add('farm fact', 'factual'), isNull);
    expect(await service.list(), isEmpty);
    await service.delete('unused');
    await service.clear();
  });
}
