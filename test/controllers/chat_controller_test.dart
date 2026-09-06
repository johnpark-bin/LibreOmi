import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:libreomi/controllers/chat_controller.dart';
import 'package:libreomi/controllers/library_controller.dart';
import 'package:libreomi/data/chat_repo.dart';
import 'package:libreomi/intelligence/llm_client.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';
import 'package:libreomi/session/recording_session.dart' show AiAnswer;

import '../data/test_db.dart';

/// A fake [LlmClient] whose `chat` response (or failure) is scripted by the
/// test, and which records the prompt it was called with.
class _FakeLlmClient implements LlmClient {
  _FakeLlmClient({this.reply, this.error});

  final String? reply;
  final Object? error;
  String? lastUserMessage;
  String? lastContext;

  @override
  Future<String> chat(String user, {String? context}) async {
    lastUserMessage = user;
    lastContext = context;
    if (error != null) throw error!;
    return reply!;
  }

  @override
  Future<ConversationInsights> summarize(String transcript, {DateTime? now}) {
    throw UnimplementedError();
  }
}

void main() {
  useFfiDatabaseFactory();

  late Database db;
  late LibraryController library;

  setUp(() async {
    db = await openTestDb();
    library = LibraryController(database: () async => db);

    // Boots SettingsService against an in-memory store, the same way
    // test/pages/settings_page_test.dart does, so `hasOpenAIKey` reads a
    // real (fake-backed) setting rather than needing its own seam.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init(secretStore: InMemorySecretStore());
  });

  test('sendChatMessage with a configured key appends the user message then the reply, both persisted', () async {
    SettingsService.openaiApiKey = 'test-key';
    final fake = _FakeLlmClient(reply: 'Hello there');
    final controller = ChatController(
      library: library,
      database: () async => db,
      llmClientFactory: () => fake,
    );

    await controller.sendChatMessage('Hi');

    expect(controller.chatMessages.map((m) => m.text), ['Hi', 'Hello there']);
    expect(controller.chatMessages.map((m) => m.isUser), [true, false]);
    expect(controller.isChatLoading, isFalse);
    expect(fake.lastUserMessage, 'Hi');

    final persisted = await ChatRepo(db).all();
    expect(persisted.map((m) => m.text), ['Hi', 'Hello there']);
  });

  test('a throwing client produces the Error: assistant message, also persisted', () async {
    SettingsService.openaiApiKey = 'test-key';
    final fake = _FakeLlmClient(error: Exception('boom'));
    final controller = ChatController(
      library: library,
      database: () async => db,
      llmClientFactory: () => fake,
    );

    await controller.sendChatMessage('Hi');

    expect(controller.chatMessages.last.text, contains('Error: '));
    expect(controller.chatMessages.last.isUser, isFalse);

    final persisted = await ChatRepo(db).all();
    expect(persisted.last.text, contains('Error: '));
  });

  test('sendChatMessage throws without an OpenAI key before appending anything', () async {
    // openaiApiKey defaults to '' from the fresh in-memory store.
    final controller = ChatController(
      library: library,
      database: () async => db,
      llmClientFactory: () => throw StateError('must not be called'),
    );

    await expectLater(
      () => controller.sendChatMessage('Hi'),
      throwsA(isA<Exception>()),
    );
    expect(controller.chatMessages, isEmpty);
  });

  test('sendChatMessage ignores blank input', () async {
    SettingsService.openaiApiKey = 'test-key';
    final controller = ChatController(
      library: library,
      database: () async => db,
      llmClientFactory: () => throw StateError('must not be called'),
    );

    await controller.sendChatMessage('   ');

    expect(controller.chatMessages, isEmpty);
  });

  test('recordAiAnswer appends and persists the question/answer pair', () async {
    final controller = ChatController(library: library, database: () async => db);

    await controller.recordAiAnswer(
      const AiAnswer(question: 'What is on my plate today?', answer: 'Nothing yet.'),
    );

    expect(controller.chatMessages.map((m) => m.text), [
      'What is on my plate today?',
      'Nothing yet.',
    ]);
    expect(controller.chatMessages.map((m) => m.isUser), [true, false]);

    final persisted = await ChatRepo(db).all();
    expect(persisted.map((m) => m.text), [
      'What is on my plate today?',
      'Nothing yet.',
    ]);
  });

  test('clearChat empties the in-memory list and the table', () async {
    final controller = ChatController(library: library, database: () async => db);
    await controller.recordAiAnswer(const AiAnswer(question: 'Q', answer: 'A'));
    expect(controller.chatMessages, isNotEmpty);

    await controller.clearChat();

    expect(controller.chatMessages, isEmpty);
    expect(await ChatRepo(db).all(), isEmpty);
  });

  test('load() restores a previously written history in chronological order', () async {
    // Each pair gets a beat of real time so `created_at` orders them the way
    // they were written -- `ChatRepo.all` breaks same-millisecond ties by
    // `id`, which is only stable when the timestamps actually differ.
    final writer = ChatController(library: library, database: () async => db);
    await writer.recordAiAnswer(const AiAnswer(question: 'first Q', answer: 'first A'));
    await Future.delayed(const Duration(milliseconds: 5));
    await writer.recordAiAnswer(const AiAnswer(question: 'second Q', answer: 'second A'));

    final reader = ChatController(library: library, database: () async => db);
    expect(reader.chatMessages, isEmpty);

    await reader.load();

    expect(reader.chatMessages.map((m) => m.text), [
      'first Q',
      'first A',
      'second Q',
      'second A',
    ]);
  });
}
