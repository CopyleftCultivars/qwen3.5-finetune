import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/models/chat_session.dart';
import 'package:natural_farming_chat/services/conversation_history.dart';
import 'package:natural_farming_chat/services/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'creates, switches, renames and deletes sessions across reloads',
    () async {
      final store = await SessionStore.open();
      expect(store.sessions, hasLength(1));
      final first = store.activeSession;

      final second = await store.createSession(title: 'Compost questions');
      expect(store.activeSessionId, second.id);
      expect(store.sessions.first.id, second.id);

      await store.switchSession(first.id);
      expect(store.activeSessionId, first.id);

      await store.renameSession(first.id, 'Garden planning');
      expect(store.activeSession.title, 'Garden planning');

      final reloaded = await SessionStore.open();
      expect(reloaded.activeSessionId, first.id);
      expect(reloaded.activeSession.title, 'Garden planning');
      expect(
        reloaded.sessions.map((session) => session.title),
        containsAll(<String>['Garden planning', 'Compost questions']),
      );

      await reloaded.deleteSession(second.id);
      expect(reloaded.sessions, hasLength(1));
      expect(reloaded.activeSessionId, first.id);

      await reloaded.deleteSession(first.id);
      expect(reloaded.sessions, hasLength(1));
      expect(reloaded.activeSession.messages, isEmpty);
      expect(
        reloaded.activeSession.id,
        isNot(anyOf(first.id, second.id)),
        reason: 'deleting the last session creates a fresh empty one',
      );
    },
  );

  test('messages persist per session and histories stay isolated', () async {
    final store = await SessionStore.open();
    final first = await store.createSession(title: 'Tomato');
    first.messages
      ..add(ChatMessage(content: 'Welcome', isUser: false))
      ..add(ChatMessage(content: 'How much compost?', isUser: true))
      ..add(ChatMessage(content: 'Two handfuls.', isUser: false));
    await store.saveActiveSession();

    final second = await store.createSession(title: 'Nettle');
    second.messages
      ..add(ChatMessage(content: 'Welcome', isUser: false))
      ..add(ChatMessage(content: 'When do I cut nettles?', isUser: true))
      ..add(ChatMessage(content: 'Before flowering.', isUser: false));
    await store.saveActiveSession();

    final firstHistory = buildSessionConversationHistory(first.messages);
    expect(firstHistory.map((message) => message.role), ['user', 'assistant']);
    expect(
      firstHistory.map((message) => message.content),
      ['How much compost?', 'Two handfuls.'],
      reason: 'the UI-only welcome message is excluded',
    );

    final secondHistory = buildSessionConversationHistory(second.messages);
    expect(secondHistory.map((message) => message.content), [
      'When do I cut nettles?',
      'Before flowering.',
    ]);
    expect(
      firstHistory.map((message) => message.content),
      isNot(contains('When do I cut nettles?')),
    );

    final reloaded = await SessionStore.open();
    final reloadedFirst = reloaded.sessions.firstWhere(
      (session) => session.id == first.id,
    );
    final reloadedSecond = reloaded.sessions.firstWhere(
      (session) => session.id == second.id,
    );
    expect(reloadedFirst.messages.map((message) => message.content), [
      'Welcome',
      'How much compost?',
      'Two handfuls.',
    ]);
    expect(reloadedSecond.messages.map((message) => message.content), [
      'Welcome',
      'When do I cut nettles?',
      'Before flowering.',
    ]);
  });

  test(
    'recipe continuation API seeds a user turn, reply and recipe JSON',
    () async {
      final store = await SessionStore.open();
      final recipe = <String, dynamic>{
        'status': 'ok',
        'candidate_plant': {'common_name': 'Stinging nettle'},
        'crop': {'common_name': 'Tomato'},
        'input': {'quantity': 25, 'unit': 'm2'},
      };

      final session = await store.createSessionFromRecipe(
        userMessage:
            'Bioaccumulator recipe: Stinging nettle for my tomato, 25 m2',
        assistantReply: 'Apply 2.5 kg of fresh nettle material.',
        recipe: recipe,
        title: 'Tomato + nettle',
      );

      expect(store.activeSessionId, session.id);
      expect(session.title, 'Tomato + nettle');
      expect(session.messages, hasLength(2));
      expect(session.messages.first.isUser, isTrue);
      expect(session.messages.last.isUser, isFalse);
      expect(session.messages.last.recipe, recipe);

      final history = buildSessionConversationHistory(session.messages);
      expect(history.map((message) => message.role), ['user', 'assistant']);
      expect(history.first.content, session.messages.first.content);
      expect(history.last.content, session.messages.last.content);

      final reloaded = await SessionStore.open();
      final restored = reloaded.sessions.firstWhere(
        (candidate) => candidate.id == session.id,
      );
      expect(restored.messages.last.recipe, recipe);
      expect(restored.messages.first.content, session.messages.first.content);
    },
  );

  test('migrates the pre-session chat history once', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'chat_history': jsonEncode([
        {
          'content': 'Earlier question',
          'isUser': true,
          'timestamp': '2026-10-19T10:00:00.000Z',
        },
        {
          'content': 'Earlier answer',
          'isUser': false,
          'timestamp': '2026-10-19T10:01:00.000Z',
        },
      ]),
    });

    final store = await SessionStore.open();
    expect(store.activeSession.title, 'Earlier chat');
    expect(store.activeSession.messages.map((message) => message.content), [
      'Earlier question',
      'Earlier answer',
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SessionStore.legacyChatHistoryKey), isNull);

    final reloaded = await SessionStore.open();
    expect(reloaded.sessions, hasLength(1));
  });
}
