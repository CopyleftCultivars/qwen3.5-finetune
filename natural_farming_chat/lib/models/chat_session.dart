/// A single chat message, including an optional deterministic recipe result.
///
/// The model history is built from these messages by
/// `buildSessionConversationHistory`; [recipe] is only UI state for the
/// "Show full recipe" card and is never sent to the model.
class ChatMessage {
  final String content;
  final bool isUser;
  final DateTime timestamp;

  /// Full deterministic recipe-tool result for the "Show full recipe" card.
  final Map<String, dynamic>? recipe;

  ChatMessage({
    required this.content,
    required this.isUser,
    DateTime? timestamp,
    this.recipe,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Convert to JSON for persistence.
  Map<String, dynamic> toJson() => {
    'content': content,
    'isUser': isUser,
    'timestamp': timestamp.toIso8601String(),
    if (recipe != null) 'recipe': recipe,
  };

  /// Create from JSON.
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    content: json['content'] as String,
    isUser: json['isUser'] as bool,
    timestamp: DateTime.parse(json['timestamp'] as String),
    recipe: json['recipe'] as Map<String, dynamic>?,
  );
}

/// One locally persisted conversation.
///
/// A session owns its own message list. Switching sessions therefore swaps the
/// whole list, and `buildSessionConversationHistory` only ever sees the active
/// session's turns.
class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    List<ChatMessage>? messages,
  }) : messages = messages ?? <ChatMessage>[];

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((message) => message.toJson()).toList(),
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'] as List? ?? const [];
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      messages: [
        for (final raw in rawMessages)
          ChatMessage.fromJson(raw as Map<String, dynamic>),
      ],
    );
  }
}
