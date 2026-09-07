import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/data/conversation_repo.dart';
import 'package:libreomi/core/models.dart';

import 'test_db.dart';

void main() {
  useFfiDatabaseFactory();

  Conversation makeConversation({
    required String id,
    required DateTime createdAt,
    String title = 'Title',
    String summary = 'Summary',
    List<TranscriptSegment> segments = const [],
  }) {
    return Conversation(
      id: id,
      createdAt: createdAt,
      title: title,
      summary: summary,
      segments: segments,
    );
  }

  group('ConversationRepo.save/all/byId', () {
    test('round trips a conversation including transcript JSON', () async {
      final db = await openTestDb();
      final repo = ConversationRepo(db);

      final segments = [
        TranscriptSegment(
          text: 'hello',
          speakerId: 0,
          startTime: 0,
          endTime: 1,
          isUser: true,
        ),
        TranscriptSegment(
          text: 'world',
          speakerId: 1,
          startTime: 1,
          endTime: 2,
        ),
      ];
      final conversation = makeConversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        segments: segments,
      );

      await repo.save(conversation);
      final read = await repo.byId('c1');

      expect(read, isNotNull);
      expect(read!.id, 'c1');
      expect(read.title, 'Title');
      expect(read.summary, 'Summary');
      expect(read.segments, hasLength(2));
      expect(read.segments[0].text, 'hello');
      expect(read.segments[0].isUser, isTrue);
      expect(read.segments[1].text, 'world');
      expect(read.segments[1].isUser, isFalse);
    });

    test('byId returns null when missing', () async {
      final db = await openTestDb();
      final repo = ConversationRepo(db);
      expect(await repo.byId('missing'), isNull);
    });

    test('all orders by created_at DESC and respects limit', () async {
      final db = await openTestDb();
      final repo = ConversationRepo(db);

      await repo.save(makeConversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.save(makeConversation(
        id: 'c2',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
      ));
      await repo.save(makeConversation(
        id: 'c3',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ));

      final all = await repo.all();
      expect(all.map((c) => c.id).toList(), ['c2', 'c3', 'c1']);

      final limited = await repo.all(limit: 2);
      expect(limited.map((c) => c.id).toList(), ['c2', 'c3']);
    });

    test('save replaces an existing row with the same id', () async {
      final db = await openTestDb();
      final repo = ConversationRepo(db);

      await repo.save(makeConversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        title: 'Original',
      ));
      await repo.save(makeConversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        title: 'Updated',
      ));

      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.single.title, 'Updated');
    });

    test('delete removes the row', () async {
      final db = await openTestDb();
      final repo = ConversationRepo(db);

      await repo.save(makeConversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.delete('c1');

      expect(await repo.byId('c1'), isNull);
    });
  });

  group('ConversationRepo.contextText', () {
    test('returns empty string when there are no conversations', () async {
      final db = await openTestDb();
      final repo = ConversationRepo(db);
      expect(await repo.contextText(), '');
    });

    test('formats conversations exactly like the old context string',
        () async {
      final db = await openTestDb();
      final repo = ConversationRepo(db);

      final createdAt = DateTime.fromMillisecondsSinceEpoch(1000);
      final conversation = makeConversation(
        id: 'c1',
        createdAt: createdAt,
        title: 'My Title',
        summary: 'My Summary',
        segments: [
          TranscriptSegment(
            text: 'hi',
            speakerId: 0,
            startTime: 0,
            endTime: 1,
          ),
        ],
      );
      await repo.save(conversation);

      final expected = '''
--- Conversation from ${createdAt.toLocal()} ---
Title: My Title
Summary: My Summary
Transcript:
${conversation.transcript}
''';

      expect(await repo.contextText(), expected);
      // The interpolation above would still pass if the transcript format
      // changed under it, and this string is what goes to the LLM verbatim.
      expect(await repo.contextText(), contains('Speaker 0: hi'));
    });
  });
}
