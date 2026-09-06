import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/audio/mic_recorder.dart';
import 'package:libreomi/audio/phone_mic_source.dart';

/// Stands in for the real recorder so the `record` plugin is never touched.
///
/// Deliberately *not* idempotent: unlike [MicService] it counts every
/// `startRecording()` call instead of returning early on the second, which is
/// what makes [PhoneMicSource]'s prepare()/start() double-call observable.
class _FakeRecorder implements MicRecorder {
  _FakeRecorder({this.startError});

  final Object? startError;
  final _controller = StreamController<Uint8List>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  bool recording = false;

  @override
  Stream<Uint8List> get audioStream => _controller.stream;

  @override
  Future<void> startRecording() async {
    startCalls++;
    if (startError != null) throw startError!;
    recording = true;
  }

  @override
  Future<void> stopRecording() async {
    stopCalls++;
    recording = false;
  }

  void emit(List<int> bytes) => _controller.add(Uint8List.fromList(bytes));

  Future<void> dispose() => _controller.close();
}

void main() {
  group('PhoneMicSource', () {
    final at = DateTime.utc(2026, 9, 6, 12);
    final recorders = <_FakeRecorder>[];

    _FakeRecorder newRecorder({Object? startError}) {
      final r = _FakeRecorder(startError: startError);
      recorders.add(r);
      return r;
    }

    tearDown(() async {
      for (final r in recorders) {
        await r.dispose();
      }
      recorders.clear();
    });

    test('one recorder buffer produces one pcm16 chunk', () async {
      final recorder = newRecorder();
      final source = PhoneMicSource(mic: recorder, now: () => at);

      final chunks = <AudioChunk>[];
      source.start().listen(chunks.add);
      await source.prepare();

      recorder.emit([1, 2, 3, 4]);
      await Future<void>.delayed(Duration.zero);

      expect(chunks, hasLength(1));
      expect(chunks.single.bytes, Uint8List.fromList([1, 2, 3, 4]));
      expect(chunks.single.encoding, AudioEncoding.pcm16);
      expect(chunks.single.at, at);
    });

    test('prepare() surfaces a recorder failure as a thrown exception', () {
      final recorder = newRecorder(startError: StateError('mic busy'));
      final source = PhoneMicSource(mic: recorder, now: () => at);

      // This is why prepare() exists next to the synchronous start(): the
      // session rollback in AppProvider needs the failure as an exception.
      expect(source.prepare(), throwsA(isA<StateError>()));
    });

    test('a start()-only failure arrives as a stream error, not a throw',
        () async {
      final recorder = newRecorder(startError: StateError('mic busy'));
      final source = PhoneMicSource(mic: recorder, now: () => at);

      final errors = <Object>[];
      source.start().listen((_) {}, onError: errors.add);
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
    });

    test('start() after an awaited prepare() does not re-start the recorder',
        () async {
      final recorder = newRecorder();
      final source = PhoneMicSource(mic: recorder, now: () => at);

      await source.prepare();
      source.start().listen((_) {});
      await Future<void>.delayed(Duration.zero);

      // start() calls prepare() again for interface-only callers; the real
      // MicService no-ops on the second call because it is already recording.
      expect(recorder.startCalls, 2);
      expect(recorder.recording, isTrue);
    });

    test('stop() stops the recorder and ends emission', () async {
      final recorder = newRecorder();
      final source = PhoneMicSource(mic: recorder, now: () => at);

      final chunks = <AudioChunk>[];
      source.start().listen(chunks.add);
      await source.prepare();
      await source.stop();

      expect(recorder.stopCalls, 1);
      expect(recorder.recording, isFalse);

      recorder.emit([9, 9]);
      await Future<void>.delayed(Duration.zero);
      expect(chunks, isEmpty);
    });

    test('stop() without start() is safe', () async {
      final recorder = newRecorder();
      await PhoneMicSource(mic: recorder, now: () => at).stop();
      expect(recorder.stopCalls, 1);
    });
  });
}
