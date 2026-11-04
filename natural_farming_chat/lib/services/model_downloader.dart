import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// A model bundle hosted on Hugging Face, pinned to one commit.
///
/// The app downloads exactly this commit, so a later push to the repository
/// cannot change what a phone receives. Moving to a new model means changing
/// [revision] here (and, for a new weights layout, the slug in `ModelService`).
class HostedModel {
  const HostedModel({
    required this.repo,
    required this.revision,
    this.origin = 'https://huggingface.co',
  });

  /// `owner/name` of the Hugging Face model repository.
  final String repo;

  /// Full 40-character commit hash.
  final String revision;

  /// Overridden in tests to point at a local server.
  final String origin;

  Uri get treeUri => Uri.parse(
    '$origin/api/models/$repo/tree/$revision',
  ).replace(queryParameters: {'recursive': 'true'});

  Uri fileUri(String path) => Uri.parse(origin).replace(
    pathSegments: [...repo.split('/'), 'resolve', revision, ...path.split('/')],
  );
}

/// The bundle candidate 4 (`qwen35-recipe-v5`, Hessian-calibrated Cactus CQ4)
/// runs from. 347 files, about 1.13 GB.
const hostedQwen35Model = HostedModel(
  repo: 'CopyleftCultivars/qwen3.5-2b-natural-farming-v5-cactus-cq4',
  revision: '3243947aa653ae039566df1179fd2e84fa98e86a',
);

class ModelDownloadException implements Exception {
  ModelDownloadException(this.message, {this.retryable = false});

  final String message;

  /// True when trying again later can help (network, server, bad bytes).
  final bool retryable;

  @override
  String toString() => message;
}

/// One file of the hosted bundle, as the repository listing describes it.
class RemoteFile {
  const RemoteFile({
    required this.path,
    required this.size,
    this.sha256,
    this.gitBlobSha1,
  });

  /// Path relative to the bundle root, with `/` separators.
  final String path;
  final int size;

  /// Hex SHA-256 of the content (files stored with Git LFS or Xet).
  final String? sha256;

  /// Hex git blob SHA-1 (small files stored directly in git).
  final String? gitBlobSha1;
}

/// Files that must be present for the bundle to be usable.
const requiredBundleFiles = <String>[
  'config.txt',
  'vocab.txt',
  'components/manifest.json',
];

/// Downloads a [HostedModel] into a directory, verified and atomically.
///
/// * Files are fetched into `<destination>.partial/`; each is written as
///   `<name>.part` and renamed only after its size and hash match the listing,
///   so a file with its final name is always a verified one.
/// * An interrupted download resumes where it stopped: finished files are kept
///   and an unfinished one continues with a `Range` request.
/// * `config.txt`, the marker the app uses for "installed", is fetched last, and
///   the whole folder is moved to [destination] in one rename at the end.
class ModelDownloader {
  ModelDownloader({
    required this.model,
    this.maxAttempts = 4,
    this.retryDelay = const Duration(seconds: 2),
    this.idleTimeout = const Duration(seconds: 60),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HostedModel model;
  final int maxAttempts;
  final Duration retryDelay;

  /// A connection that sends nothing for this long counts as failed.
  final Duration idleTimeout;
  final HttpClient Function() _clientFactory;

  /// Download the bundle to [destination]. The folder must not exist yet.
  Future<void> download({
    required Directory destination,
    required void Function(double progress, String status) onProgress,
  }) async {
    if (await destination.exists()) {
      throw StateError('${destination.path} already exists');
    }
    final client = _clientFactory()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'natural-farming-chat';
    try {
      onProgress(0.0, 'Looking up the Qwen3.5 model...');
      final files = await _withRetries(
        'listing the model files',
        () => listFiles(client),
      );

      final work = Directory('${destination.path}.partial');
      await work.create(recursive: true);

      // The marker file goes last so an interrupted run never looks complete.
      final ordered = [
        ...files.where((f) => f.path != 'config.txt'),
        ...files.where((f) => f.path == 'config.txt'),
      ];
      final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);
      var doneBytes = 0;
      final progress = _ProgressReporter(totalBytes, onProgress);

      for (final file in ordered) {
        final target = File('${work.path}/${file.path}');
        if (await target.exists() && await target.length() == file.size) {
          doneBytes += file.size;
          progress.report(doneBytes, force: true);
          continue;
        }
        await target.parent.create(recursive: true);
        await _withRetries(
          file.path,
          () => _fetch(
            client,
            file,
            target,
            (bytes) => progress.report(doneBytes + bytes),
          ),
        );
        doneBytes += file.size;
        progress.report(doneBytes, force: true);
      }

      await work.rename(destination.path);
      onProgress(1.0, 'Model downloaded');
    } finally {
      client.close(force: true);
    }
  }

  /// Read the repository listing at the pinned commit.
  Future<List<RemoteFile>> listFiles(HttpClient client) async {
    final entries = <Map<String, dynamic>>[];
    Uri? next = model.treeUri;
    for (var page = 0; next != null && page < 20; page++) {
      final request = await client.getUrl(next);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw _statusError('the model listing', response.statusCode);
      }
      // Automatic decompression is off (it would break ranged file downloads),
      // so a server that compresses the listing anyway is decoded here.
      final gzipped = response.headers
          .value(HttpHeaders.contentEncodingHeader)
          ?.toLowerCase()
          .contains('gzip');
      final Stream<List<int>> raw = gzipped == true
          ? response.cast<List<int>>().transform(gzip.decoder)
          : response;
      final body = await raw
          .transform(utf8.decoder)
          .join()
          .timeout(idleTimeout);
      final decoded = jsonDecode(body);
      if (decoded is! List) {
        throw ModelDownloadException(
          'The model listing was not understood.',
          retryable: true,
        );
      }
      entries.addAll(decoded.whereType<Map<String, dynamic>>());
      next = _nextLink(response, next);
    }
    return parseListing(entries);
  }

