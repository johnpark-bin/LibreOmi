import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:libreomi/audio/wav.dart';
import 'package:libreomi/core/clock.dart';
import 'package:libreomi/core/ids.dart';
import 'package:libreomi/data/conversation_repo.dart';
import 'package:libreomi/core/models.dart';
import 'package:libreomi/session/conversation_finalizer.dart';
import 'package:libreomi/session/sdcard_import.dart';
import 'package:libreomi/transcription/transcriber.dart';

import '../data/test_db.dart';

class _FixedIdGenerator implements IdGenerator {
  _FixedIdGenerator(this.id);
  final String id;

  @override
  String newId() => id;
}

/// Returns a canned segment list and records the WAV it was handed, so a
/// test can assert on what the importer actually produced from the `.bin`.
class _FakeFileTranscriber implements FileTranscriber {
  _FakeFileTranscriber(this.segments);

  final List<TranscriptSegment> segments;
  WavData? receivedWav;
  String? receivedPath;
  bool wavExistedDuringCall = false;

  @override
  Future<List<TranscriptSegment>> transcribe(File wav) async {
    receivedPath = wav.path;
    wavExistedDuringCall = wav.existsSync();
    receivedWav = parseWav(await wav.readAsBytes());
    return segments;
  }
}

class _ThrowingFileTranscriber implements FileTranscriber {
  String? receivedPath;

  @override
  Future<List<TranscriptSegment>> transcribe(File wav) async {
    receivedPath = wav.path;
    throw Exception('transcription backend is down');
  }
}

/// Builds the on-disk layout `SdCardSyncService._saveFramesToFile` writes:
/// `[len int32 LE][frame]` repeated.
Uint8List framed(List<List<int>> frames) {
  final out = BytesBuilder();
  for (final frame in frames) {
    out.add([
      frame.length & 0xFF,
      (frame.length >> 8) & 0xFF,
      (frame.length >> 16) & 0xFF,
      (frame.length >> 24) & 0xFF,
    ]);
    out.add(frame);
  }
  return out.toBytes();
}

TranscriptSegment segment(String text, double start, double end,
        {int speakerId = 0}) =>
    TranscriptSegment(
      text: text,
      speakerId: speakerId,
      startTime: start,
      endTime: end,
    );

