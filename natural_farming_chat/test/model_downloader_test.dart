import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/model_downloader.dart';
import 'package:natural_farming_chat/services/model_service.dart';

/// A stand-in for the Hugging Face API: the tree listing, `resolve` URLs that
/// redirect to a CDN path, and `Range` support.
class FakeHub {
  FakeHub(this.files);

  final Map<String, Uint8List> files;
  late HttpServer server;
  final requests = <String>[];
  final ranges = <String, String>{};

  /// Paths whose bytes are altered on the wire (same length).
  final corrupt = <String>{};

  /// Paths whose first response is cut short after this many bytes.
  final dropFirstAfter = <String, int>{};
  final _dropped = <String>{};

  /// Paths served gzip-compressed whatever the client asked for.
  final gzipFiles = <String>{};

  /// Paths served in full even when a range is requested.
  final ignoreRange = <String>{};

  /// Paths answered with this status.
  final status = <String, int>{};

  /// Entries per listing page; 0 means one page.
  int pageSize = 0;

  /// Entries added to or replaced in the listing.
  final extraEntries = <Map<String, dynamic>>[];
  bool omitConfig = false;

  /// Compress the listing even though the client asked for identity.
  bool gzipListing = false;

  static const lfsThreshold = 64;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);

  String get origin => 'http://127.0.0.1:${server.port}';

  HostedModel get model =>
      HostedModel(repo: 'org/model', revision: 'a' * 40, origin: origin);

  List<Map<String, dynamic>> entries() {
    final list = <Map<String, dynamic>>[
      {'type': 'directory', 'path': 'components'},
    ];
    for (final entry in files.entries) {
      if (omitConfig && entry.key == 'config.txt') continue;
      final bytes = entry.value;
      final map = <String, dynamic>{
        'type': 'file',
        'path': entry.key,
        'size': bytes.length,
      };
      if (bytes.length >= lfsThreshold) {
        map['oid'] = 'f' * 40; // The pointer's own git hash is not used.
        map['lfs'] = {'oid': sha256.convert(bytes).toString(), 'size': bytes.length};
      } else {
        map['oid'] = sha1
            .convert([...utf8.encode('blob ${bytes.length}\u0000'), ...bytes])
            .toString();
      }
      list.add(map);
    }
    return [...list, ...extraEntries];
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add(path);
    final response = request.response;
    try {
      if (path == '/api/models/org/model/tree/${'a' * 40}') {
        await _listing(request);
      } else if (path.startsWith('/org/model/resolve/${'a' * 40}/')) {
        final file = path.substring('/org/model/resolve/${'a' * 40}/'.length);
        if (status.containsKey(file)) {
          response.statusCode = status[file]!;
        } else if (!files.containsKey(file)) {
          response.statusCode = 404;
        } else {
          response.statusCode = 302;
          response.headers.set('location', '/cdn/$file?sig=1');
        }
        await response.close();
      } else if (path.startsWith('/cdn/')) {
        await _serve(request, path.substring('/cdn/'.length));
      } else {
        response.statusCode = 404;
        await response.close();
      }
    } catch (_) {
      // A dropped connection is part of the test.
    }
  }

  Future<void> _listing(HttpRequest request) async {
    final all = entries();
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '0') ?? 0;
    final size = pageSize == 0 ? all.length : pageSize;
    final slice = all.skip(page * size).take(size).toList();
    if (pageSize != 0 && (page + 1) * size < all.length) {
      request.response.headers.set(
        'link',
        '<$origin${request.uri.path}?recursive=true&page=${page + 1}>; rel="next"',
      );
    }
    request.response.headers.contentType = ContentType.json;
    final body = utf8.encode(jsonEncode(slice));
    if (gzipListing) {
      request.response.headers.set('content-encoding', 'gzip');
      request.response.add(gzip.encode(body));
    } else {
      request.response.add(body);
    }
    await request.response.close();
  }

  Future<void> _serve(HttpRequest request, String file) async {
    final response = request.response;
    var bytes = files[file]!;
    if (corrupt.contains(file) && bytes.isNotEmpty) {
      bytes = Uint8List.fromList(bytes)..[0] ^= 0xff;
    }
    if (gzipFiles.contains(file)) {
      response.headers.set('content-encoding', 'gzip');
      bytes = Uint8List.fromList(gzip.encode(bytes));
    }
    final range = request.headers.value('range');
    var start = 0;
    if (range != null && !ignoreRange.contains(file)) {
      ranges[file] = range;
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= bytes.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      response.statusCode = 206;
      response.headers.set(
        'content-range',
        'bytes $start-${bytes.length - 1}/${bytes.length}',
      );
    }
    final body = bytes.sublist(start);
    response.contentLength = body.length;
    final cut = dropFirstAfter[file];
    if (cut != null && _dropped.add(file)) {
      response.bufferOutput = false;
      response.add(body.sublist(0, cut));
      await response.flush();
      // Let the client read what was sent before the connection dies.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final socket = await response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    response.add(body);
    await response.close();
  }
}

