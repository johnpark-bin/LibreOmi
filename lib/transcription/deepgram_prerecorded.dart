/// Deepgram's pre-recorded ("batch") REST transcription, for files that
/// already exist on disk rather than a live audio stream.
///
/// This file has no Flutter/widget dependencies (beyond `dart:io`'s [File])
/// so it can be unit tested with `package:http/testing.dart`'s `MockClient`
/// instead of a real network call.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../services/deepgram/deepgram_parser.dart';
import 'transcriber.dart';

/// Longest prefix of a failed response body to include in the thrown
/// [Exception]'s message. Deepgram error bodies are small JSON objects;
/// this cap just guards against an unexpected HTML error page or proxy
/// response being dumped whole into a log.
const _maxErrorBodyLength = 200;

/// [FileTranscriber] backed by Deepgram's `/v1/listen` pre-recorded API.
///
/// Shares [segmentsFromDeepgramWords] with the live streaming path in
/// `deepgram_parser.dart` so a completed recording and a live caption never
/// disagree about how words become speaker segments (LO-51).
class DeepgramPreRecordedTranscriber implements FileTranscriber {
  DeepgramPreRecordedTranscriber({
    required this.apiKey,
    this.model = 'nova-2',
    this.language = 'en',
    http.Client? client,
    this.onUsage,
  })  : _client = client ?? http.Client(),
        // A transcriber is built per import (`session/sdcard_import.dart`),
        // so a client this class created must be closed with it or every
        // cloud import leaks an idle connection pool. An injected client
        // belongs to the caller and is left alone.
        _ownsClient = client == null;

  final String apiKey;
  final String model;
  final String language;
  final http.Client _client;
  final bool _ownsClient;

  /// Reports minutes of audio billed for the most recent [transcribe] call.
  ///
  /// This is a callback rather than a direct call to
  /// `SettingsService.addDeepgramUsage` so this file stays free of
  /// `SettingsService`/Flutter bindings and can be unit tested without the
  /// Flutter test binding; the caller wires usage accounting itself.
  final void Function(double minutes)? onUsage;

  @override
  Future<List<TranscriptSegment>> transcribe(File wav) async {
    final bytes = await wav.readAsBytes();

    final uri = Uri.https('api.deepgram.com', '/v1/listen', {
      'model': model,
      'language': language,
      'punctuate': 'true',
      'diarize': 'true',
    });

    final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: {
          'Authorization': 'Token $apiKey',
          'Content-Type': 'audio/wav',
        },
        body: bytes,
      );
    } finally {
      if (_ownsClient) _client.close();
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Deepgram pre-recorded request failed with status '
        '${response.statusCode}: ${_truncate(response.body)}',
      );
    }

    // A body that will not decode is a broken response, not a silent
    // recording: the SD-card importer deletes the `.bin` once an import
    // returns, so "no speech" and "the answer was garbage" must not look
    // the same to it.
    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (e) {
      throw Exception(
        'Deepgram pre-recorded response was not JSON: ${_truncate(response.body)}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception(
        'Deepgram pre-recorded response was not a JSON object: '
        '${_truncate(response.body)}',
      );
    }

    _reportUsage(decoded);

    return _extractSegments(decoded);
  }

  /// Caps a response body quoted in an error message: a Deepgram failure can
  /// carry a long body, and the message ends up in a snackbar.
  static String _truncate(String body) => body.length > _maxErrorBodyLength
      ? '${body.substring(0, _maxErrorBodyLength)}…'
      : body;

  void _reportUsage(Map<String, dynamic> json) {
    final metadata = json['metadata'];
    if (metadata is! Map) return;

    final duration = metadata['duration'];
    if (duration is! num || duration <= 0) return;

    onUsage?.call(duration / 60.0);
  }

  List<TranscriptSegment> _extractSegments(Map<String, dynamic> json) {
    final results = json['results'];
    if (results is! Map) return const [];

    final channels = results['channels'];
    if (channels is! List || channels.isEmpty) return const [];

    final channel = channels.first;
    if (channel is! Map) return const [];

    final alternatives = channel['alternatives'];
    if (alternatives is! List || alternatives.isEmpty) return const [];

    final alternative = alternatives.first;
    if (alternative is! Map) return const [];

    final words = alternative['words'];
    if (words is! List || words.isEmpty) return const [];

    return segmentsFromDeepgramWords(words);
  }
}
