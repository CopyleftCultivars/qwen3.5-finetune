import '../models/chat_session.dart';

/// Per-chat turn limit and prompt-token backstop (chainlink #119, #118; design docs/benchmark-results/app-turn-limit-design-2026-11-04.md).
///
/// Owner decisions, 2026-11-04: option B (the history is fixed by routing, the limit only keeps the app inside what was tested), **one hard stop at
/// 20 turns** (no soft warning, no 24), every turn counts (a plain answer, a full recipe turn or an error with no answer), count-only logs. The
/// prompt-token ceiling is a second hard stop for chats whose verbatim notes grow faster than the measured ledger.
///
/// Ceiling: the routed ledger's decision prompt averaged 1,311 to 1,589 tokens from 4 to 24 earlier turns (phone, #115, about 14 tokens per
/// turn); the app's own full history reached a mean of 6,119 tokens at 24 earlier turns without a memory or timeout problem (lowest free memory
/// 3.34 GiB). 4,096 is about 2.6 times the 24-turn routed mean, so ordinary chats never reach it, and below the largest prompt that ran cleanly.
///
/// Pure Dart, no model, no clock. A turn is counted from the message list, so a new chat (empty list) resets it and a saved chat keeps its count.

const int turnLimit = 20;
const int promptTokenCeiling = 4096;

enum TurnLimitReason { none, turns, tokens }

class TurnLimitStatus {
  const TurnLimitStatus({required this.completedTurns, required this.limit, required this.reason, required this.promptTokens});

  final int completedTurns;
  final int limit;
  final TurnLimitReason reason;

  /// Decision-prompt token count of the last turn (0 when unknown).
  final int promptTokens;

  bool get stopped => reason != TurnLimitReason.none;

  /// `none` or `hard` (the state names of the device-log record).
  String get state => stopped ? 'hard' : 'none';

  /// The fixed, value-free message of the hard stop; null when sending is allowed.
  String? get message => switch (reason) {
        TurnLimitReason.none => null,
        TurnLimitReason.turns => hardStopTurnsMessage(limit),
        TurnLimitReason.tokens => hardStopTokensMessage,
      };

  /// Counts only: no text, no entity values.
  String get logLine => '[TURN_LIMIT] completed=$completedTurns limit=$limit state=$state reason=${reason.name} prompt_tokens=$promptTokens';
}

String hardStopTurnsMessage(int limit) => 'This chat has reached its turn limit ($limit). Start a new chat to continue.';
const String hardStopTokensMessage = 'This chat has grown too long to continue. Start a new chat to continue.';

/// Finished turns: a user message that an assistant message (answer or error text) follows. The welcome message is an assistant message and never
/// follows a user message, and a turn still running has no assistant message yet, so neither counts.
int completedTurns(List<ChatMessage> messages) {
  var turns = 0;
  for (var index = 0; index + 1 < messages.length; index++) {
    if (messages[index].isUser && !messages[index + 1].isUser) turns++;
  }
  return turns;
}

TurnLimitStatus turnLimitStatus(
  List<ChatMessage> messages, {
  int lastPromptTokens = 0,
  int limit = turnLimit,
  int ceiling = promptTokenCeiling,
}) {
  final turns = completedTurns(messages);
  final reason = turns >= limit
      ? TurnLimitReason.turns
      : lastPromptTokens > ceiling
          ? TurnLimitReason.tokens
          : TurnLimitReason.none;
  return TurnLimitStatus(completedTurns: turns, limit: limit, reason: reason, promptTokens: lastPromptTokens);
}
