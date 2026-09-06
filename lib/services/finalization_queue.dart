/// Persistent retry queue for conversation finalization (LO-23).
///
/// Finalizing a conversation (summarizing its transcript through an
/// [LlmClient] and applying the result to storage) can fail for reasons
/// that have nothing to do with the conversation itself: no network, a
/// flaky server, a rate limit. Losing that work would mean the user's
/// conversation never gets a title/summary/memories/tasks. This queue
/// persists each pending finalization in SQLite (via [FinalizationRepo]) so
/// it survives an app restart, and retries it with exponential backoff
/// until it succeeds or is permanently held after too many/non-retryable
/// failures.
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/finalization_repo.dart';
import '../intelligence/llm_client.dart';
import 'database_service.dart';

export '../data/finalization_repo.dart' show PendingFinalizationRow;

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
/// timeout it detected itself). This is the queue's own vocabulary for a
/// caller that finalizes without an [LlmClient] in the loop (so it cannot
/// throw [LlmRetryableException] itself) and still needs to say "retry
/// this".
///
/// Nothing in `lib/` throws it today — since LO-33 the summarisation path
/// raises [LlmRetryableException] instead. It is kept because the applier
/// the queue is handed is caller code, which has no LLM to translate its
/// failures for it. Delete it if the applier contract ever stops being
/// injectable.
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
  if (error is LlmException) {
    return error is LlmRetryableException;
  }
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException ||
      error is HttpException ||
      error is FinalizationTransientException;
}

/// A row is held once it has exhausted [FinalizationQueue.maxAttempts];
/// [FinalizationQueue.drainOnce] will not pick it up again.
extension PendingFinalizationStatus on PendingFinalizationRow {
  bool get isHeld => attempts >= FinalizationQueue.maxAttempts;
}

/// Applies a successful summarization result to storage.
typedef FinalizationApplier = Future<void> Function(String conversationId, ConversationInsights insights);

class FinalizationQueue {
  FinalizationQueue({
    required LlmClientFactory llmClient,
    required FinalizationApplier applier,
    Future<Database> Function()? databaseProvider,
    Stream<Object?>? networkRestored,
    this.pollInterval = const Duration(seconds: 60),
    DateTime Function() now = DateTime.now,
  })  : _llmClient = llmClient,
        _applier = applier,
        _databaseProvider = databaseProvider ?? (() => DatabaseService.database),
        _injectedNetworkRestored = networkRestored,
        _now = now;

  /// Rows that have failed this many times are held rather than retried
  /// further; a manual retry (e.g. from a future settings screen) can reset
  /// them.
  static const int maxAttempts = 10;
  static const String tableName = 'pending_finalizations';

  final LlmClientFactory _llmClient;
  final FinalizationApplier _applier;
  final Future<Database> Function() _databaseProvider;
  final Stream<Object?>? _injectedNetworkRestored;
  final Duration pollInterval;
  final DateTime Function() _now;

  final _uuid = const Uuid();

  bool _draining = false;
  StreamSubscription<Object?>? _networkSubscription;
  Timer? _pollTimer;

  Future<FinalizationRepo> _repo() async => FinalizationRepo(await _databaseProvider());

  /// Inserts a pending finalization for [conversationId], unless a
  /// non-held row for that conversation already exists (in which case its
  /// id is returned instead of creating a duplicate). A held row does not
  /// block a fresh enqueue -- it is replaced, since a held row means the
  /// prior attempt gave up and a new one should get a clean slate.
  Future<String> enqueue({
    required String conversationId,
    required String transcript,
  }) async {
    final repo = await _repo();
    final existing = await repo.forConversation(conversationId);
    final nonHeld = existing.where((e) => !e.isHeld).toList();
    if (nonHeld.isNotEmpty) {
      return nonHeld.first.id;
    }

    for (final held in existing) {
      await repo.delete(held.id);
    }

    final id = _uuid.v4();
    final nowMillis = _now().millisecondsSinceEpoch;
    await repo.insert(PendingFinalizationRow(
      id: id,
      conversationId: conversationId,
      transcript: transcript,
      attempts: 0,
      nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(nowMillis),
      lastError: null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(nowMillis),
    ));
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
      final repo = await _repo();
      final rows = await repo.due(maxAttempts: maxAttempts, now: _now());

      var succeeded = 0;
      for (final entry in rows) {
        try {
          final insights = await _llmClient().summarize(entry.transcript);
          await _applier(entry.conversationId, insights);
          await repo.delete(entry.id);
          succeeded++;
        } catch (error) {
          debugPrint('FinalizationQueue: finalization failed for ${entry.conversationId}: $error');
          await _recordFailure(repo, entry, error);
        }
      }
      return succeeded;
    } finally {
      _draining = false;
    }
  }

  Future<void> _recordFailure(FinalizationRepo repo, PendingFinalizationRow entry, Object error) async {
    final retryable = isRetryableFinalizationFailure(error);
    final newAttempts = entry.attempts + 1;

    if (!retryable || newAttempts >= maxAttempts) {
      await repo.updateAttempt(
        id: entry.id,
        attempts: maxAttempts,
        lastError: error.toString(),
      );
      return;
    }

    final nextAttemptAt = _now().add(finalizationRetryDelay(newAttempts));
    await repo.updateAttempt(
      id: entry.id,
      attempts: newAttempts,
      nextAttemptAt: nextAttemptAt,
      lastError: error.toString(),
    );
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
  Future<List<PendingFinalizationRow>> entries() async {
    final repo = await _repo();
    return repo.all();
  }

  /// The pending row for [conversationId], if any.
  Future<PendingFinalizationRow?> entryFor(String conversationId) async {
    final repo = await _repo();
    final rows = await repo.forConversation(conversationId);
    if (rows.isEmpty) return null;
    return rows.first;
  }
}
