import 'package:objectbox/objectbox.dart';
import 'document_chunk.dart';

/// Document entity for storing source documents.
/// Schema MUST match the Cactus RAG implementation exactly for database portability.
@Entity()
class Document {
  @Id()
  int id = 0;

  @Unique()
  late String fileName;

  late String filePath;

  @Property(type: PropertyType.date)
  late DateTime createdAt;

  @Property(type: PropertyType.date)
  late DateTime updatedAt;

  int? fileSize;
  String? fileHash;

  @Backlink('document')
  final chunks = ToMany<DocumentChunk>();

  Document({
    this.id = 0,
    required this.fileName,
    required this.filePath,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.fileSize,
    this.fileHash,
  }) {
    this.createdAt = createdAt ?? DateTime.now();
    this.updatedAt = updatedAt ?? DateTime.now();
  }

  Document.empty() {
    fileName = '';
    filePath = '';
    createdAt = DateTime.now();
    updatedAt = DateTime.now();
  }

  String get content => chunks.map((c) => c.content).join('\n\n');
}
