import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/models/chat_session.dart';
import 'package:natural_farming_chat/services/turn_limit.dart';

List<ChatMessage> chat(int finishedTurns, {bool running = false, bool welcome = true}) => [
      if (welcome) ChatMessage(content: 'Welcome.', isUser: false),
      for (var i = 0; i < finishedTurns; i++) ...[
        ChatMessage(content: 'q$i', isUser: true),
        ChatMessage(content: 'a$i', isUser: false),
      ],
      if (running) ChatMessage(content: 'pending', isUser: true),
    ];

void main() {
  test('the limit is 20 and the ceiling is 4096', () {
    expect(turnLimit, 20);
    expect(promptTokenCeiling, 4096);
  });

  test('the welcome message and a running turn do not count', () {
    expect(completedTurns(chat(0)), 0);
    expect(completedTurns(chat(3, running: true)), 3);
    expect(completedTurns(chat(3, welcome: false)), 3);
    expect(completedTurns([]), 0);
  });

  test('nineteen turns still send; the twentieth is the last; the next is stopped', () {
    expect(turnLimitStatus(chat(19)).stopped, isFalse);
    expect(turnLimitStatus(chat(19)).message, isNull);
    final stopped = turnLimitStatus(chat(20));
    expect(stopped.stopped, isTrue);
    expect(stopped.reason, TurnLimitReason.turns);
    expect(stopped.message, 'This chat has reached its turn limit (20). Start a new chat to continue.');
  });

  test('a turn that ended in an error text counts like any other', () {
    final messages = [
      ChatMessage(content: 'q', isUser: true),
      ChatMessage(content: 'Sorry, I encountered an error: x', isUser: false),
    ];
    expect(completedTurns(messages), 1);
  });

  test('a prompt over the ceiling stops the chat, at the ceiling it does not', () {
    expect(turnLimitStatus(chat(3), lastPromptTokens: 4096).stopped, isFalse);
    final stopped = turnLimitStatus(chat(3), lastPromptTokens: 4097);
    expect(stopped.reason, TurnLimitReason.tokens);
    expect(stopped.message, hardStopTokensMessage);
  });

  test('the turn reason wins when both apply', () {
    expect(turnLimitStatus(chat(20), lastPromptTokens: 9000).reason, TurnLimitReason.turns);
  });

  test('a new chat starts again: the empty list has no stop', () {
    expect(turnLimitStatus(chat(0)).stopped, isFalse);
  });

  test('messages and the log line hold no digits beyond the fixed counts and no text', () {
    expect(hardStopTokensMessage, isNot(matches(RegExp(r'\d'))));
    final status = turnLimitStatus(chat(5), lastPromptTokens: 1300);
    expect(status.logLine, '[TURN_LIMIT] completed=5 limit=20 state=none reason=none prompt_tokens=1300');
    expect(turnLimitStatus(chat(20)).logLine, contains('state=hard reason=turns'));
  });

  test('limit and ceiling can be set (the phone harness shortens the limit for a smoke test)', () {
    expect(turnLimitStatus(chat(4), limit: 4).stopped, isTrue);
    expect(turnLimitStatus(chat(4), limit: 4).message, 'This chat has reached its turn limit (4). Start a new chat to continue.');
  });
}
