import 'package:objectbox/objectbox.dart';
import 'document.dart';

/// DocumentChunk entity for storing chunked text with embeddings.
/// Schema MUST match the Cactus RAG implementation exactly for database portability.
@Entity()
class DocumentChunk {
  @Id()
  int id = 0;

  late String content;

  /// Vector embeddings for HNSW similarity search.
  /// Dimensions: 1024 (matches Cactus embedding model)
  @Property(type: PropertyType.floatVector)
  @HnswIndex(dimensions: 1024)
  late List<double> embeddings;

  final document = ToOne<Document>();

  DocumentChunk({
    this.id = 0,
    required this.content,
    required this.embeddings,
  });
}
