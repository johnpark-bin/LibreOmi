/// Persistent retry queue for conversation finalization (LO-23).
///
/// Finalizing a conversation (summarizing its transcript through
/// `OpenAIService` and applying the result to storage) can fail for
/// reasons that have nothing to do with the conversation itself: no
/// network, a flaky server, a rate limit. Losing that work would mean the
/// user's conversation never gets a title/summary/memories/tasks. This
/// queue persists each pending finalization in SQLite so it survives an
/// app restart, and retries it with exponential backoff until it succeeds
/// or is permanently held after too many/non-retryable failures.
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'database_service.dart';

/// Backoff for a row that has now failed [attempts] times (1-based).
///
/// `attempts <= 0` is treated as 1 (there is no such thing as a "zeroth"
/// failure delay). The ladder doubles from 30s and caps at 30 minutes; the
/// loop below stops doubling as soon as it would reach the cap so it never
/// shifts by an exponent large enough to overflow.
Duration finalizationRetryDelay(int attempts) {
  final effectiveAttempts = attempts <= 0 ? 1 : attempts;
  const base = Duration(seconds: 30);
  const cap = Duration(minutes: 30);

  // min(2^attempts * 30s, 30min), computed by doubling step by step (rather
  // than shifting by `attempts`) so a huge attempts value can never
  // overflow -- it just saturates at the cap early and stops.
  var delay = base;
  for (var i = 0; i < effectiveAttempts; i++) {
    if (delay >= cap) {
      return cap;
    }
    final doubled = delay * 2;
    delay = doubled >= cap ? cap : doubled;
  }
  return delay > cap ? cap : delay;
}

/// A transient failure the caller already knows is worth retrying (e.g. a
/// timeout it detected itself). Exists so LO-33's `ConversationFinalizer`
/// can hand the queue a typed error instead of a raw exception.
class FinalizationTransientException implements Exception {
  FinalizationTransientException(this.message);

  final String message;

  @override
  String toString() => 'FinalizationTransientException: $message';
}

/// An HTTP failure from the finalization backend, carrying the status code
/// so the queue can decide whether it is worth retrying (429/5xx) or
/// permanent (e.g. 401/400).
class FinalizationHttpException implements Exception {
  FinalizationHttpException(this.statusCode, [this.body]);

  final int statusCode;
  final String? body;

  @override
  String toString() => 'FinalizationHttpException($statusCode): $body';
}

/// Whether [error] is worth another attempt, versus a permanent failure
/// that would just burn through retries on a bug or a bad credential.
bool isRetryableFinalizationFailure(Object error) {
  if (error is FinalizationHttpException) {
    final code = error.statusCode;
    return code == 429 || (code >= 500 && code <= 599);
  }
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException ||
      error is HttpException ||
      error is FinalizationTransientException;
}