void main() {
  useFfiDatabaseFactory();

  late Directory tempDir;
  late Database db;
  late List<Conversation> enqueued;
  late ConversationFinalizer finalizer;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('sdcard_import_test');
    db = await openTestDb();
    enqueued = [];
    finalizer = ConversationFinalizer(
      database: () async => db,
      enqueue: (c) async => enqueued.add(c),
      scheduleReminder: ({required id, required title, required dueDate}) async {},
    );
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  SdCardImporter importerWith(
    FileTranscriber transcriber, {
    FrameDecoder? opusDecoder,
    String id = 'conversation-1',
  }) {
    return SdCardImporter(
      finalizer: finalizer,
      transcriberFactory: () => transcriber,
      temporaryDirectory: () async => tempDir,
      // Concatenating the frames stands in for a real Opus decode: the
      // importer only cares that it gets PCM16 back.
      opusDecoder: opusDecoder ??
          (frames) async {
            final out = BytesBuilder();
            for (final f in frames) {
              out.add(f);
            }
            return out.toBytes();
          },
      ids: _FixedIdGenerator(id),
      clock: FixedClock(DateTime(2026, 1, 1, 12)),
    );
  }

  /// Writes a `.bin` whose name carries [startedAt] the way
  /// `SdCardSyncService` writes it.
  File writeBin(List<List<int>> frames, {DateTime? startedAt}) {
    final seconds = (startedAt ?? DateTime(2026, 9, 1, 9))
            .millisecondsSinceEpoch ~/
        1000;
    final file = File('${tempDir.path}/sdcard_audio_opus_16000_1_$seconds.bin');
    file.writeAsBytesSync(framed(frames));
    return file;
  }

  group('readFramedPackets', () {
    test('splits the length-prefixed records back into frames', () {
      final frames = readFramedPackets(framed([
        [1, 2, 3],
        [4, 5],
      ]));
      expect(frames.map((f) => f.toList()), [
        [1, 2, 3],
        [4, 5],
      ]);
    });

    test('stops at a record the file was cut in the middle of', () {
      // What an interrupted sync leaves behind: a length that claims more
      // bytes than the file holds.
      final bytes = Uint8List.fromList([
        ...framed([
          [7, 7, 7]
        ]),
        99, 0, 0, 0, 1, 2,
      ]);
      expect(readFramedPackets(bytes).map((f) => f.toList()), [
        [7, 7, 7]
      ]);
    });

    test('does not spin on a zero-length record', () {
      expect(readFramedPackets(Uint8List.fromList([0, 0, 0, 0, 1, 2])), isEmpty);
    });
  });

  group('recordingStartFromFileName', () {
    test('reads the unix start out of the synced name', () {
      expect(
        recordingStartFromFileName('/tmp/sdcard_audio_opus_16000_1_1757000000.bin'),
        DateTime.fromMillisecondsSinceEpoch(1757000000 * 1000),
      );
    });

    test('returns null for a name it does not recognize', () {
      expect(recordingStartFromFileName('/tmp/recording.bin'), isNull);
      // A millisecond timestamp would stamp the conversation with a year in
      // the far future; only whole seconds are accepted.
      expect(
        recordingStartFromFileName(
            '/tmp/sdcard_audio_opus_16000_1_1757000000000.bin'),
        isNull,
      );
    });
  });

  group('import', () {
    test('decodes, transcribes and finalizes one recording', () async {
      final startedAt = DateTime(2026, 9, 1, 9);
      final bin = writeBin([
        [1, 2, 3, 4],
        [5, 6, 7, 8],
      ], startedAt: startedAt);

      final transcriber = _FakeFileTranscriber([
        segment('hello there', 0.0, 1.5),
        segment('general kenobi', 2.0, 3.25, speakerId: 1),
      ]);

      final transcript = await importerWith(transcriber).import(bin.path);

      expect(transcript, 'hello there general kenobi');

      // The transcriber saw a 16 kHz mono PCM16 WAV holding exactly the
      // decoded frames.
      expect(transcriber.wavExistedDuringCall, isTrue);
      expect(transcriber.receivedWav!.sampleRate, 16000);
      expect(transcriber.receivedWav!.channels, 1);
      expect(transcriber.receivedWav!.bitsPerSample, 16);
      expect(transcriber.receivedWav!.pcm, [1, 2, 3, 4, 5, 6, 7, 8]);

      // The temporary WAV is cleaned up.
      expect(File(transcriber.receivedPath!).existsSync(), isFalse);

      final saved = await ConversationRepo(db).byId('conversation-1');
      expect(saved, isNotNull);
      expect(saved!.title, sdCardConversationTitle);
      expect(saved.createdAt, startedAt);
      expect(saved.segments.map((s) => s.text),
          ['hello there', 'general kenobi']);
      expect(saved.segments[1].speakerId, 1);

      // Wall clock is re-anchored on when the audio was captured, not on
      // when the decode ran.
      expect(saved.segments.first.startAt, startedAt);
      expect(saved.segments.first.endAt,
          startedAt.add(const Duration(milliseconds: 1500)));
      expect(saved.segments[1].endAt,
          startedAt.add(const Duration(milliseconds: 3250)));

      expect(enqueued.single.id, 'conversation-1');
    });

    test('fails loudly when the recording produced no text', () async {
      // Not an empty return: `pages/sdcard_sync_page.dart` deletes the `.bin`
      // after any non-throwing import, so a quiet empty result would destroy
      // the recording while having saved nothing.
      final bin = writeBin([
        [1, 2]
      ]);
      await expectLater(
        importerWith(_FakeFileTranscriber([segment('   ', 0, 1)]))
            .import(bin.path),
        throwsA(isA<SdCardImportException>()),
      );

      expect(enqueued, isEmpty);
      expect(await ConversationRepo(db).byId('conversation-1'), isNull);
    });

    test('deletes the temporary WAV even when transcription throws', () async {
      final bin = writeBin([
        [1, 2]
      ]);
      final transcriber = _ThrowingFileTranscriber();

      await expectLater(
        importerWith(transcriber).import(bin.path),
        throwsA(isA<Exception>()),
      );
      expect(File(transcriber.receivedPath!).existsSync(), isFalse);
      expect(enqueued, isEmpty);
    });

    test('refuses a codec docs/05 has not verified', () async {
      final file = File('${tempDir.path}/sdcard_audio_pcm8_16000_1_1757000000.bin');
      file.writeAsBytesSync(framed([
        [1, 2, 3]
      ]));

      await expectLater(
        importerWith(_FakeFileTranscriber([])).import(file.path),
        throwsA(isA<SdCardImportException>()),
      );
    });

    test('reports a missing file and an empty one', () async {
      final importer = importerWith(_FakeFileTranscriber([]));
      await expectLater(
        importer.import('${tempDir.path}/does_not_exist.bin'),
        throwsA(isA<SdCardImportException>()),
      );

      final empty = File('${tempDir.path}/sdcard_audio_opus_16000_1_1757000000.bin');
      empty.writeAsBytesSync(<int>[]);
      await expectLater(
        importer.import(empty.path),
        throwsA(isA<SdCardImportException>()),
      );
    });
  });
}
