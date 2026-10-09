import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/document.dart';
import '../models/document_chunk.dart';
import '../objectbox.g.dart';
import 'embedding_service.dart';

/// Service for managing RAG (Retrieval-Augmented Generation) operations
/// using direct ObjectBox access with a pre-built database.
///
/// This uses the same ObjectBox schema as the Cactus RAG implementation to ensure
/// database compatibility with pre-computed embeddings.
class RagService {
  Store? _store;
  Box<Document>? _documentBox;
  Box<DocumentChunk>? _chunkBox;
  EmbeddingService? _embeddingService;
  bool _isInitialized = false;
  bool _documentsLoaded = false;

  /// Search configuration
  static const int defaultTopK = 3;
  static const double maxDistance = 1.5;

  /// Asset path for pre-built database
  static const String prebuiltDbAsset = 'assets/rag_db/data.mdb';

  bool get isInitialized => _isInitialized;
  bool get documentsLoaded => _documentsLoaded;

  /// Initialize the RAG service with a dedicated embedding service
  Future<void> initialize(EmbeddingService embeddingService) async {
    if (_isInitialized) return;

    _embeddingService = embeddingService;

    // Extract pre-built database from assets BEFORE ObjectBox initializes
    final dbPath = await _extractPrebuiltDatabase();

    // Open ObjectBox store with the same model as the preprocessor
    print('[RAG] === Opening ObjectBox Store ===');
    print('[RAG] Opening store at: $dbPath');

    try {
      _store = Store(getObjectBoxModel(), directory: dbPath);
      print('[RAG] Store opened successfully');
    } catch (e, stackTrace) {
      print('[RAG] ERROR opening store: $e');
      print('[RAG] Stack trace: $stackTrace');
      rethrow;
    }

    print('[RAG] Creating Document box...');
    _documentBox = Box<Document>(_store!);
    print('[RAG] Document box created');

    print('[RAG] Creating DocumentChunk box...');
    _chunkBox = Box<DocumentChunk>(_store!);
    print('[RAG] DocumentChunk box created');

    // Immediately check counts after box creation
    print('[RAG] === Immediate Box Check ===');
    print('[RAG] Document count: ${_documentBox!.count()}');
    print('[RAG] Chunk count: ${_chunkBox!.count()}');

    _isInitialized = true;
    print('[RAG] ObjectBox store opened at $dbPath');
  }

  /// Generate embedding for search queries using dedicated embedding model
  Future<List<double>> _generateQueryEmbedding(String text) async {
    return await _embeddingService!.generateEmbedding(text);
  }

  /// Minimum expected database size in bytes (10MB).
  /// If existing database is smaller, it's likely stale/empty and needs re-extraction.
  static const int _minExpectedDbSize = 10 * 1024 * 1024;

  /// Extract pre-built ObjectBox database from assets and return the database path.
  /// Returns the directory path where ObjectBox data is stored.
  Future<String> _extractPrebuiltDatabase() async {
    print('[RAG] === Database Extraction ===');
    final appDir = await getApplicationDocumentsDirectory();
    final objectboxDir = Directory(p.join(appDir.path, 'objectbox'));
    final dataMdbFile = File(p.join(objectboxDir.path, 'data.mdb'));

    print('[RAG] App documents dir: ${appDir.path}');
    print('[RAG] Target objectbox dir: ${objectboxDir.path}');
    print('[RAG] Target data.mdb path: ${dataMdbFile.path}');

    bool needsExtraction = !await dataMdbFile.exists();

    // Check if existing database is too small (likely stale/empty from previous run)
    if (!needsExtraction) {
      final existingSize = await dataMdbFile.length();
      final existingSizeMB = (existingSize / 1024 / 1024).toStringAsFixed(2);
      print('[RAG] Existing data.mdb size: $existingSizeMB MB');

      if (existingSize < _minExpectedDbSize) {
        print('[RAG] Database too small (< 10MB), likely stale. Deleting and re-extracting...');
        await dataMdbFile.delete();
        // Also delete lock.mdb if present
        final lockFile = File(p.join(objectboxDir.path, 'lock.mdb'));
        if (await lockFile.exists()) {
          await lockFile.delete();
        }
        needsExtraction = true;
      }
    }

    if (needsExtraction) {
      print('[RAG] Extracting pre-built database from assets...');

      // Create directory
      if (!await objectboxDir.exists()) {
        await objectboxDir.create(recursive: true);
      }

      // Load from assets and write to file
      final assetData = await rootBundle.load(prebuiltDbAsset);
      final bytes = assetData.buffer.asUint8List();
      await dataMdbFile.writeAsBytes(bytes);

      final sizeMB = (bytes.length / 1024 / 1024).toStringAsFixed(2);
      print('[RAG] Extracted database: $sizeMB MB to ${objectboxDir.path}');
    } else {
      final size = await dataMdbFile.length();
      final sizeMB = (size / 1024 / 1024).toStringAsFixed(2);
      print('[RAG] Using existing database at ${objectboxDir.path}, size: $sizeMB MB');
    }

    return objectboxDir.path;
  }

