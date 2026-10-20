import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_session.dart';

/// Local persistence for chat sessions.
///
/// Sessions are stored as one versioned JSON envelope in SharedPreferences,
/// reusing the store the app already used for `chat_history`. The ObjectBox
/// database remains the read-only RAG database whose schema is shared with the
/// Cactus reference implementation, so adding chat entities there would risk
/// that portability guarantee for no benefit at this data size.
class SessionStore {
  static const String storageKey = 'chat_sessions_v1';
  static const String activeSessionKey = 'active_chat_session_id';
  static const String legacyChatHistoryKey = 'chat_history';
  static const String schemaVersion = 'chat_sessions_v1';

  static int _idCounter = 0;

  final SharedPreferences _preferences;
  final List<ChatSession> _sessions;
  String? _activeSessionId;

  SessionStore._(this._preferences, this._sessions, this._activeSessionId);

  /// Opens the store, migrating the pre-session `chat_history` value once.
  ///
  /// The returned store always has at least one session and an active session.
  static Future<SessionStore> open({SharedPreferences? preferences}) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final store = SessionStore._(prefs, <ChatSession>[], null);

    final raw = prefs.getString(storageKey);
    if (raw != null) {
      try {
        store._load(jsonDecode(raw));
      } catch (_) {
        store._sessions.clear();
      }
    }

    if (store._sessions.isEmpty) {
      await store._migrateLegacyHistory();
    }
    if (store._sessions.isEmpty) {
      store._sessions.add(store._newSession(title: 'New chat'));
    }

    final savedActive = prefs.getString(activeSessionKey);
    if (savedActive != null &&
        store._sessions.any((session) => session.id == savedActive)) {
      store._activeSessionId = savedActive;
    } else {
      store._activeSessionId = store._sessions.first.id;
    }

    // Persist on first open as well, so the active id and the migration result
    // exist for the next launch.
    await store._persist();
    return store;
  }

  /// Sessions ordered by most recent activity, newest first.
  List<ChatSession> get sessions {
    final sorted = [..._sessions]
      ..sort((a, b) {
        final byUpdated = b.updatedAt.compareTo(a.updatedAt);
        if (byUpdated != 0) return byUpdated;
        return b.createdAt.compareTo(a.createdAt);
      });
    return List.unmodifiable(sorted);
  }

  ChatSession get activeSession {
    final activeId = _activeSessionId;
    if (activeId != null) {
      for (final session in _sessions) {
        if (session.id == activeId) return session;
      }
    }
    return _sessions.first;
  }

  String get activeSessionId => activeSession.id;

  Future<ChatSession> createSession({
    String? title,
    List<ChatMessage>? messages,
  }) async {
    final session = _newSession(
      title: _normalizeTitle(title),
      messages: List<ChatMessage>.from(messages ?? const <ChatMessage>[]),
    );
    _sessions.insert(0, session);
    _activeSessionId = session.id;
    await _persist();
    return session;
  }

  /// Seeds a session for #20's "Continue chat?" action.
  ///
  /// The user's recipe trigger and the assistant's reply (with the full
  /// deterministic recipe JSON used by the card) become the session's first
  /// two turns. No welcome message is added, so the recipe conversation starts
  /// exactly where the recipe result left off.
  Future<ChatSession> createSessionFromRecipe({
    required String userMessage,
    required String assistantReply,
    Map<String, dynamic>? recipe,
    String? title,
    DateTime? timestamp,
  }) {
    final now = timestamp ?? DateTime.now();
    return createSession(
      title: title ?? 'Recipe chat',
      messages: [
        ChatMessage(content: userMessage, isUser: true, timestamp: now),
        ChatMessage(
          content: assistantReply,
          isUser: false,
          timestamp: now,
          recipe: recipe,
        ),
      ],
    );
  }

  Future<void> switchSession(String id) async {
    if (!_sessions.any((session) => session.id == id)) {
      throw ArgumentError.value(id, 'id', 'Unknown chat session');
    }
    _activeSessionId = id;
    await _persist();
  }

  Future<ChatSession> renameSession(String id, String title) async {
    final normalized = title.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Session title is empty');
    }
    final session = _sessionById(id);
    session
      ..title = normalized
      ..updatedAt = DateTime.now();
    await _persist();
    return session;
  }

  /// Deletes a session. If it was active, the most recent remaining session is
  /// activated; deleting the last session creates a fresh empty one.
  Future<void> deleteSession(String id) async {
    final session = _sessionById(id);
    _sessions.remove(session);
    if (_sessions.isEmpty) {
      _sessions.add(_newSession(title: 'New chat'));
    }
    if (_activeSessionId == id) {
      _activeSessionId = sessions.first.id;
    }
    await _persist();
  }

  /// Replaces a session's messages, then persists it.
  Future<void> saveMessages(String id, List<ChatMessage> messages) async {
    final session = _sessionById(id);
    if (!identical(session.messages, messages)) {
      session.messages
        ..clear()
        ..addAll(messages);
    }
    session.updatedAt = DateTime.now();
    await _persist();
  }

  /// Persists the active session's current messages and activity time.
  Future<void> saveActiveSession() async {
    activeSession.updatedAt = DateTime.now();
    await _persist();
  }

  ChatSession _sessionById(String id) {
    for (final session in _sessions) {
      if (session.id == id) return session;
    }
    throw ArgumentError.value(id, 'id', 'Unknown chat session');
  }

  ChatSession _newSession({
    required String title,
    List<ChatMessage>? messages,
  }) {
    final now = DateTime.now();
    return ChatSession(
      id: _newId(),
      title: title,
      createdAt: now,
      updatedAt: now,
      messages: messages,
    );
  }

  String _normalizeTitle(String? title) {
    final normalized = title?.trim();
    return normalized == null || normalized.isEmpty ? 'New chat' : normalized;
  }

  static String _newId() {
    _idCounter += 1;
    return 'session-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_idCounter';
  }

  void _load(dynamic decoded) {
    final rawSessions = decoded is List
        ? decoded
        : (decoded as Map<String, dynamic>)['sessions'] as List? ?? const [];
    for (final raw in rawSessions) {
      try {
        _sessions.add(ChatSession.fromJson(raw as Map<String, dynamic>));
      } catch (_) {
        // Skip a malformed session instead of losing the rest.
      }
    }
  }

  Future<void> _migrateLegacyHistory() async {
    final raw = _preferences.getString(legacyChatHistoryKey);
    if (raw == null) return;
    try {
      final messages = [
        for (final item in jsonDecode(raw) as List)
          ChatMessage.fromJson(item as Map<String, dynamic>),
      ];
      if (messages.isNotEmpty) {
        final now = DateTime.now();
        _sessions.add(
          ChatSession(
            id: _newId(),
            title: 'Earlier chat',
            createdAt: now,
            updatedAt: now,
            messages: messages,
          ),
        );
      }
    } catch (_) {
      // Keep the legacy value if it cannot be parsed; the user can still clear
      // it from the app.
      return;
    }
    await _preferences.remove(legacyChatHistoryKey);
  }

  Future<void> _persist() async {
    await _preferences.setString(
      storageKey,
      jsonEncode({
        'schema_version': schemaVersion,
        'sessions': _sessions.map((session) => session.toJson()).toList(),
      }),
    );
    await _preferences.setString(activeSessionKey, activeSession.id);
  }
}
