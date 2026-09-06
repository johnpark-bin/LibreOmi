/// A minimal request/response + event channel over [Isolate.spawn].
///
/// The transcription workers (LO-41, and LO-42 later) all need the same three
/// things from an isolate: call it and wait for an answer, push audio at it
/// without waiting, and receive results it produces on its own schedule.
/// [IsolateChannel] is the main-isolate half of that, [IsolateWorker] the
/// worker half. Nothing here knows about audio or sherpa-onnx.
///
/// Per `docs/03-architecture.md` §1 this file lives in `transcription/` and
/// imports no Flutter widgets and no platform plugin: everything it hands to
/// the worker crosses an isolate boundary, where plugin channels are not
/// available.
library;

import 'dart:async';
import 'dart:isolate';

/// What a worker entry point receives as its single [Isolate.spawn] argument.
class IsolateBootstrap {
  const IsolateBootstrap(this.toMain, this.payload);

  /// Port back to the [IsolateChannel] that spawned this worker.
  final SendPort toMain;

  /// Caller-supplied startup value, copied into the worker isolate.
  final Object? payload;
}

/// Frame sent main -> worker when an answer is expected.
class _Request {
  const _Request(this.id, this.payload);
  final int id;
  final Object? payload;
}

/// Frame sent main -> worker when no answer is expected.
class _Notification {
  const _Notification(this.payload);
  final Object? payload;
}

/// Frame sent main -> worker to end the serve loop.
class _Shutdown {
  const _Shutdown();
}

/// Frame sent worker -> main in reply to a [_Request].
class _Response {
  const _Response(this.id, this.result, this.error, this.stackTrace);
  final int id;
  final Object? result;

  /// Stringified: arbitrary error objects are not guaranteed to be sendable.
  final String? error;
  final String? stackTrace;
}

/// Frame sent worker -> main outside of any request.
class _Event {
  const _Event(this.payload);
  final Object? payload;
}

/// The main-isolate half of the channel.
///
/// Message order is preserved in both directions, so an event the worker
/// emits before answering a request reaches [events] before that request's
/// future completes.
class IsolateChannel {
  IsolateChannel._(this._fromWorker, this._exitPort, this._errorPort);

  final ReceivePort _fromWorker;
  final ReceivePort _exitPort;
  final ReceivePort _errorPort;

  Isolate? _isolate;
  late final SendPort _toWorker;

  final Completer<SendPort> _ready = Completer<SendPort>();
  final Completer<void> _exited = Completer<void>();
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast(sync: true);
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  int _nextId = 0;
  bool _closing = false;
  bool _closed = false;

  /// Events the worker pushed on its own. A worker death that nobody asked
  /// for arrives here as a stream error.
  Stream<Object?> get events => _events.stream;

  /// True once the channel is torn down, by [close] or by the worker dying.
  bool get isClosed => _closed;

  /// Spawns [entryPoint] and completes once the worker has handed back its
  /// own port. [bootstrap] is copied into the worker as
  /// [IsolateBootstrap.payload].
  static Future<IsolateChannel> spawn(
    void Function(IsolateBootstrap) entryPoint, {
    Object? bootstrap,
    String? debugName,
  }) async {
    final channel =
        IsolateChannel._(ReceivePort(), ReceivePort(), ReceivePort());
    channel._fromWorker.listen(
      channel._onWorkerMessage,
      onDone: () => channel._onWorkerGone('worker closed its port'),
    );
    channel._exitPort.listen(
      (_) => channel._onWorkerGone('worker isolate exited'),
    );
    channel._errorPort.listen((message) {
      final detail = message is List && message.isNotEmpty
          ? '${message.first}'
          : '$message';
      channel._onWorkerGone('worker isolate error: $detail');
    });

    try {
      channel._isolate = await Isolate.spawn(
        entryPoint,
        IsolateBootstrap(channel._fromWorker.sendPort, bootstrap),
        onExit: channel._exitPort.sendPort,
        onError: channel._errorPort.sendPort,
        errorsAreFatal: true,
        debugName: debugName,
      );
    } catch (_) {
      // Closing the ports fires `onDone` on the worker port, which runs
      // teardown; nobody is left to observe the failed handshake.
      channel._ready.future.ignore();
      channel._closePorts();
      rethrow;
    }

    channel._toWorker = await channel._ready.future;
    return channel;
  }

