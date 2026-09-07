import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/core/models.dart';

void main() {
  group('TranscriptSegment JSON round-trip', () {
    test('round-trips with wall-clock values present', () {
      final startAt = DateTime.fromMillisecondsSinceEpoch(1000);
      final endAt = DateTime.fromMillisecondsSinceEpoch(5000);
      final segment = TranscriptSegment(
        text: 'hello',
        speakerId: 1,
        startTime: 0.0,
        endTime: 4.0,
        isUser: true,
        startAt: startAt,
        endAt: endAt,
      );

      final json = segment.toJson();
      expect(json['start_at'], 1000);
      expect(json['end_at'], 5000);

      final restored = TranscriptSegment.fromJson(json);
      expect(restored.text, 'hello');
      expect(restored.speakerId, 1);
      expect(restored.startTime, 0.0);
      expect(restored.endTime, 4.0);
      expect(restored.isUser, true);
      expect(restored.startAt, startAt);
      expect(restored.endAt, endAt);
    });

    test('round-trips with wall-clock values absent', () {
      final segment = TranscriptSegment(
        text: 'hi',
        speakerId: 0,
        startTime: 1.0,
        endTime: 2.0,
      );

      final json = segment.toJson();
      expect(json.containsKey('start_at'), isFalse);
      expect(json.containsKey('end_at'), isFalse);

      final restored = TranscriptSegment.fromJson(json);
      expect(restored.startAt, isNull);
      expect(restored.endAt, isNull);
    });

    test('fromJson tolerates explicit null values', () {
      final json = {
        'text': 'x',
        'speaker_id': 0,
        'start': 0.0,
        'end': 1.0,
        'is_user': false,
        'start_at': null,
        'end_at': null,
      };

      final segment = TranscriptSegment.fromJson(json);
      expect(segment.startAt, isNull);
      expect(segment.endAt, isNull);
    });

    test('fromJson tolerates a legacy payload with no wall-clock keys', () {
      final json = {
        'text': 'legacy',
        'speaker_id': 2,
        'start': 3.0,
        'end': 4.0,
        'is_user': false,
      };

      final segment = TranscriptSegment.fromJson(json);
      expect(segment.text, 'legacy');
      expect(segment.startAt, isNull);
      expect(segment.endAt, isNull);
    });
  });

  group('Conversation.duration', () {
    test('returns Duration.zero for an empty segment list', () {
      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime.now(),
        segments: const [],
      );
      expect(conversation.duration, Duration.zero);
    });

    test('uses wall clock when both first startAt and last endAt are present', () {
      final startAt = DateTime.fromMillisecondsSinceEpoch(0);
      final midAt = DateTime.fromMillisecondsSinceEpoch(2000);
      final endAt = DateTime.fromMillisecondsSinceEpoch(10000);

      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime.now(),
        segments: [
          TranscriptSegment(
            text: 'a',
            speakerId: 0,
            startTime: 0.0,
            endTime: 100.0, // deliberately wrong relative time to prove wall clock wins
            startAt: startAt,
            endAt: midAt,
          ),
          TranscriptSegment(
            text: 'b',
            speakerId: 0,
            startTime: 100.0,
            endTime: 200.0,
            startAt: midAt,
            endAt: endAt,
          ),
        ],
      );

      expect(conversation.duration, const Duration(seconds: 10));
    });

    test('falls back to relative seconds when first segment startAt is missing', () {
      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime.now(),
        segments: [
          TranscriptSegment(
            text: 'a',
            speakerId: 0,
            startTime: 0.0,
            endTime: 5.0,
          ),
          TranscriptSegment(
            text: 'b',
            speakerId: 0,
            startTime: 5.0,
            endTime: 10.0,
            endAt: DateTime.fromMillisecondsSinceEpoch(10000),
          ),
        ],
      );

      expect(conversation.duration, const Duration(seconds: 10));
    });

    test('falls back to relative seconds when last segment endAt is missing', () {
      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime.now(),
        segments: [
          TranscriptSegment(
            text: 'a',
            speakerId: 0,
            startTime: 0.0,
            endTime: 5.0,
            startAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
          TranscriptSegment(
            text: 'b',
            speakerId: 0,
            startTime: 5.0,
            endTime: 10.0,
          ),
        ],
      );

      expect(conversation.duration, const Duration(seconds: 10));
    });

    test('clamps a negative wall-clock duration to zero', () {
      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime.now(),
        segments: [
          TranscriptSegment(
            text: 'a',
            speakerId: 0,
            startTime: 0.0,
            endTime: 5.0,
            startAt: DateTime.fromMillisecondsSinceEpoch(10000),
          ),
          TranscriptSegment(
            text: 'b',
            speakerId: 0,
            startTime: 5.0,
            endTime: 10.0,
            endAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        ],
      );

      expect(conversation.duration, Duration.zero);
    });

    test('formattedDuration formats a wall-clock-derived duration', () {
      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime.now(),
        segments: [
          TranscriptSegment(
            text: 'a',
            speakerId: 0,
            startTime: 0.0,
            endTime: 0.0,
            startAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
          TranscriptSegment(
            text: 'b',
            speakerId: 0,
            startTime: 0.0,
            endTime: 0.0,
            endAt: DateTime.fromMillisecondsSinceEpoch((5 * 60 + 23) * 1000),
          ),
        ],
      );

      expect(conversation.formattedDuration, '5m 23s');
    });
  });
}
