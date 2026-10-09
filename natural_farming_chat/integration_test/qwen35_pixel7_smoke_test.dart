// Chainlink #246: Qwen3.5-2B Pixel 7 fit + smoke test, step 1-2 of 4
// (cactus_init succeeds; unarmed generation is coherent).
//
// Does NOT go through ModelService (that's hardcoded to the production
// distill-v2 slug/download URL) -- uses CactusLM directly against a bundle
// pre-pushed to <appDocDir>/models/$kModelSlug/ via adb (push script run
// separately, see localllm-qwen3.5/short-conv-matcher-evidence/).
//
// Run with:
//   flutter test integration_test/qwen35_pixel7_smoke_test.dart -d <device_id>
//
// Writes: <appDocDir>/qwen35_smoke_result.json (adb-pullable afterward)

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

String getLastNativeError() {
  try {
    final lib = DynamicLibrary.open(
      Platform.isAndroid ? 'libcactus.so' : 'cactus.framework/cactus',
    );
    final getLastError = lib
        .lookup<NativeFunction<Pointer<Utf8> Function()>>('cactus_get_last_error')
        .asFunction<Pointer<Utf8> Function()>();
    final ptr = getLastError();
    if (ptr.address == 0) return '(no error message)';
    return ptr.toDartString();
  } catch (e) {
    return '(could not read native error: $e)';
  }
}

const String kModelSlug = 'qwen35-2b-smoke';
const String kStagingDir = '/data/local/tmp/qwen35-2b-smoke';

const List<String> kPrompts = [
  'The best fertilizer for tomatoes depends on the',
  'Tell me about Korean natural farming inputs',
  'Describe how to make biochar',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('qwen3.5-2b pixel7 smoke: init + coherent generation', (tester) async {
    final docDir = await getApplicationDocumentsDirectory();
    final modelDir = Directory('${docDir.path}/models/$kModelSlug');
    final result = <String, dynamic>{'issue': 246, 'model_dir': modelDir.path};

    var configFile = File('${modelDir.path}/config.txt');
    if (!await configFile.exists()) {
      // Bundle lives at a world-readable staging path (adb-pushed there
      // separately, since the app's own private storage only exists -- and
      // only has this app's own permissions -- once the app itself is
      // running; `run-as` can't help here because `flutter test` uninstalls
      // the app, wiping app_flutter, right after each run). Copy it in
      // using the app's own file-IO permissions as the test's first step.
      final staging = Directory(kStagingDir);
      result['staging_exists'] = await staging.exists();
      if (!await staging.exists()) {
        result['error'] = 'neither ${modelDir.path} nor $kStagingDir exist -- push the bundle first';
        await _writeResult(docDir, result);
        fail('bundle not found at ${modelDir.path} or staging path $kStagingDir');
      }
      print('[SMOKE] copying bundle from $kStagingDir to ${modelDir.path} ...');
      final sw = Stopwatch()..start();
      await modelDir.create(recursive: true);
      await for (final entity in staging.list(recursive: true, followLinks: false)) {
        final relative = entity.path.substring(staging.path.length);
        final destPath = '${modelDir.path}$relative';
        if (entity is Directory) {
          await Directory(destPath).create(recursive: true);
        } else if (entity is File) {
          await Directory(File(destPath).parent.path).create(recursive: true);
          await entity.copy(destPath);
        }
      }
      sw.stop();
      print('[SMOKE] copy done in ${sw.elapsedMilliseconds}ms');
      result['copy_ms'] = sw.elapsedMilliseconds;
    }

    configFile = File('${modelDir.path}/config.txt');
    result['config_exists'] = await configFile.exists();
    if (!await configFile.exists()) {
      result['error'] = 'copy completed but config.txt still missing at ${modelDir.path}';
      await _writeResult(docDir, result);
      fail('config.txt missing at ${modelDir.path} after copy');
    }

    final lm = CactusLM();
    bool initOk = false;
    String? initError;
    String? nativeError;
    try {
      await lm.initializeModel(params: CactusInitParams(model: kModelSlug));
      initOk = true;
    } catch (e) {
      initError = e.toString();
      nativeError = getLastNativeError();
    }
    result['init_ok'] = initOk;
    result['init_error'] = initError;
    result['native_error'] = nativeError;
    print('[SMOKE] init_ok=$initOk error=$initError native_error=$nativeError');

    if (!initOk) {
      await _writeResult(docDir, result);
      fail('cactus_init failed: $initError');
    }

    final gens = <Map<String, dynamic>>[];
    for (final prompt in kPrompts) {
      final sw = Stopwatch()..start();
      CactusCompletionResult? r;
      String? genError;
      try {
        r = await lm.generateCompletion(
          messages: [ChatMessage(content: prompt, role: 'user')],
          params: CactusCompletionParams(maxTokens: 16, temperature: 0.0),
        );
      } catch (e) {
        genError = e.toString();
      }
      sw.stop();
      final record = {
        'prompt': prompt,
        'success': r?.success ?? false,
        'response': r?.response ?? '',
        'error': genError,
        'elapsed_ms': sw.elapsedMilliseconds,
        'prefill_tokens': r?.prefillTokens,
        'decode_tokens': r?.decodeTokens,
        'tokens_per_second': r?.tokensPerSecond,
      };
      gens.add(record);
      print('[SMOKE] gen: ${jsonEncode(record)}');
    }
    result['generations'] = gens;
    result['all_succeeded'] = gens.every((g) => g['success'] == true);
    result['all_nonempty'] = gens.every((g) => (g['response'] as String).trim().isNotEmpty);

    lm.unload();
    await _writeResult(docDir, result);

    expect(result['all_succeeded'], isTrue, reason: 'every generation must report success');
    expect(result['all_nonempty'], isTrue, reason: 'every generation must produce non-empty text');
  }, timeout: const Timeout(Duration(minutes: 30)));
}

Future<void> _writeResult(Directory docDir, Map<String, dynamic> result) async {
  final out = File('${docDir.path}/qwen35_smoke_result.json');
  await out.writeAsString(jsonEncode(result));
  print('[SMOKE] wrote ${out.path}');
}
