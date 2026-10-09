import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';

/// Service for managing a dedicated embedding model.
///
/// This service maintains a separate CactusLM instance specifically for
/// generating embeddings, allowing the main chat model to remain loaded
/// while still using the correct embedding model for RAG queries.
class EmbeddingService {
  CactusLM? _embeddingLm;
  bool _isInitialized = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';

  /// Embedding model slug - must match the model used in preprocessing.
  static const String embeddingModelSlug = 'qwen3-0.6-embed';

  bool get isInitialized => _isInitialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String get downloadStatus => _downloadStatus;

  /// Download the embedding model with progress callback
  Future<void> downloadModel({
    required void Function(double progress, String status) onProgress,
  }) async {
    if (_isDownloading) return;

    _isDownloading = true;
    debugPrint('[EMBED] Creating CactusLM instance for embedding model...');
    _embeddingLm = CactusLM(
      enableToolFiltering: false, // Not needed for embeddings
    );

    try {
      debugPrint('[EMBED] Downloading model: $embeddingModelSlug');
      await _embeddingLm!.downloadModel(
        model: embeddingModelSlug,
        downloadProcessCallback: (progress, status, isError) {
          _downloadProgress = progress ?? 0.0;
          _downloadStatus = status;
          debugPrint('[EMBED] Download progress: $progress, status: $status, error: $isError');
          onProgress(_downloadProgress, status);

          if (isError) {
            throw EmbeddingServiceException('Download failed: $status');
          }
        },
      );
      debugPrint('[EMBED] Download complete');
    } finally {
      _isDownloading = false;
    }
  }

  /// Initialize the embedding model for inference
  Future<void> initializeModel() async {
    if (_embeddingLm == null) {
      throw EmbeddingServiceException(
        'Model not downloaded. Call downloadModel first.',
      );
    }

    if (_isInitialized) return;

    await _embeddingLm!.initializeModel(
      params: CactusInitParams(model: embeddingModelSlug),
    );
    _isInitialized = true;
  }

  /// Combined initialize method - downloads and initializes the model
  Future<void> initialize({
    required void Function(double progress, String status) onProgress,
  }) async {
    if (_isInitialized) return;

    // Download model if not already downloaded
    onProgress(0.0, 'Downloading embedding model...');
    await downloadModel(onProgress: onProgress);

    // Initialize model for inference
    onProgress(0.95, 'Initializing embedding engine...');
    await initializeModel();

    onProgress(1.0, 'Embedding model ready');
  }

  /// Generate embedding for text
  Future<List<double>> generateEmbedding(String text) async {
    if (!_isInitialized) {
      throw EmbeddingServiceException(
        'Model not initialized. Call initialize first.',
      );
    }

    debugPrint('[EMBED] Generating embedding for: ${text.substring(0, text.length.clamp(0, 50))}...');

    final result = await _embeddingLm!.generateEmbedding(
      text: text,
      modelName: embeddingModelSlug,
    );

    debugPrint('[EMBED] Result success: ${result.success}, dimensions: ${result.embeddings.length}');

    if (!result.success) {
      throw EmbeddingServiceException(
        'Embedding generation failed: ${result.errorMessage}',
      );
    }

    return result.embeddings;
  }

  /// Unload the model and free resources
  void dispose() {
    _embeddingLm?.unload();
    _embeddingLm = null;
    _isInitialized = false;
    _downloadProgress = 0.0;
    _downloadStatus = '';
  }
}

/// Exception thrown by EmbeddingService
class EmbeddingServiceException implements Exception {
  final String message;

  EmbeddingServiceException(this.message);

  @override
  String toString() => 'EmbeddingServiceException: $message';
}
