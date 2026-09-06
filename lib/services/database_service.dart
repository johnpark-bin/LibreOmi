/// Facade over the repositories in `lib/data` (LO-35).
///
/// Every method here forwards to a repository; the SQL lives there. The class
/// stays as it was — static, same signatures — so the callers that still say
/// `DatabaseService.saveConversation(...)` keep compiling while LO-34 moves
/// them onto the repositories one controller at a time.
library;

import 'package:sqflite/sqflite.dart';

import '../data/chat_repo.dart';
import '../data/conversation_repo.dart';
import '../data/db.dart';
import '../data/memory_repo.dart';
import '../data/task_repo.dart';
import '../models/conversation.dart';

class DatabaseService {
  /// Schema version. Owned by [AppDatabase]; re-exported because callers and
  /// tests already read it from here.
  static const int dbVersion = AppDatabase.schemaVersion;

  static Future<Database> get database => AppDatabase.instance();

  static Future<void> createSchema(Database db) => AppDatabase.createSchema(db);

  static Future<void> migrate(Database db, int oldVersion, int newVersion) =>
      AppDatabase.migrate(db, oldVersion, newVersion);

  static Future<void> createPendingFinalizationsTable(Database db) =>
      AppDatabase.createPendingFinalizationsTable(db);

  // Conversation CRUD operations

  static Future<void> saveConversation(Conversation conversation) async =>
      ConversationRepo(await database).save(conversation);

  static Future<List<Conversation>> getConversations({int limit = 50}) async =>
      ConversationRepo(await database).all(limit: limit);

  static Future<Conversation?> getConversation(String id) async =>
      ConversationRepo(await database).byId(id);

  static Future<void> deleteConversation(String id) async =>
      ConversationRepo(await database).delete(id);

  static Future<String> getAllConversationsContext({int limit = 10}) async =>
      ConversationRepo(await database).contextText(limit: limit);

  // Memory CRUD operations

  static Future<void> saveMemory(Memory memory) async =>
      MemoryRepo(await database).save(memory);

  static Future<List<Memory>> getMemories({int limit = 100}) async =>
      MemoryRepo(await database).all(limit: limit);

  static Future<void> deleteMemory(String id) async =>
      MemoryRepo(await database).delete(id);

  /// Update memory content
  static Future<void> updateMemory(String id, String content) async =>
      MemoryRepo(await database).updateContent(id, content);

  /// Check if a similar memory already exists (for deduplication)
  static Future<bool> hasSimilarMemory(String content) async =>
      MemoryRepo(await database).hasSimilar(content);

  // Task CRUD operations

  static Future<void> saveTask(Task task) async =>
      TaskRepo(await database).save(task);

  static Future<List<Task>> getTasks({int limit = 100}) async =>
      TaskRepo(await database).all(limit: limit);

  static Future<void> updateTaskCompletion(String id, bool isCompleted) async =>
      TaskRepo(await database).setCompleted(id, isCompleted);

  static Future<void> deleteTask(String id) async =>
      TaskRepo(await database).delete(id);

  /// Check if a similar task already exists (for deduplication)
  static Future<bool> hasSimilarTask(String title) async =>
      TaskRepo(await database).hasSimilar(title);

  // Chat history (persisted since schema v5)

  static Future<void> saveChatMessage(ChatMessage message) async =>
      ChatRepo(await database).save(message);

  static Future<List<ChatMessage>> getChatMessages({int limit = 500}) async =>
      ChatRepo(await database).all(limit: limit);

  static Future<void> deleteChatMessage(String id) async =>
      ChatRepo(await database).delete(id);

  static Future<void> clearChatMessages() async =>
      ChatRepo(await database).clear();

  /// Export all data for backup/sharing
  static Future<Map<String, dynamic>> exportAllData() async {
    final conversations = await getConversations(limit: 10000);
    final memories = await getMemories(limit: 10000);
    final tasks = await getTasks(limit: 10000);
    final chatMessages = await getChatMessages(limit: 10000);

    return {
      'export_date': DateTime.now().toIso8601String(),
      'app_version': '2.1.0',
      'conversations': conversations.map((c) => c.toJson()).toList(),
      'memories': memories.map((m) => m.toJson()).toList(),
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'chat_messages': chatMessages.map((m) => m.toJson()).toList(),
    };
  }
}
