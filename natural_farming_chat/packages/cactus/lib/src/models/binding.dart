import 'dart:ffi';
import 'package:ffi/ffi.dart';

final class CactusModelOpaque extends Opaque {}

typedef CactusModel = Pointer<CactusModelOpaque>;

typedef CactusTokenCallbackNative = Void Function(
    Pointer<Utf8> token, Uint32 tokenId, Pointer<Void> userData);
typedef CactusTokenCallbackDart = void Function(
    Pointer<Utf8> token, int tokenId, Pointer<Void> userData);

// Cactus SDK v2.0 uses the same initializer ABI on Android and Apple:
// (model_path, corpus_dir, cache_index).
typedef CactusInitNative = CactusModel Function(
    Pointer<Utf8> modelPath, Pointer<Utf8> corpusDir, Bool cacheIndex);
typedef CactusInitDart = CactusModel Function(
    Pointer<Utf8> modelPath, Pointer<Utf8> corpusDir, bool cacheIndex);

typedef CactusSetBackendNative = Int32 Function(Pointer<Utf8> backend);
typedef CactusSetBackendDart = int Function(Pointer<Utf8> backend);

typedef CactusCompleteNative = Int32 Function(
    CactusModel model,
    Pointer<Utf8> messagesJson,
    Pointer<Utf8> responseBuffer,
    Size bufferSize,
    Pointer<Utf8> optionsJson,
    Pointer<Utf8> toolsJson,
    Pointer<NativeFunction<CactusTokenCallbackNative>> callback,
    Pointer<Void> userData,
    Pointer<Uint8> pcmBuffer,
    Size pcmBufferSize);
typedef CactusCompleteDart = int Function(
    CactusModel model,
    Pointer<Utf8> messagesJson,
    Pointer<Utf8> responseBuffer,
    int bufferSize,
    Pointer<Utf8> optionsJson,
    Pointer<Utf8> toolsJson,
    Pointer<NativeFunction<CactusTokenCallbackNative>> callback,
    Pointer<Void> userData,
    Pointer<Uint8> pcmBuffer,
    int pcmBufferSize);

typedef CactusDestroyNative = Void Function(CactusModel model);
typedef CactusDestroyDart = void Function(CactusModel model);

typedef CactusResetNative = Void Function(CactusModel model);
typedef CactusResetDart = void Function(CactusModel model);

typedef CactusEmbedNative = Int32 Function(
    CactusModel model,
    Pointer<Utf8> text,
    Pointer<Float> embeddingsBuffer,
    Size bufferSize,
    Pointer<Size> embeddingDim);
typedef CactusEmbedDart = int Function(
    CactusModel model,
    Pointer<Utf8> text,
    Pointer<Float> embeddingsBuffer,
    int bufferSize,
    Pointer<Size> embeddingDim);

typedef CactusTranscribeNative = Int32 Function(
    CactusModel model,
    Pointer<Utf8> audioFilePath,
    Pointer<Utf8> prompt,
    Pointer<Utf8> responseBuffer,
    Size bufferSize,
    Pointer<Utf8> optionsJson,
    Pointer<NativeFunction<CactusTokenCallbackNative>> callback,
    Pointer<Void> userData,
    Pointer<Uint8> pcmBuffer,
    Size pcmBufferSize);
typedef CactusTranscribeDart = int Function(
    CactusModel model,
    Pointer<Utf8> audioFilePath,
    Pointer<Utf8> prompt,
    Pointer<Utf8> responseBuffer,
    int bufferSize,
    Pointer<Utf8> optionsJson,
    Pointer<NativeFunction<CactusTokenCallbackNative>> callback,
    Pointer<Void> userData,
    Pointer<Uint8> pcmBuffer,
    int pcmBufferSize);

typedef RegisterAppNative = Pointer<Utf8> Function(Pointer<Utf8> encData);
typedef RegisterAppDart = Pointer<Utf8> Function(Pointer<Utf8> encData);

typedef GetAllEntriesNative = Pointer<Utf8> Function();
typedef GetAllEntriesDart = Pointer<Utf8> Function();

typedef GetDeviceIdNative = Pointer<Utf8> Function(Pointer<Utf8> token);
typedef GetDeviceIdDart = Pointer<Utf8> Function(Pointer<Utf8> token);
