import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/intelligence/llm_client.dart';

void main() {
  group('ConversationInsights.fromMap', () {
    test('parses a well-formed map', () {
      final insights = ConversationInsights.fromMap({
        'title': 'Grocery run',
        'summary': 'Discussed what to buy.',
        'memories': ['User likes oat milk'],
        'tasks': [
          {'title': 'Buy milk', 'description': 'oat milk', 'due_date': '2026-09-07T18:00:00.000'},
        ],
      });

      expect(insights.title, 'Grocery run');
      expect(insights.summary, 'Discussed what to buy.');
      expect(insights.memories, ['User likes oat milk']);
      expect(insights.tasks, hasLength(1));
      expect(insights.tasks.single.title, 'Buy milk');
      expect(insights.tasks.single.description, 'oat milk');
      expect(insights.tasks.single.dueDate, DateTime.parse('2026-09-07T18:00:00.000'));
    });

    test('falls back to defaults when keys are missing', () {
      final insights = ConversationInsights.fromMap(<String, dynamic>{});

      expect(insights.title, 'Untitled Conversation');
      expect(insights.summary, '');
      expect(insights.memories, isEmpty);
      expect(insights.tasks, isEmpty);
    });

    test('falls back to default title when title is blank', () {
      final insights = ConversationInsights.fromMap({'title': '   '});
      expect(insights.title, 'Untitled Conversation');
    });

    test('skips a task with no title', () {
      final insights = ConversationInsights.fromMap({
        'tasks': [
          {'description': 'no title here'},
          {'title': '', 'description': 'blank title'},
          {'title': 'Valid task'},
        ],
      });

      expect(insights.tasks, hasLength(1));
      expect(insights.tasks.single.title, 'Valid task');
    });

    test('skips a non-map task entry', () {
      final insights = ConversationInsights.fromMap({
        'tasks': ['not a map', 42, null],
      });
      expect(insights.tasks, isEmpty);
    });

    test('an unparseable due_date becomes null instead of throwing', () {
      final insights = ConversationInsights.fromMap({
        'tasks': [
          {'title': 'Task with bad date', 'due_date': 'not-a-date'},
        ],
      });

      expect(insights.tasks.single.dueDate, isNull);
    });

    test('a null due_date stays null', () {
      final insights = ConversationInsights.fromMap({
        'tasks': [
          {'title': 'Task with no date', 'due_date': null},
        ],
      });

      expect(insights.tasks.single.dueDate, isNull);
    });
  });

  group('ConversationInsights.toMap', () {
    test('round-trips through fromMap/toMap', () {
      const insights = ConversationInsights(
        title: 'Standup notes',
        summary: 'Talked about the sprint.',
        memories: ['User prefers async standups'],
        tasks: [
          TaskDraft(title: 'Send recap', description: 'to the team', dueDate: null),
        ],
      );

      final map = insights.toMap();
      expect(map['title'], 'Standup notes');
      expect(map['summary'], 'Talked about the sprint.');
      expect(map['memories'], ['User prefers async standups']);
      expect(map['tasks'], [
        {'title': 'Send recap', 'description': 'to the team', 'due_date': null},
      ]);

      final roundTripped = ConversationInsights.fromMap(map);
      expect(roundTripped.title, insights.title);
      expect(roundTripped.summary, insights.summary);
      expect(roundTripped.memories, insights.memories);
      expect(roundTripped.tasks.single.title, insights.tasks.single.title);
    });

    test('serializes a due date as ISO-8601', () {
      final insights = ConversationInsights(
        title: 'x',
        summary: 'y',
        memories: const [],
        tasks: [TaskDraft(title: 'Task', dueDate: DateTime.utc(2026, 9, 7, 18))],
      );

      final tasks = insights.toMap()['tasks'] as List;
      expect(tasks.single['due_date'], DateTime.utc(2026, 9, 7, 18).toIso8601String());
    });
  });
}