  /// Load the knowledge base (marks as ready since data is pre-built)
  Future<void> loadKnowledgeBase({
    required void Function(double progress, String status) onProgress,
  }) async {
    if (!_isInitialized) {
      throw RagServiceException('RAG not initialized. Call initialize first.');
    }

    if (_documentsLoaded) {
      onProgress(1.0, 'Knowledge base already loaded');
      return;
    }

    onProgress(0.5, 'Loading pre-built knowledge base...');

    print('[RAG] === Loading Knowledge Base ===');

    // Verify documents exist in pre-built database
    final docs = _documentBox!.getAll();
    print('[RAG] Document count from getAll(): ${docs.length}');

    if (docs.isNotEmpty) {
      print('[RAG] First doc fileName: ${docs.first.fileName}');
      print('[RAG] First doc id: ${docs.first.id}');
    }

    if (docs.isEmpty) {
      print('[RAG] WARNING: No documents found in database!');
      print('[RAG] Checking chunk count directly...');
      final chunkCount = _chunkBox!.count();
      print('[RAG] Chunk count: $chunkCount');
      throw RagServiceException(
        'Pre-built database is empty. Ensure data.mdb was extracted correctly.',
      );
    }

    _documentsLoaded = true;
    final chunkCount = _chunkBox!.count();
    onProgress(1.0, 'Knowledge base ready (${docs.length} docs, $chunkCount chunks)');
    print('[RAG] Loaded ${docs.length} documents with $chunkCount chunks');
  }

  /// Search for relevant context given a query
  Future<String> searchContext(String query) async {
    if (!_isInitialized) {
      throw RagServiceException('RAG not initialized. Call initialize first.');
    }

    if (!_documentsLoaded) {
      return '';
    }

    // Generate embedding for the query
    final queryEmbedding = await _generateQueryEmbedding(query);

    // Use ObjectBox's native HNSW vector search
    final searchQuery = _chunkBox!
        .query(DocumentChunk_.embeddings.nearestNeighborsF32(queryEmbedding, defaultTopK))
        .build();

    final results = searchQuery.findWithScores();
    searchQuery.close();

    if (results.isEmpty) {
      return '';
    }

    final relevantChunks = results
        .where((result) => result.score <= maxDistance)
        .map((result) => result.object.content)
        .toList();

    if (relevantChunks.isEmpty) {
      return '';
    }

    return relevantChunks.join('\n\n---\n\n');
  }

  /// Search and return detailed results with metadata
  Future<List<SearchResult>> searchDetailed(String query, {int? limit}) async {
    if (!_isInitialized) {
      throw RagServiceException('RAG not initialized. Call initialize first.');
    }

    if (!_documentsLoaded) {
      return [];
    }

    // Generate embedding for the query
    final queryEmbedding = await _generateQueryEmbedding(query);

    // Use ObjectBox's native HNSW vector search
    final searchQuery = _chunkBox!
        .query(DocumentChunk_.embeddings.nearestNeighborsF32(queryEmbedding, limit ?? defaultTopK))
        .build();

    final results = searchQuery.findWithScores();
    searchQuery.close();

    return results
        .where((result) => result.score <= maxDistance)
        .map((result) => SearchResult(
              content: result.object.content,
              distance: result.score,
            ))
        .toList();
  }

  /// Get count of stored documents
  Future<int> getDocumentCount() async {
    if (!_isInitialized) return 0;
    return _documentBox!.count();
  }

  /// Release resources
  Future<void> dispose() async {
    _store?.close();
    _store = null;
    _documentBox = null;
    _chunkBox = null;
    _embeddingService = null;
    _isInitialized = false;
    _documentsLoaded = false;
  }
}

/// Result from a RAG search operation
class SearchResult {
  final String content;
  final double distance;

  SearchResult({
    required this.content,
    required this.distance,
  });

  double get similarity => 1.0 / (1.0 + distance);
}

/// Exception thrown by RagService
class RagServiceException implements Exception {
  final String message;

  RagServiceException(this.message);

  @override
  String toString() => 'RagServiceException: $message';
}
