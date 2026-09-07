/// The memory model.
library;

/// A memory extracted from conversations
class Memory {
  final String id;
  final String content;           // "User's name is Karsten"
  final String category;          // "personal", "preference", "fact"
  final DateTime createdAt;
  final String? sourceConversationId;

  Memory({
    required this.id,
    required this.content,
    required this.category,
    required this.createdAt,
    this.sourceConversationId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'category': category,
    'created_at': createdAt.millisecondsSinceEpoch,
    'source_conversation_id': sourceConversationId,
  };

  factory Memory.fromJson(Map<String, dynamic> json) {
    return Memory(
      id: json['id'],
      content: json['content'],
      category: json['category'] ?? 'fact',
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['created_at']),
      sourceConversationId: json['source_conversation_id'],
    );
  }

  factory Memory.fromDbRow(Map<String, dynamic> row) {
    return Memory(
      id: row['id'],
      content: row['content'],
      category: row['category'] ?? 'fact',
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']),
      sourceConversationId: row['source_conversation_id'],
    );
  }
}
