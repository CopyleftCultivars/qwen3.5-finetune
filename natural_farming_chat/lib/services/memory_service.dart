import 'package:memlocal/memlocal.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Local long-term memory used by chat. Implementations remain flavor-specific.
abstract class MemoryService {
  bool get enabled;

  Future<void> initialize();
  Future<List<RecalledMemory>> recall(String query, {int k = 5});
  Future<String?> add(String content, String kind);
  Future<List<RecalledMemory>> list({
    String? kind,
    int limit = 50,
    int offset = 0,
  });
  Future<void> delete(String id);
  Future<void> clear();
}

/// Selects keyword memory only for the experimental Qwen3.5 flavor.
MemoryService createMemoryService(String? flavor) =>
    flavor == 'qwen35' ? KeywordMemoryService() : const NoopMemoryService();

/// Production implementation. It does not initialize Rust or open a database.
class NoopMemoryService implements MemoryService {
  const NoopMemoryService();

  @override
  bool get enabled => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<RecalledMemory>> recall(String query, {int k = 5}) async =>
      const [];

  @override
  Future<String?> add(String content, String kind) async => null;

  @override
  Future<List<RecalledMemory>> list({
    String? kind,
    int limit = 50,
    int offset = 0,
  }) async => const [];

  @override
  Future<void> delete(String id) async {}

  @override
  Future<void> clear() async {}
}

/// Fully offline BM25 memory backed by the keyword-only memlocal database.
class KeywordMemoryService implements MemoryService {
  Memlocal? _engine;

  @override
  bool get enabled => _engine != null;

  @override
  Future<void> initialize() async {
    if (_engine != null) return;

    await RustLib.init();
    final documents = await getApplicationDocumentsDirectory();
    _engine = await Memlocal.openKeywordOnly(
      dbPath: path.join(documents.path, 'memlocal.db'),
    );
  }

  @override
  Future<List<RecalledMemory>> recall(String query, {int k = 5}) =>
      _requireEngine().searchKeyword(query: query, k: k);

  @override
  Future<String> add(String content, String kind) =>
      _requireEngine().addMemory(content: content, kind: kind);

  // The FFI management operations are tracked in memlocal_core #4 and will be
  // connected when the app adds its Memories screen and forget command.
  @override
  Future<List<RecalledMemory>> list({
    String? kind,
    int limit = 50,
    int offset = 0,
  }) async => throw UnsupportedError(
    'Listing memories requires the memlocal_core #4 FFI operations.',
  );

  @override
  Future<void> delete(String id) async => throw UnsupportedError(
    'Deleting memories requires the memlocal_core #4 FFI operations.',
  );

  @override
  Future<void> clear() async => throw UnsupportedError(
    'Clearing memories requires the memlocal_core #4 FFI operations.',
  );

  Memlocal _requireEngine() =>
      _engine ??
      (throw StateError('KeywordMemoryService has not been initialized.'));
}