  /// Sends [payload] and waits for the worker's answer. Throws
  /// [IsolateChannelException] if the worker's handler threw, or [StateError]
  /// if the channel is closed or dies while the request is in flight.
  Future<Object?> request(Object? payload) {
    if (_closed) {
      return Future<Object?>.error(StateError('IsolateChannel is closed'));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _toWorker.send(_Request(id, payload));
    return completer.future;
  }

  /// Sends [payload] without waiting for anything back. A no-op once closed,
  /// so a late audio chunk cannot throw at the caller.
  void notify(Object? payload) {
    if (_closed) return;
    _toWorker.send(_Notification(payload));
  }

  /// Asks the worker to end its serve loop, waits up to [timeout] for it to
  /// exit, then tears the isolate down. Pending requests complete with a
  /// [StateError]. Safe to call more than once.
  Future<void> close({Duration timeout = const Duration(seconds: 2)}) async {
    if (_closed) return;
    _closing = true;
    _toWorker.send(const _Shutdown());
    await _exited.future.timeout(timeout, onTimeout: () {});
    _teardown('IsolateChannel was closed');
  }

  void _onWorkerMessage(Object? message) {
    if (!_ready.isCompleted) {
      // The worker's first message is always its own SendPort.
      _ready.complete(message as SendPort);
      return;
    }
    if (message is _Response) {
      final completer = _pending.remove(message.id);
      if (completer == null || completer.isCompleted) return;
      if (message.error != null) {
        completer.completeError(
          IsolateChannelException(message.error!, message.stackTrace),
        );
      } else {
        completer.complete(message.result);
      }
      return;
    }
    if (message is _Event) {
      if (!_events.isClosed) _events.add(message.payload);
      return;
    }
    if (!_events.isClosed) {
      _events.addError(
        IsolateChannelException('unexpected frame from worker: $message', null),
      );
    }
  }

  void _onWorkerGone(String reason) {
    if (!_exited.isCompleted) _exited.complete();
    if (_closed) return;
    if (!_closing && !_events.isClosed) {
      _events.addError(IsolateChannelException(reason, null));
    }
    if (!_ready.isCompleted) {
      _ready.completeError(IsolateChannelException(reason, null));
    }
    _teardown(reason);
  }

  void _teardown(String reason) {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(StateError(reason));
    }
    _pending.clear();
    _closePorts();
    // `beforeNextEvent` lets the worker finish the message it is on, which is
    // how `IsolateWorker.serve`'s `finally` — and so a recognizer's `free()` —
    // still runs after a clean shutdown. A worker wedged in native code is
    // killed without that cleanup; callers free their native handles from a
    // command handler rather than relying on this path.
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    if (!_events.isClosed) _events.close();
  }

  void _closePorts() {
    _fromWorker.close();
    _exitPort.close();
    _errorPort.close();
  }
}

/// Raised in the main isolate for an error that happened in the worker. The
/// worker's stack trace, when there is one, comes along as text.
class IsolateChannelException implements Exception {
  const IsolateChannelException(this.message, this.workerStackTrace);

  final String message;
  final String? workerStackTrace;

  @override
  String toString() => 'IsolateChannelException: $message';
}

/// Handles one request or notification. Returning a value answers a request;
/// throwing sends the error back to the caller's [IsolateChannel.request]
/// future, or — for a notification, which nobody awaits — emits an
/// [IsolateWorkerError] event.
typedef IsolateRequestHandler = FutureOr<Object?> Function(Object? request);

/// The worker-isolate half of the channel.
///
/// A worker entry point is a top-level (or static) function taking an
/// [IsolateBootstrap]; it calls [IsolateWorker.serve] and returns when the
/// main isolate closes the channel.
class IsolateWorker {
  IsolateWorker._(this._toMain);

  final SendPort _toMain;

  /// Runs the serve loop until the main isolate asks for shutdown.
  ///
  /// [build] receives the worker so a handler can [emit] while serving; it
  /// runs before any request is handled. [onShutdown] runs once the loop
  /// ends — use it to free native resources.
  static Future<void> serve(
    IsolateBootstrap bootstrap,
    IsolateRequestHandler Function(IsolateWorker worker) build, {
    void Function()? onShutdown,
  }) async {
    final fromMain = ReceivePort();
    final worker = IsolateWorker._(bootstrap.toMain);
    bootstrap.toMain.send(fromMain.sendPort);

    final handler = build(worker);
    try {
      // Requests are handled one at a time and in arrival order: a sherpa
      // recognizer is a single native stream and must not be re-entered.
      await for (final message in fromMain) {
        if (message is _Shutdown) break;
        if (message is _Notification) {
          await worker._runNotification(handler, message.payload);
        } else if (message is _Request) {
          await worker._runRequest(handler, message);
        }
      }
    } finally {
      onShutdown?.call();
      fromMain.close();
    }
  }

  /// Pushes an unsolicited event to [IsolateChannel.events].
  void emit(Object? payload) => _toMain.send(_Event(payload));

  Future<void> _runRequest(
      IsolateRequestHandler handler, _Request request) async {
    try {
      final result = await handler(request.payload);
      _toMain.send(_Response(request.id, result, null, null));
    } catch (e, st) {
      _toMain.send(_Response(request.id, null, '$e', '$st'));
    }
  }

  Future<void> _runNotification(
      IsolateRequestHandler handler, Object? payload) async {
    try {
      await handler(payload);
    } catch (e, st) {
      // Nobody is waiting on a notification, so an error can only be
      // reported out of band.
      emit(IsolateWorkerError('$e', '$st'));
    }
  }
}

/// Emitted on [IsolateChannel.events] when a notification's handler threw.
class IsolateWorkerError {
  const IsolateWorkerError(this.message, this.stackTrace);
  final String message;
  final String stackTrace;

  @override
  String toString() => 'IsolateWorkerError: $message';
}
