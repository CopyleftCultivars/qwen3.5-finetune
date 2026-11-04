import 'package:cactus/cactus.dart' as cactus;

import '../models/chat_session.dart';
import 'format_g.dart';

export 'format_g.dart' show formatG;

/// Routed model history (chainlink #116; host #110, phone #115, fill #113).
///
/// The app used to send every earlier user message plus the final answer shown
/// (no tool messages). In that shape the model lost the recipe call at the first
/// earlier recipe turn (phone: 0 of 12). This file decides, per new message:
///
/// * a message the trigger parser accepts is decided with an EMPTY history
///   (route `trigger_empty`);
/// * a bare area right after a missing-area trigger message that ended without a
///   recipe is rebuilt into the full trigger message from the user's own words and
///   decided with an empty history (route `followup_fill`, `followup_fill_v1`);
/// * every other message sees the compact ledger of earlier recipe results
///   (route `ledger`, `context_ledger_v1.1`).
///
/// Pure Dart, no model, no clock. The Python references are
/// `context_ledger.py`, `followup_fill.py` and `session_length.view_for`; the
/// golden file `test/fixtures/routed_history_goldens.json` is generated from them.
/// The ledger copies plant, crop and area from the recipe tool's served view and
/// computes nothing.

const String ledgerVersion = 'context_ledger_v1.1';
const String fillVersion = 'followup_fill_v1';
const String ledgerHeader =
    'Earlier in this conversation (from the recorded tool results):';
const String ledgerNotesHeader = 'Your notes since then:';
const String ledgerAck = 'Understood.';

/// The recipe tool's served view of a full result (`RecipeToolService.servedView`).
typedef ServedView = Map<String, dynamic> Function(Map<String, dynamic> recipe);

/// `null` when the trigger parser accepts [text]; otherwise the parser's error code
/// (`trigger_not_matched`, `unsupported_unit`, `invalid_quantity`).
typedef TriggerCode = String? Function(String text);

class RoutedTurn {
  /// The text the model decides on (the user's own text, or the rebuilt trigger message).
  final String question;
  final List<cactus.ChatMessage> history;

  /// `trigger_empty`, `followup_fill` or `ledger`.
  final String route;

  /// Count-only description for logs; never carries message text.
  final Map<String, Object> audit;

  const RoutedTurn({
    required this.question,
    required this.history,
    required this.route,
    required this.audit,
  });
}

/// Decide the question and history for [text], given the session's [messages]
/// as they are BEFORE the new user message is added.
RoutedTurn routeTurn({
  required List<ChatMessage> messages,
  required String text,
  required ServedView servedView,
  required TriggerCode triggerCode,
}) {
  if (triggerCode(text) == null) {
    return RoutedTurn(
      question: text,
      history: const [],
      route: 'trigger_empty',
      audit: const {'ledger_entries': 0, 'notes': 0},
    );
  }
  final fill = _fillFor(messages, text, triggerCode);
  if (fill != null) {
    return RoutedTurn(
      question: fill,
      history: const [],
      route: 'followup_fill',
      audit: const {'ledger_entries': 0, 'notes': 0},
    );
  }
  final ledger = buildLedger(messages, servedView);
  return RoutedTurn(
    question: text,
    history: renderLedgerMessages(ledger),
    route: 'ledger',
    audit: {'ledger_entries': ledger.entries.length, 'notes': ledger.notes.length},
  );
}

// ---------------------------------------------------------------------------
// Follow-up fill (followup_fill_v1)
// ---------------------------------------------------------------------------

const String _unit = r'(?:m2|m²|sq m|square metres|square meters)';

final RegExp _missingArea = RegExp(
  r'^\s*Bioaccumulator recipe:\s*(?<plant>[^,;\d]+?)\s+for my\s+(?<crop>[^,;\d]+?)\s*'
  '(?:,\\s*(?:$_unit|some area)?\\s*)?\$',
  caseSensitive: false,
);

final RegExp _bareArea = RegExp(
  "^\\s*(?:it(?:'s| is)|the area is|area(?: is)?:?)?\\s*(?<number>\\d+(?:\\.\\d+)?)\\s*(?<unit>$_unit)\\s*\\.?\\s*\$",
  caseSensitive: false,
);

/// The rebuilt trigger message, or null when the fill does not apply. Applies only
/// when the last turn ended without a recipe, the message before it was a
/// missing-area trigger message the parser rejects as not matched, and [text] is a
/// bare area. [messages] must exclude the welcome message handling: the welcome
/// is an assistant message and is never a user message, so it cannot match.
String? _fillFor(List<ChatMessage> messages, String text, TriggerCode triggerCode) {
  if (messages.length < 2) return null;
  final last = messages[messages.length - 1];
  final previous = messages[messages.length - 2];
  if (last.isUser || !previous.isUser) return null;
  if (last.recipe != null) return null;
  final follow = _bareArea.firstMatch(text);
  if (follow == null) return null;
  final missing = _missingArea.firstMatch(previous.content);
  if (missing == null || triggerCode(previous.content) != 'trigger_not_matched') {
    return null;
  }
  final message =
      'Bioaccumulator recipe: ${missing.namedGroup('plant')!.trim()} for my '
      '${missing.namedGroup('crop')!.trim()}, ${follow.namedGroup('number')} '
      '${follow.namedGroup('unit')}';
  if (triggerCode(message) != null) return null;
  return message;
}

