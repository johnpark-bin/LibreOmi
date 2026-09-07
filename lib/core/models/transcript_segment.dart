/// The transcript segment model.
library;

/// A single segment of transcribed speech
class TranscriptSegment {
  final String text;
  final int speakerId;
  final double startTime;
  final double endTime;
  final bool isUser;

  /// Wall-clock start/end of this segment, in addition to the
  /// Deepgram-relative seconds above. Optional: null when the source of
  /// this segment did not supply a wall-clock timestamp.
  ///
  /// Serialized as milliseconds since epoch, so a round trip through JSON
  /// truncates sub-millisecond precision and returns a local-zone
  /// `DateTime` even when a UTC one went in. The instant is preserved;
  /// `==` against the original UTC value is not.
  final DateTime? startAt;
  final DateTime? endAt;

  TranscriptSegment({
    required this.text,
    required this.speakerId,
    required this.startTime,
    required this.endTime,
    this.isUser = false,
    this.startAt,
    this.endAt,
  });

  Map<String, dynamic> toJson() => {
    'text': text,
    'speaker_id': speakerId,
    'start': startTime,
    'end': endTime,
    'is_user': isUser,
    if (startAt != null) 'start_at': startAt!.millisecondsSinceEpoch,
    if (endAt != null) 'end_at': endAt!.millisecondsSinceEpoch,
  };

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptSegment(
      text: json['text'] ?? '',
      speakerId: json['speaker_id'] ?? json['speaker'] ?? 0,
      startTime: (json['start'] ?? 0).toDouble(),
      endTime: (json['end'] ?? 0).toDouble(),
      isUser: json['is_user'] ?? false,
      startAt: json['start_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch((json['start_at'] as num).toInt())
          : null,
      endAt: json['end_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch((json['end_at'] as num).toInt())
          : null,
    );
  }
}
