/// Pure Dart parsing for Deepgram WebSocket streaming messages.
///
/// This file has no Flutter/widget dependencies so it can be unit tested
/// without a socket, an API key, or the Flutter test binding.
library;

import 'dart:convert';

import '../../core/models.dart';

/// Result of parsing a Deepgram `Results` message.
class DeepgramResult {
  /// Deepgram sets `is_final` at the top level of a `Results` message.
  final bool isFinal;

  /// Length in seconds of the audio window this result covers.
  final double duration;

  final List<TranscriptSegment> segments;

  const DeepgramResult({
    required this.isFinal,
    required this.duration,
    required this.segments,
  });

  /// Minutes of audio this result should be billed for.
  ///
  /// Only final results count. Successive interim results repeat and extend
  /// the same audio window, so summing every result's [duration] over-counts
  /// the session.
  double get billableMinutes =>
      (isFinal && duration > 0) ? duration / 60.0 : 0.0;
}

/// Decodes one raw Deepgram WebSocket text message into its JSON object.
///
/// Returns `null` when [message] is not valid JSON or is not a JSON object.
/// Callers decode once with this and then dispatch on the `type` field, so a
/// message is never parsed twice.
Map<String, dynamic>? decodeDeepgramMessage(String message) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(message);
  } catch (_) {
    return null;
  }
  return decoded is Map<String, dynamic> ? decoded : null;
}

/// Parses an already-decoded Deepgram `Results` message body.
///
/// A payload whose shape does not match what Deepgram documents yields an
/// empty segment list instead of throwing, so one odd message never costs the
/// caller its usage accounting. Shape checks are explicit rather than a
/// blanket `catch`, so a genuine bug in this function still throws and gets
/// logged by the caller instead of disappearing into silence.
DeepgramResult parseDeepgramResults(Map<String, dynamic> json) {
  final isFinal = json['is_final'] == true;

  var duration = (json['duration'] as num?)?.toDouble() ?? 0.0;
  if (duration < 0) duration = 0.0;

  return DeepgramResult(
    isFinal: isFinal,
    duration: duration,
    segments: _extractSegments(json),
  );
}

List<TranscriptSegment> _extractSegments(Map<String, dynamic> json) {
  final channel = json['channel'];
  if (channel is! Map) return const [];

  final alternatives = channel['alternatives'];
  if (alternatives is! List || alternatives.isEmpty) return const [];

  final alternative = alternatives.first;
  if (alternative is! Map) return const [];

  final transcript = alternative['transcript'];
  if (transcript is! String || transcript.isEmpty) return const [];

  final words = alternative['words'];
  if (words is! List) return const [];

  return segmentsFromDeepgramWords(words);
}

/// Groups Deepgram `words` entries by speaker, preserving first-seen speaker
/// order, and joins each speaker's words into one segment.
///
/// Public because both the streaming parser above (via [_extractSegments])
/// and `transcription/deepgram_prerecorded.dart`'s pre-recorded file
/// transcriber consume the same Deepgram `words` array shape and must not
/// drift into two different grouping rules (LO-51).
List<TranscriptSegment> segmentsFromDeepgramWords(List words) {
  if (words.isEmpty) return [];

  // Group words by speaker
  Map<int, List<dynamic>> speakerWords = {};

  for (var word in words) {
    if (word is! Map) continue;
    final speaker = word['speaker'];
    speakerWords.putIfAbsent(speaker is int ? speaker : 0, () => []).add(word);
  }

  List<TranscriptSegment> segments = [];

  for (var entry in speakerWords.entries) {
    final wordList = entry.value;
    if (wordList.isEmpty) continue;

    final text = wordList.map((w) => w['word'] ?? '').join(' ');
    final start = (wordList.first['start'] ?? 0).toDouble();
    final end = (wordList.last['end'] ?? 0).toDouble();

    segments.add(TranscriptSegment(
      text: text,
      speakerId: entry.key,
      startTime: start,
      endTime: end,
    ));
  }

  return segments;
}
