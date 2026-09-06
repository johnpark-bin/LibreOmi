import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/isolate_channel.dart';

const _timeout = Timeout(Duration(seconds: 30));

/// Echoes back whatever payload it is sent, on both requests and
/// notifications. Notifications are recorded so a following request can
/// observe them.
void _echoWorker(IsolateBootstrap bootstrap) {
  final received = <Object?>[];
  IsolateWorker.serve(bootstrap, (worker) {
    return (Object? payload) {
      if (payload == '__last_notification__') {
        return received.isEmpty ? null : received.last;
      }
      received.add(payload);
      return payload;
    };
  });
}

/// Emits an event before answering each request, so ordering between events
/// and responses can be observed.
void _emitThenRespondWorker(IsolateBootstrap bootstrap) {
  IsolateWorker.serve(bootstrap, (worker) {
    return (Object? payload) {
      worker.emit('event-for-$payload');
      return 'response-for-$payload';
    };
  });
}

/// Throws for any payload equal to 'boom', otherwise echoes.
void _throwingWorker(IsolateBootstrap bootstrap) {
  IsolateWorker.serve(bootstrap, (worker) {
    return (Object? payload) {
      if (payload == 'boom') {
        throw StateError('boom happened');
      }
      return payload;
    };
  });
}

/// Kills its own isolate the instant it receives a payload equal to 'kill',
/// without ever sending back a response.
void _selfKillWorker(IsolateBootstrap bootstrap) {
  IsolateWorker.serve(bootstrap, (worker) {
    return (Object? payload) {
      if (payload == 'kill') {
        Isolate.current.kill(priority: Isolate.immediate);
      }
      return payload;
    };
  });
}

void main() {
  group('IsolateChannel', () {
    test('request/response round trip', () async {
      final channel = await IsolateChannel.spawn(_echoWorker);
      addTearDown(channel.close);

      final result = await channel.request('hello');
      expect(result, 'hello');
    }, timeout: _timeout);

    test('notification reaches the worker, observable via a following request',
        () async {
      final channel = await IsolateChannel.spawn(_echoWorker);
      addTearDown(channel.close);

      channel.notify('side-effect');
      final last = await channel.request('__last_notification__');
      expect(last, 'side-effect');
    }, timeout: _timeout);

    test(
        'worker emit arrives on events in order, before its own response future',
        () async {
      final channel = await IsolateChannel.spawn(_emitThenRespondWorker);
      addTearDown(channel.close);

      final events = <Object?>[];
      final sub = channel.events.listen(events.add);
      addTearDown(sub.cancel);

      final orderMarks = <String>[];
      final future = channel.request('a').then((result) {
        orderMarks.add('response:$result');
      });
      // The event for this request must be observed before the response
      // future completes.
      final eventSeen = Completer<void>();
      late StreamSubscription<Object?> orderSub;
      orderSub = channel.events.listen((event) {
        orderMarks.add('event:$event');
        if (!eventSeen.isCompleted) eventSeen.complete();
      });
      addTearDown(orderSub.cancel);

      await future;
      await eventSeen.future;

      expect(events, ['event-for-a']);
      expect(orderMarks.first, 'event:event-for-a');
      expect(orderMarks.last, 'response:response-for-a');
    }, timeout: _timeout);

    test('a handler that throws on a request surfaces IsolateChannelException '
        'and leaves the channel usable', () async {
      final channel = await IsolateChannel.spawn(_throwingWorker);
      addTearDown(channel.close);

      await expectLater(
        channel.request('boom'),
        throwsA(isA<IsolateChannelException>()),
      );

      // Channel must still work afterwards.
      final result = await channel.request('still fine');
      expect(result, 'still fine');
    }, timeout: _timeout);

    test('a handler that throws on a notification emits IsolateWorkerError '
        'on events', () async {
      final channel = await IsolateChannel.spawn(_throwingWorker);
      addTearDown(channel.close);

      final events = channel.events;
      final firstError = events.firstWhere((e) => e is IsolateWorkerError);

      channel.notify('boom');

      final error = await firstError as IsolateWorkerError;
      expect(error.message, contains('boom happened'));
    }, timeout: _timeout);

    test('close completes and isClosed becomes true; request after close '
        'throws StateError; notify after close is a silent no-op', () async {
      final channel = await IsolateChannel.spawn(_echoWorker);

      expect(channel.isClosed, isFalse);
      await channel.close();
      expect(channel.isClosed, isTrue);

      await expectLater(
        channel.request('anything'),
        throwsA(isA<StateError>()),
      );

      // Must not throw.
      channel.notify('anything');
    }, timeout: _timeout);

    test('worker death while a request is in flight fails the pending '
        'request with StateError, surfaces a stream error on events, closes '
        'the channel, and leaves close() safe to call afterwards', () async {
      final channel = await IsolateChannel.spawn(_selfKillWorker);

      final eventsError = Completer<Object>();
      final sub = channel.events.listen(
        (_) {},
        onError: (Object error) {
          if (!eventsError.isCompleted) eventsError.complete(error);
        },
      );
      addTearDown(sub.cancel);

      await expectLater(
        channel.request('kill'),
        throwsA(isA<StateError>()),
      );

      final error = await eventsError.future;
      expect(error, isA<IsolateChannelException>());
      expect(channel.isClosed, isTrue);

      // Safe to call again after the worker is already gone.
      await channel.close();
    }, timeout: _timeout);
  });
}