/// One row of the `pending_finalizations` table.
class PendingFinalization {
  PendingFinalization({
    required this.id,
    required this.conversationId,
    required this.transcript,
    required this.attempts,
    required this.nextAttemptAt,
    required this.lastError,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String transcript;
  final int attempts;
  final DateTime nextAttemptAt;
  final String? lastError;
  final DateTime createdAt;

  /// A row is held once it has exhausted [FinalizationQueue.maxAttempts];
  /// it will not be picked up by [FinalizationQueue.drainOnce] again.
  bool get isHeld => attempts >= FinalizationQueue.maxAttempts;

  factory PendingFinalization.fromRow(Map<String, Object?> row) {
    return PendingFinalization(
      id: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      transcript: row['transcript'] as String,
      attempts: row['attempts'] as int,
      nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(row['next_attempt_at'] as int),
      lastError: row['last_error'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    );
  }
}

/// Summarizes a transcript (normally `OpenAIService.summarizeConversation`).
typedef ConversationSummarizer = Future<Map<String, dynamic>> Function(String transcript);

/// Applies a successful summarization result to storage.
typedef FinalizationApplier = Future<void> Function(String conversationId, Map<String, dynamic> result);

/// The sentinel `OpenAIService.summarizeConversation` returns when it has
/// swallowed a real error internally.
const String _sentinelTitle = 'Untitled Conversation';

class FinalizationQueue {
  FinalizationQueue({
    required ConversationSummarizer summarizer,
    required FinalizationApplier applier,
    Future<Database> Function()? databaseProvider,
    Stream<Object?>? networkRestored,
    this.pollInterval = const Duration(seconds: 60),
    DateTime Function() now = DateTime.now,
  })  : _summarizer = summarizer,
        _applier = applier,
        _databaseProvider = databaseProvider ?? (() => DatabaseService.database),
        _injectedNetworkRestored = networkRestored,
        _now = now;

  /// Rows that have failed this many times are held rather than retried
  /// further; a manual retry (e.g. from a future settings screen) can reset
  /// them.
  static const int maxAttempts = 10;
  static const String tableName = 'pending_finalizations';

  final ConversationSummarizer _summarizer;
  final FinalizationApplier _applier;
  final Future<Database> Function() _databaseProvider;
  final Stream<Object?>? _injectedNetworkRestored;
  final Duration pollInterval;
  final DateTime Function() _now;

  final _uuid = const Uuid();

  bool _draining = false;
  StreamSubscription<Object?>? _networkSubscription;
  Timer? _pollTimer;

  /// Inserts a pending finalization for [conversationId], unless a
  /// non-held row for that conversation already exists (in which case its
  /// id is returned instead of creating a duplicate). A held row does not
  /// block a fresh enqueue -- it is replaced, since a held row means the
  /// prior attempt gave up and a new one should get a clean slate.
  Future<String> enqueue({
    required String conversationId,
    required String transcript,
  }) async {
    final db = await _databaseProvider();
    final existingRows = await db.query(
      tableName,
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    final existing = existingRows.map(PendingFinalization.fromRow).toList();
    final nonHeld = existing.where((e) => !e.isHeld).toList();
    if (nonHeld.isNotEmpty) {
      return nonHeld.first.id;
    }

    for (final held in existing) {
      await db.delete(tableName, where: 'id = ?', whereArgs: [held.id]);
    }

    final id = _uuid.v4();
    final nowMillis = _now().millisecondsSinceEpoch;
    await db.insert(tableName, {
      'id': id,
      'conversation_id': conversationId,
      'transcript': transcript,
      'attempts': 0,
      'next_attempt_at': nowMillis,
      'last_error': null,
      'created_at': nowMillis,
    });
    return id;
  }

  /// Runs one pass over every due, non-held row, attempting to finalize
  /// each. Returns how many were finalized successfully. Re-entrant calls
  /// (e.g. a connectivity event firing while a poll is already draining)
  /// return 0 immediately rather than running the same rows twice.
  Future<int> drainOnce() async {
    if (_draining) {
      return 0;
    }
    _draining = true;
    try {
      final db = await _databaseProvider();
      final nowMillis = _now().millisecondsSinceEpoch;
      final rows = await db.query(
        tableName,
        where: 'attempts < ? AND next_attempt_at <= ?',
        whereArgs: [maxAttempts, nowMillis],
        orderBy: 'next_attempt_at ASC, created_at ASC',
      );

      var succeeded = 0;
      for (final row in rows) {
        final entry = PendingFinalization.fromRow(row);
        try {
          final result = await _summarizer(entry.transcript);

          // Workaround: OpenAIService.summarizeConversation swallows every
          // error internally and returns this fixed sentinel instead of
          // throwing, so a bad API key and a dropped network look
          // identical here. Treat the sentinel as a transient failure so
          // the row is retried rather than silently finalized with junk
          // data. LO-33's ConversationFinalizer will replace this with
          // typed errors from OpenAIService so this heuristic can go away.
          if (_looksLikeSwallowedFailure(result)) {
            throw FinalizationTransientException('summarizer returned the swallowed-error sentinel');
          }

          await _applier(entry.conversationId, result);
          await db.delete(tableName, where: 'id = ?', whereArgs: [entry.id]);
          succeeded++;
        } catch (error) {
          debugPrint('FinalizationQueue: finalization failed for ${entry.conversationId}: $error');
          await _recordFailure(db, entry, error);
        }
      }
      return succeeded;
    } finally {
      _draining = false;
    }
  }

  Future<void> _recordFailure(Database db, PendingFinalization entry, Object error) async {
    final retryable = isRetryableFinalizationFailure(error);
    final newAttempts = entry.attempts + 1;

    if (!retryable) {
      await db.update(
        tableName,
        {
          'attempts': maxAttempts,
          'last_error': error.toString(),
        },
        where: 'id = ?',
        whereArgs: [entry.id],
      );
      return;
    }

    if (newAttempts >= maxAttempts) {
      await db.update(
        tableName,
        {
          'attempts': maxAttempts,
          'last_error': error.toString(),
        },
        where: 'id = ?',
        whereArgs: [entry.id],
      );
      return;
    }

    final nextAttemptAt = _now().add(finalizationRetryDelay(newAttempts));
    await db.update(
      tableName,
      {
        'attempts': newAttempts,
        'next_attempt_at': nextAttemptAt.millisecondsSinceEpoch,
        'last_error': error.toString(),
      },
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }

  bool _looksLikeSwallowedFailure(Map<String, dynamic> result) {
    final title = result['title'];
    final summary = result['summary'];
    final memories = result['memories'];
    final tasks = result['tasks'];
    return title == _sentinelTitle &&
        (summary == null || (summary is String && summary.isEmpty)) &&
        (memories == null || (memories is List && memories.isEmpty)) &&
        (tasks == null || (tasks is List && tasks.isEmpty));
  }

  /// Starts background draining: an immediate poll timer (Doze can delay
  /// how promptly this fires; the LO-20 foreground service is what
  /// normally keeps it ticking on a phone that is otherwise idle) plus a
  /// connectivity-restored trigger as a second, faster path for the common
  /// "the network just came back" case. Idempotent -- calling it twice
  /// while already running is a no-op.
  void start() {
    if (_networkSubscription != null || _pollTimer != null) {
      return;
    }

    final restored = _injectedNetworkRestored ?? _defaultNetworkRestored();
    _networkSubscription = restored.listen(
      (_) {
        unawaited(drainOnce().catchError((Object error) {
          debugPrint('FinalizationQueue: connectivity-triggered drain failed: $error');
          return 0;
        }));
      },
      // A platform channel that is missing (a plain `flutter test`) or an OEM
      // that rejects the network callback must not take the process down. The
      // poll timer is still a working trigger without this stream.
      onError: (Object error) {
        debugPrint('FinalizationQueue: connectivity stream error: $error');
      },
      cancelOnError: false,
    );

    _pollTimer = Timer.periodic(pollInterval, (_) {
      unawaited(drainOnce().catchError((Object error) {
        debugPrint('FinalizationQueue: periodic drain failed: $error');
        return 0;
      }));
    });
  }

  /// `connectivity_plus` is only touched here, lazily -- a unit test that
  /// injects its own [networkRestored] stream never calls this, so it
  /// never reaches the plugin's method channel (unavailable in a plain
  /// `flutter test`).
  Stream<Object?> _defaultNetworkRestored() {
    return Connectivity().onConnectivityChanged.where(
          (results) => results.any((r) => r != ConnectivityResult.none),
        );
  }

  /// Stops draining. Safe to call when never started, and safe to call
  /// more than once.
  Future<void> stop() async {
    await _networkSubscription?.cancel();
    _networkSubscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// All pending rows (held and not), most recently created last.
  Future<List<PendingFinalization>> entries() async {
    final db = await _databaseProvider();
    final rows = await db.query(tableName, orderBy: 'created_at ASC');
    return rows.map(PendingFinalization.fromRow).toList();
  }

  /// The pending row for [conversationId], if any.
  Future<PendingFinalization?> entryFor(String conversationId) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      tableName,
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    if (rows.isEmpty) return null;
    return PendingFinalization.fromRow(rows.first);
  }
}