  /// Turn raw listing entries into the files to fetch, rejecting unsafe or
  /// incomplete listings.
  static List<RemoteFile> parseListing(List<Map<String, dynamic>> entries) {
    final files = <RemoteFile>[];
    for (final entry in entries) {
      if (entry['type'] != 'file') continue;
      final path = entry['path'];
      final size = entry['size'];
      if (path is! String || size is! int || size < 0) {
        throw ModelDownloadException('The model listing has a bad entry.');
      }
      if (_ignoredPaths.contains(path)) continue;
      if (!_isSafeRelativePath(path)) {
        throw ModelDownloadException(
          'The model listing has an unsafe file path.',
        );
      }
      final lfs = entry['lfs'];
      final sha = lfs is Map ? lfs['oid'] : null;
      final blob = entry['oid'];
      if (sha is! String && blob is! String) {
        throw ModelDownloadException('The model listing has no hash for a file.');
      }
      files.add(
        RemoteFile(
          path: path,
          size: size,
          sha256: sha is String ? sha.toLowerCase() : null,
          gitBlobSha1: sha is String ? null : (blob as String).toLowerCase(),
        ),
      );
    }
    final paths = files.map((f) => f.path).toSet();
    final hasWeights = paths.any((p) => p.endsWith('.weights'));
    for (final required in requiredBundleFiles) {
      if (!paths.contains(required)) {
        throw ModelDownloadException(
          'The model listing is missing $required.',
        );
      }
    }
    if (!hasWeights) {
      throw ModelDownloadException('The model listing has no weights files.');
    }
    return files;
  }

  /// Files in the repository that are not part of the model.
  static const _ignoredPaths = {'README.md', '.gitattributes'};

