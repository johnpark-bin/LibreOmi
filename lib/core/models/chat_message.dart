/// The chat message model.
library;

/// Chat message in AI conversation
class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final DateTime createdAt;

  /// The conversation this exchange was about, when it was about one.
  /// The chat page asks across the whole library, so this is usually null.
  final String? conversationId;

  ChatMessage({
    required this.id,
    required this.text,
    required this.isUser,
    required this.createdAt,
    this.conversationId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversation_id': conversationId,
    'text': text,
    'is_user': isUser ? 1 : 0,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'],
      text: json['text'] ?? '',
      isUser: json['is_user'] == 1 || json['is_user'] == true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['created_at']),
      conversationId: json['conversation_id'],
    );
  }

  factory ChatMessage.fromDbRow(Map<String, dynamic> row) =>
      ChatMessage.fromJson(row);
}