/// Test hook: the fill alone, as `followup_fill.fill(previous_user, ended_without_recipe, user)`.
String? followupFill({
  required String? previousUser,
  required bool previousEndedWithoutRecipe,
  required String text,
  required TriggerCode triggerCode,
}) {
  if (previousUser == null || !previousEndedWithoutRecipe) return null;
  return _fillFor(
    [
      ChatMessage(content: previousUser, isUser: true),
      ChatMessage(content: '', isUser: false),
    ],
    text,
    triggerCode,
  );
}

// ---------------------------------------------------------------------------
// Context ledger (context_ledger_v1 / v1.1 render)
// ---------------------------------------------------------------------------

class LedgerEntry {
  final int ordinal;

  /// `ok`, `error` or `unresolved`.
  final String kind;
  final String? candidatePlant;
  final String? crop;
  final double? areaM2;
  final String? errorCode;
  final String? requestText;
  int? supersededBy;

  LedgerEntry({
    required this.ordinal,
    required this.kind,
    this.candidatePlant,
    this.crop,
    this.areaM2,
    this.errorCode,
    this.requestText,
  });
}

class LedgerNote {
  final int afterOrdinal;
  final String text;
  const LedgerNote(this.afterOrdinal, this.text);
}

class Ledger {
  final List<LedgerEntry> entries;
  final List<LedgerNote> notes;
  const Ledger(this.entries, this.notes);
}

/// One entry per user message directly followed by an assistant message that
/// holds a recipe result; every other user message is a verbatim note; assistant
/// text is dropped. The welcome message is an assistant message, so it drops out.
Ledger buildLedger(List<ChatMessage> messages, ServedView servedView) {
  final entries = <LedgerEntry>[];
  final notes = <LedgerNote>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (!message.isUser) continue;
    final next = i + 1 < messages.length ? messages[i + 1] : null;
    final paired = next != null && !next.isUser && next.recipe != null;
    if (!paired) {
      notes.add(LedgerNote(entries.length, message.content));
      continue;
    }
    final view = servedView(next.recipe!);
    final ordinal = entries.length + 1;
    if (view['status'] != 'ok') {
      final error = view['error'];
      final code = error is Map ? error['code'] as String? : null;
      entries.add(
        LedgerEntry(
          ordinal: ordinal,
          kind: 'error',
          errorCode: code,
          requestText: message.content,
        ),
      );
      continue;
    }
    final plant = view['candidate_plant'];
    final crop = view['crop'];
    final area = view['area_m2'];
    if (plant is! String || crop is! String || area is! num) {
      entries.add(
        LedgerEntry(ordinal: ordinal, kind: 'unresolved', requestText: message.content),
      );
      continue;
    }
    entries.add(
      LedgerEntry(
        ordinal: ordinal,
        kind: 'ok',
        candidatePlant: plant,
        crop: crop,
        areaM2: area.toDouble(),
      ),
    );
  }
  final seen = <String, LedgerEntry>{};
  for (final entry in entries) {
    if (entry.kind != 'ok') continue;
    final key = '${entry.candidatePlant}\u0000${entry.crop}';
    final earlier = seen[key];
    if (earlier != null && earlier.areaM2 != entry.areaM2) {
      earlier.supersededBy = entry.ordinal;
    }
    seen[key] = entry;
  }
  return Ledger(entries, notes);
}

String renderEntry(LedgerEntry entry) {
  if (entry.kind == 'ok') {
    var line =
        '${entry.ordinal}. ${entry.candidatePlant} for ${entry.crop}, ${formatG(entry.areaM2!)} m2';
    if (entry.supersededBy != null) {
      line += ' (replaced by request ${entry.supersededBy})';
    }
    return line;
  }
  final text = entry.requestText ?? '(request text unavailable)';
  final detail =
      entry.kind == 'error' && entry.errorCode != null ? ' error=${entry.errorCode}' : '';
  final label = entry.kind == 'error' ? 'no recipe' : 'result not readable';
  return '${entry.ordinal}. $text -> $label$detail';
}

String renderLedgerText(Ledger ledger) {
  final lines = <String>[ledgerHeader, ...ledger.entries.map(renderEntry)];
  if (ledger.notes.isNotEmpty) {
    lines.add(ledgerNotesHeader);
    for (final note in ledger.notes) {
      lines.add('- after request ${note.afterOrdinal}: ${note.text}');
    }
  }
  return lines.join('\n');
}

/// Two history messages (ledger text, short acknowledgement); none for an empty ledger.
List<cactus.ChatMessage> renderLedgerMessages(Ledger ledger) {
  if (ledger.entries.isEmpty && ledger.notes.isEmpty) return const [];
  return [
    cactus.ChatMessage(content: renderLedgerText(ledger), role: 'user'),
    cactus.ChatMessage(content: ledgerAck, role: 'assistant'),
  ];
}
