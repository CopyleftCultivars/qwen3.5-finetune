import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/model_downloader.dart';

/// Downloads the real pinned bundle from Hugging Face (about 1.1 GB, no token).
///
///     HF_NETWORK_TEST=1 flutter test test/model_downloader_network_test.dart
///
/// Set `HF_NETWORK_COMPARE_DIR` to a local copy of the bundle to also compare
/// every file's SHA-256 with it.
void main() {
  final enabled = Platform.environment['HF_NETWORK_TEST'] == '1';

  test(
    'the pinned bundle downloads and verifies from Hugging Face',
    () async {
      final temp = await Directory.systemTemp.createTemp('hf_network_test');
      addTearDown(() => temp.delete(recursive: true));
      final destination = Directory('${temp.path}/bundle');

      final progress = <double>[];
      await ModelDownloader(model: hostedQwen35Model).download(
        destination: destination,
        onProgress: (p, _) => progress.add(p),
      );

      final files = await destination
          .list(recursive: true)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      var bytes = 0;
      for (final file in files) {
        bytes += await file.length();
      }
      // ignore: avoid_print
      print('downloaded ${files.length} files, $bytes bytes');
      for (final required in requiredBundleFiles) {
        expect(File('${destination.path}/$required').existsSync(), isTrue);
      }
      expect(files.where((f) => f.path.endsWith('.part')), isEmpty);
      expect(progress.last, 1.0);

      final compare = Platform.environment['HF_NETWORK_COMPARE_DIR'];
      if (compare != null) {
        final local = await Directory(compare)
            .list(recursive: true)
            .where((e) => e is File)
            .cast<File>()
            .toList();
        expect(files.length, local.length);
        for (final file in local) {
          final relative = file.path.substring(compare.length + 1);
          final got = File('${destination.path}/$relative');
          expect(got.existsSync(), isTrue, reason: relative);
          expect(
            (await sha256.bind(got.openRead()).first).toString(),
            (await sha256.bind(file.openRead()).first).toString(),
            reason: relative,
          );
        }
      }
    },
    skip: enabled ? false : 'set HF_NETWORK_TEST=1 to download 1.1 GB',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
