/// The conversation model.
library;

import 'dart:convert';

import 'transcript_segment.dart';

/// A complete conversation with transcript and AI summary
class Conversation {
  final String id;
  final DateTime createdAt;
  String title;
  String summary;
  List<TranscriptSegment> segments;

  Conversation({
    required this.id,
    required this.createdAt,
    this.title = '',
    this.summary = '',
    this.segments = const [],
  });

  String get transcript {
    return segments.map((s) => 'Speaker ${s.speakerId}: ${s.text}').join('\n');
  }

  /// Duration of the conversation, from the first segment's start to the
  /// last segment's end.
  ///
  /// Prefers the wall-clock timestamps when the first segment has a
  /// [TranscriptSegment.startAt] and the last has an
  /// [TranscriptSegment.endAt], clamping a negative result to
  /// [Duration.zero]. Otherwise falls back to the transcriber-relative
  /// seconds exactly as before LO-30 — including its lack of a clamp.
  Duration get duration {
    if (segments.isEmpty) return Duration.zero;

    final wallStart = segments.first.startAt;
    final wallEnd = segments.last.endAt;
    if (wallStart != null && wallEnd != null) {
      final diff = wallEnd.difference(wallStart);
      return diff.isNegative ? Duration.zero : diff;
    }

    // Fallback: relative seconds, unchanged from the pre-LO-30 behaviour.
    final firstStart = segments.first.startTime;
    final lastEnd = segments.last.endTime;
    return Duration(milliseconds: ((lastEnd - firstStart) * 1000).round());
  }

  /// Get formatted duration string (e.g., "5m 23s")
  String get formattedDuration {
    final d = duration;
    if (d.inSeconds < 60) {
      return '${d.inSeconds}s';
    } else if (d.inMinutes < 60) {
      final mins = d.inMinutes;
      final secs = d.inSeconds % 60;
      return secs > 0 ? '${mins}m ${secs}s' : '${mins}m';
    } else {
      final hours = d.inHours;
      final mins = d.inMinutes % 60;
      return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'created_at': createdAt.millisecondsSinceEpoch,
    'title': title,
    'summary': summary,
    'segments': segments.map((s) => s.toJson()).toList(),
  };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['created_at']),
      title: json['title'] ?? '',
      summary: json['summary'] ?? '',
      segments: (json['segments'] as List?)
          ?.map((s) => TranscriptSegment.fromJson(s))
          .toList() ?? [],
    );
  }

  factory Conversation.fromDbRow(Map<String, dynamic> row) {
    List<TranscriptSegment> segments = [];
    if (row['transcript'] != null && row['transcript'].isNotEmpty) {
      final decoded = jsonDecode(row['transcript']) as List;
      segments = decoded.map((s) => TranscriptSegment.fromJson(s)).toList();
    }
    return Conversation(
      id: row['id'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']),
      title: row['title'] ?? '',
      summary: row['summary'] ?? '',
      segments: segments,
    );
  }
}