  static bool _isSafeRelativePath(String path) {
    if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
      return false;
    }
    return !path.split('/').any((s) => s.isEmpty || s == '.' || s == '..');
  }

  Uri? _nextLink(HttpClientResponse response, Uri current) {
    final link = response.headers.value('link');
    if (link == null) return null;
    final match = RegExp(r'<([^>]+)>\s*;\s*rel="next"').firstMatch(link);
    if (match == null) return null;
    return current.resolve(match.group(1)!);
  }

  Future<T> _withRetries<T>(String what, Future<T> Function() action) async {
    ModelDownloadException? last;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on ModelDownloadException catch (error) {
        if (!error.retryable) rethrow;
        last = error;
      } on SocketException catch (error) {
        last = ModelDownloadException(
          'Network error while downloading $what: ${error.message}',
          retryable: true,
        );
      } on HttpException catch (error) {
        last = ModelDownloadException(
          'Network error while downloading $what: ${error.message}',
          retryable: true,
        );
      } on TlsException catch (error) {
        last = ModelDownloadException(
          'Secure connection failed while downloading $what: ${error.message}',
          retryable: true,
        );
      } on TimeoutException {
        last = ModelDownloadException(
          'The connection stalled while downloading $what.',
          retryable: true,
        );
      }
      if (attempt < maxAttempts) await Future<void>.delayed(retryDelay * attempt);
    }
    throw last!;
  }

  /// Fetch one file into [target], resuming from `<target>.part`.
  Future<void> _fetch(
    HttpClient client,
    RemoteFile file,
    File target,
    void Function(int fileBytes) onBytes,
  ) async {
    final part = File('${target.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > file.size) {
      await part.delete();
      have = 0;
    }

    final hash = _FileHash(file);
    if (have > 0) {
      await for (final chunk in part.openRead()) {
        hash.add(chunk);
      }
    }

    if (have < file.size) {
      final request = await client.getUrl(model.fileUri(file.path));
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        await part.delete();
        throw ModelDownloadException(
          'The server could not resume ${file.path}.',
          retryable: true,
        );
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        throw _statusError(file.path, response.statusCode);
      }

      // Hugging Face's CDN compresses some small text files even when the
      // request asks for none. A range over a compressed stream is meaningless,
      // so a compressed answer is decoded whole, from the first byte.
      final encoding = response.headers
          .value(HttpHeaders.contentEncodingHeader)
          ?.toLowerCase();
      final compressed = encoding != null && encoding != 'identity';
      if (compressed && (encoding != 'gzip' || response.statusCode == 206)) {
        await response.drain<void>();
        if (await part.exists()) await part.delete();
        throw ModelDownloadException(
          'The server sent ${file.path} in a form that cannot be resumed.',
          retryable: true,
        );
      }

      var mode = FileMode.append;
      if (response.statusCode == 200 && have > 0) {
        // The server ignored the range and is sending the whole file.
        hash.reset();
        have = 0;
        mode = FileMode.write;
      }
      final Stream<List<int>> body = compressed
          ? response.cast<List<int>>().transform(gzip.decoder)
          : response;
      final sink = part.openWrite(mode: mode);
      var received = have;
      try {
        await for (final chunk in body.timeout(idleTimeout)) {
          hash.add(chunk);
          sink.add(chunk);
          received += chunk.length;
          onBytes(received);
          if (received > file.size) break;
        }
      } finally {
        await sink.close();
      }
      if (received != file.size) {
        // Keep a short file so the next attempt resumes; drop an overlong one.
        if (received > file.size) await part.delete();
        throw ModelDownloadException(
          'Download of ${file.path} ended early or ran long.',
          retryable: true,
        );
      }
    }

    if (!hash.matches()) {
      await part.delete();
      throw ModelDownloadException(
        'Downloaded ${file.path} failed its integrity check.',
        retryable: true,
      );
    }
    await part.rename(target.path);
  }

  ModelDownloadException _statusError(String what, int status) {
    final retryable = status == 408 || status == 429 || status >= 500;
    final reason = switch (status) {
      401 || 403 => 'access was refused',
      404 => 'it was not found',
      429 => 'the server is rate limiting requests',
      _ => 'the server answered $status',
    };
    return ModelDownloadException(
      'Could not download $what: $reason.',
      retryable: retryable,
    );
  }
}

/// Running hash of one file, computed with whichever algorithm the listing
/// publishes: SHA-256 for LFS/Xet files, git blob SHA-1 for small ones.
class _FileHash {
  _FileHash(this._file) {
    _start();
  }

  final RemoteFile _file;
  late _DigestSink _sink;
  late ByteConversionSink _input;

  void _start() {
    _sink = _DigestSink();
    if (_file.sha256 != null) {
      _input = sha256.startChunkedConversion(_sink);
    } else {
      _input = sha1.startChunkedConversion(_sink);
      _input.add(utf8.encode('blob ${_file.size}\u0000'));
    }
  }

  void add(List<int> chunk) => _input.add(chunk);

  void reset() => _start();

  bool matches() {
    _input.close();
    final actual = _sink.value.toString();
    return actual == (_file.sha256 ?? _file.gitBlobSha1);
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Limits progress callbacks to a few per second.
class _ProgressReporter {
  _ProgressReporter(this.total, this.callback);

  final int total;
  final void Function(double progress, String status) callback;
  final _clock = Stopwatch()..start();
  int _lastMs = -1000;

  void report(int bytes, {bool force = false}) {
    final ms = _clock.elapsedMilliseconds;
    if (!force && ms - _lastMs < 250) return;
    _lastMs = ms;
    final fraction = total == 0 ? 1.0 : (bytes / total).clamp(0.0, 1.0);
    callback(
      fraction,
      'Downloading the Qwen3.5 model: ${bytes ~/ (1024 * 1024)} of '
      '${total ~/ (1024 * 1024)} MB. Keep the app open; a Wi-Fi connection '
      'is best.',
    );
  }
}
