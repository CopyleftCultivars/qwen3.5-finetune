import 'package:cactus/cactus.dart' as cactus;

import '../models/chat_session.dart';

/// Build the model history for one session in the #19 runner order.
///
/// The runner appends every earlier turn's user message and its complete final
/// answer, in order, with no character budget. The app's welcome message is
/// UI-only, so it is excluded when it is the first assistant message. Recipe
/// JSON, timestamps and session titles are UI state and never included.
List<cactus.ChatMessage> buildSessionConversationHistory(
  List<ChatMessage> messages,
) {
  final history = <cactus.ChatMessage>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (i == 0 && !message.isUser) continue;
    history.add(
      cactus.ChatMessage(
        content: message.content,
        role: message.isUser ? 'user' : 'assistant',
      ),
    );
  }
  return history;
}