/// Pseudo-random bytes, so gzip cannot shrink them below a test's range offsets.
Uint8List _bytes(int length, int seed) {
  var state = seed;
  return Uint8List.fromList(
    List.generate(length, (_) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      return (state >> 16) & 0xff;
    }),
  );
}

Map<String, Uint8List> _bundle() => {
  'config.txt': Uint8List.fromList(utf8.encode('model_type=qwen\n')),
  'vocab.txt': Uint8List.fromList(utf8.encode('a\nb\n')),
  'components/manifest.json': Uint8List.fromList(utf8.encode('{}')),
  'layer_0.weights': _bytes(5000, 1),
  'layer_1.weights': _bytes(9000, 2),
  'components/decoder/graph.cactus': _bytes(700, 3),
};

void main() {
  late Directory temp;
  late FakeHub hub;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('model_downloader_test');
    hub = FakeHub(_bundle());
    await hub.start();
  });

  tearDown(() async {
    await hub.stop();
    await temp.delete(recursive: true);
  });

  ModelDownloader downloader({int attempts = 4}) => ModelDownloader(
    model: hub.model,
    maxAttempts: attempts,
    retryDelay: const Duration(milliseconds: 5),
    idleTimeout: const Duration(seconds: 5),
  );

  Directory destination() => Directory('${temp.path}/models/bundle');

  Future<void> expectInstalled() async {
    for (final entry in hub.files.entries) {
      final file = File('${destination().path}/${entry.key}');
      expect(await file.exists(), isTrue, reason: entry.key);
      expect(await file.readAsBytes(), entry.value, reason: entry.key);
    }
    expect(await Directory('${destination().path}.partial').exists(), isFalse);
  }

  test('downloads, verifies and installs every file', () async {
    final progress = <double>[];
    await downloader().download(
      destination: destination(),
      onProgress: (p, _) => progress.add(p),
    );
    await expectInstalled();
    expect(progress.first, 0.0);
    expect(progress.last, 1.0);
    expect(progress, orderedEquals([...progress]..sort()));
  });

  test('ranges survive the redirect to the CDN', () async {
    hub.dropFirstAfter['layer_1.weights'] = 3000;
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    await expectInstalled();
    expect(hub.ranges['layer_1.weights'], 'bytes=3000-');
  });

  test('config.txt is requested last', () async {
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    final resolves = hub.requests.where((r) => r.contains('/resolve/')).toList();
    expect(resolves.last, endsWith('/config.txt'));
  });

  test('a server that ignores Range still yields a correct file', () async {
    hub.dropFirstAfter['layer_0.weights'] = 2000;
    hub.ignoreRange.add('layer_0.weights');
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    await expectInstalled();
  });

  test('a rerun reuses finished files and a partial one', () async {
    // First run dies on the second weights file for good.
    hub.status['layer_1.weights'] = 404;
    await expectLater(
      downloader().download(destination: destination(), onProgress: (_, _) {}),
      throwsA(isA<ModelDownloadException>()),
    );
    expect(await destination().exists(), isFalse);
    final partial = Directory('${destination().path}.partial');
    expect(await File('${partial.path}/layer_0.weights').exists(), isTrue);

    hub.status.clear();
    hub.requests.clear();
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    await expectInstalled();
    expect(
      hub.requests.where((r) => r.endsWith('/layer_0.weights')),
      isEmpty,
      reason: 'a verified file is not fetched again',
    );
  });

  test('wrong bytes of the right length are caught and retried', () async {
    hub.corrupt.add('layer_0.weights');
    Timer(const Duration(milliseconds: 40), hub.corrupt.clear);
    await downloader(attempts: 50).download(
      destination: destination(),
      onProgress: (_, _) {},
    );
    await expectInstalled();
  });

  test('persistent corruption fails and installs nothing', () async {
    hub.corrupt.add('layer_0.weights');
    await expectLater(
      downloader().download(destination: destination(), onProgress: (_, _) {}),
      throwsA(
        isA<ModelDownloadException>().having(
          (e) => e.message,
          'message',
          contains('integrity'),
        ),
      ),
    );
    expect(await destination().exists(), isFalse);
    expect(
      await File('${destination().path}.partial/layer_0.weights').exists(),
      isFalse,
      reason: 'a failed file is never kept under its final name',
    );
  });

  test('a missing file fails at once without retrying', () async {
    hub.status['vocab.txt'] = 404;
    await expectLater(
      downloader().download(destination: destination(), onProgress: (_, _) {}),
      throwsA(
        isA<ModelDownloadException>()
            .having((e) => e.retryable, 'retryable', isFalse)
            .having((e) => e.message, 'message', contains('not found')),
      ),
    );
    expect(hub.requests.where((r) => r.endsWith('/vocab.txt')), hasLength(1));
  });

  test('server errors are retried', () async {
    hub.status['vocab.txt'] = 503;
    Timer(const Duration(milliseconds: 30), hub.status.clear);
    await downloader(attempts: 50).download(
      destination: destination(),
      onProgress: (_, _) {},
    );
    await expectInstalled();
  });

  test('a paginated listing is read to the end', () async {
    hub.pageSize = 2;
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    await expectInstalled();
  });

  test('a file the server compresses anyway is decoded whole', () async {
    hub.gzipFiles.addAll(['vocab.txt', 'layer_1.weights']);
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    await expectInstalled();
  });

  test('a leftover partial file is dropped when the answer is compressed', () async {
    hub.gzipFiles.add('layer_1.weights');
    final partial = File('${destination().path}.partial/layer_1.weights.part');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(hub.files['layer_1.weights']!.sublist(0, 4000));
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    await expectInstalled();
    expect(hub.ranges['layer_1.weights'], 'bytes=4000-', reason: 'it did try to resume first');
  });

  test('a gzip-compressed listing is understood', () async {
    hub.gzipListing = true;
    await downloader().download(destination: destination(), onProgress: (_, _) {});
    await expectInstalled();
  });

  test('refuses to overwrite an existing install', () async {
    await destination().create(recursive: true);
    expect(
      downloader().download(destination: destination(), onProgress: (_, _) {}),
      throwsStateError,
    );
  });

  group('listing checks', () {
    test('a path that leaves the folder is rejected', () async {
      for (final bad in ['../escape', '/abs', 'a//b', 'a/../b', 'x\\y']) {
        hub.extraEntries
          ..clear()
          ..add({'type': 'file', 'path': bad, 'size': 1, 'oid': 'b' * 40});
        await expectLater(
          downloader().download(destination: destination(), onProgress: (_, _) {}),
          throwsA(
            isA<ModelDownloadException>().having(
              (e) => e.message,
              'message',
              contains('unsafe'),
            ),
          ),
          reason: bad,
        );
        expect(await destination().exists(), isFalse);
      }
    });

    test('a listing without config.txt is rejected', () async {
      hub.omitConfig = true;
      await expectLater(
        downloader().download(destination: destination(), onProgress: (_, _) {}),
        throwsA(
          isA<ModelDownloadException>().having(
            (e) => e.message,
            'message',
            contains('config.txt'),
          ),
        ),
      );
    });

    test('an entry without a hash is rejected', () {
      expect(
        () => ModelDownloader.parseListing([
          {'type': 'file', 'path': 'config.txt', 'size': 3},
        ]),
        throwsA(isA<ModelDownloadException>()),
      );
    });

    test('README and .gitattributes are not part of the model', () {
      final files = ModelDownloader.parseListing([
        for (final p in [
          'README.md',
          '.gitattributes',
          'config.txt',
          'vocab.txt',
          'components/manifest.json',
          'a.weights',
        ])
          {'type': 'file', 'path': p, 'size': 1, 'oid': 'c' * 40},
      ]);
      expect(
        files.map((f) => f.path),
        unorderedEquals([
          'config.txt',
          'vocab.txt',
          'components/manifest.json',
          'a.weights',
        ]),
      );
    });
  });

  group('pinned model', () {
    test('is a full commit hash of the cactus repository', () {
      expect(hostedQwen35Model.revision, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(
        hostedQwen35Model.repo,
        'CopyleftCultivars/qwen3.5-2b-natural-farming-v5-cactus-cq4',
      );
    });

    test('URLs name the repository, commit and file', () {
      expect(
        hostedQwen35Model.fileUri('components/manifest.json').toString(),
        'https://huggingface.co/CopyleftCultivars/'
        'qwen3.5-2b-natural-farming-v5-cactus-cq4/resolve/'
        '${hostedQwen35Model.revision}/components/manifest.json',
      );
      expect(
        hostedQwen35Model.treeUri.toString(),
        startsWith(
          'https://huggingface.co/api/models/CopyleftCultivars/'
          'qwen3.5-2b-natural-farming-v5-cactus-cq4/tree/',
        ),
      );
    });
  });

  group('model source', () {
    test('auto is the default and names parse', () {
      expect(ModelService.modelSource, ModelSource.auto);
      expect(ModelService.parseModelSource('hosted'), ModelSource.hosted);
      expect(ModelService.parseModelSource('staged'), ModelSource.staged);
    });

    test('an unknown name is an error, not a silent fallback', () {
      expect(
        () => ModelService.parseModelSource('cloud'),
        throwsA(isA<ModelServiceException>()),
      );
    });
  });
}
