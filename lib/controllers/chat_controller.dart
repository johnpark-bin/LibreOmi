/// Owns the chat page's message list (LO-34, unit 1 of the pre-LO-34
/// monolith's split, `docs/06-roadmap.md`).
///
/// Unlike the rest of `LibraryController`, this is not a straight port:
/// The pre-LO-34 monolith kept chat messages in memory only, while schema v5 added the
/// `chat_messages` table (`data/db.dart`), so every appended message is now
/// also persisted through `ChatRepo`.
library;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/chat_repo.dart';
import '../data/db.dart';
import '../intelligence/llm_client.dart';
import '../intelligence/openai_client.dart';
import '../l10n/l10n.dart';
import '../models/conversation.dart';
import '../services/settings_service.dart';
import '../session/recording_session.dart' show AiAnswer;
import 'library_controller.dart';

class ChatController extends ChangeNotifier {
  ChatController({
    required LibraryController library,
    Future<Database> Function()? database,
    LlmClientFactory? llmClientFactory,
  })  : _library = library,
        _database = database ?? AppDatabase.instance,
        _llmClientFactory = llmClientFactory ?? _defaultLlmClient;

  final LibraryController _library;
  final Future<Database> Function() _database;
  final LlmClientFactory _llmClientFactory;

  /// Builds the LLM client for one call.
  ///
  /// Deliberately not a shared field: a background drain would otherwise be
  /// able to swap the client out from under a chat request that is between
  /// its own assignment and its use, and the key and model can change in
  /// settings between a conversation being queued and being retried.
  static LlmClient _defaultLlmClient() => OpenAiClient.fromApiKey(
        apiKey: SettingsService.openaiApiKey,
        model: SettingsService.openaiModel,
      );

  List<ChatMessage> _chatMessages = [];
  List<ChatMessage> get chatMessages => _chatMessages;

  bool _isChatLoading = false;
  bool get isChatLoading => _isChatLoading;

  /// Reads the persisted chat history back. Tolerates a read failure -- a
  /// broken history must not stop the chat page from rendering -- by
  /// logging and leaving the list empty.
  Future<void> load() async {
    try {
      _chatMessages = await ChatRepo(await _database()).all();
    } catch (e) {
      debugPrint('Failed to load chat history: $e');
      _chatMessages = [];
    }
    notifyListeners();
  }

  Future<void> _persist(ChatMessage message) async {
    try {
      await ChatRepo(await _database()).save(message);
    } catch (e) {
      debugPrint('Failed to persist chat message: $e');
    }
  }

  Future<void> sendChatMessage(String message) async {
    if (message.trim().isEmpty) return;
    if (!SettingsService.hasOpenAIKey) {
      throw Exception(L10n.current.chatController_openAiKeyMissingError);
    }

    // Add user message
    final userMessage = ChatMessage(
      id: const Uuid().v4(),
      text: message,
      isUser: true,
      createdAt: DateTime.now(),
    );
    _chatMessages.add(userMessage);
    _isChatLoading = true;
    notifyListeners();
    await _persist(userMessage);

    // Build context from recent conversations
    final context = _buildMemoryContext();

    // Get AI response. Built per call for the same reason every other
    // [LlmClient] call site here is: see [_defaultLlmClient].
    final llmClient = _llmClientFactory();

    ChatMessage replyMessage;
    try {
      final response = await llmClient.chat(message, context: context);

      replyMessage = ChatMessage(
        id: const Uuid().v4(),
        text: response,
        isUser: false,
        createdAt: DateTime.now(),
      );
    } catch (e) {
      replyMessage = ChatMessage(
        id: const Uuid().v4(),
        text: L10n.current.chatController_replyErrorMessage(e.toString()),
        isUser: false,
        createdAt: DateTime.now(),
      );
    }
    _chatMessages.add(replyMessage);

    _isChatLoading = false;
    notifyListeners();
    await _persist(replyMessage);
  }

  String _buildMemoryContext() {
    final buffer = StringBuffer();

    // Include stored memories first
    final memories = _library.memories;
    if (memories.isNotEmpty) {
      buffer.writeln('Important facts about the user:');
      for (final memory in memories.take(20)) {
        buffer.writeln('• ${memory.content}');
      }
      buffer.writeln('');
    }

    // Then add recent conversation summaries
    final conversations = _library.conversations;
    if (conversations.isNotEmpty) {
      buffer.writeln('Recent conversation summaries:');
      final recent = conversations.take(5);
      for (final conv in recent) {
        buffer.writeln('---');
        buffer.writeln('Date: ${conv.createdAt.toString().substring(0, 16)}');
        if (conv.title.isNotEmpty) buffer.writeln('Topic: ${conv.title}');
        if (conv.summary.isNotEmpty) buffer.writeln('Summary: ${conv.summary}');
      }
    }

    return buffer.toString();
  }

  /// The old monolith's `_recordAiAnswer`: the hold-to-ask answer is
  /// delivered as a notification by the session and also recorded here.
  Future<void> recordAiAnswer(AiAnswer answer) async {
    final questionMessage = ChatMessage(
      id: const Uuid().v4(),
      text: answer.question,
      isUser: true,
      createdAt: DateTime.now(),
    );
    // Both timestamps are the real ones even when the two calls land in the
    // same clock tick: `ChatRepo` sorts on `chat_messages.seq`, the insertion
    // order stamped at save time (schema v6, LO-65), so a reloaded history
    // keeps the question ahead of its answer without either of them having to
    // be nudged off the clock.
    final answerMessage = ChatMessage(
      id: const Uuid().v4(),
      text: answer.answer,
      isUser: false,
      createdAt: DateTime.now(),
    );
    _chatMessages.add(questionMessage);
    _chatMessages.add(answerMessage);
    notifyListeners();

    await _persist(questionMessage);
    await _persist(answerMessage);
  }

  Future<void> clearChat() async {
    _chatMessages = [];
    notifyListeners();
    try {
      await ChatRepo(await _database()).clear();
    } catch (e) {
      debugPrint('Failed to clear persisted chat history: $e');
    }
  }
}
