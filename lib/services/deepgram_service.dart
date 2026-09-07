/// Direct Deepgram WebSocket service for speech-to-text
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/models.dart';
import 'deepgram/deepgram_parser.dart';
import 'settings_service.dart';

class DeepgramService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;

  final String apiKey;
  final String language;
  final String encoding;
  final int sampleRate;
  final Function(List<TranscriptSegment>)? onTranscript;
  final Function(String)? onError;

  /// Explicit model override. When null the model is read from
  /// [SettingsService] at connect time, so the constructor stays free of
  /// side effects and a settings change takes effect on the next connect.
  final String? _modelOverride;

  DeepgramService({
    required this.apiKey,
    this.language = 'en',
    this.encoding = 'opus',
    this.sampleRate = 16000,
    this.onTranscript,
    this.onError,
    String? model,
  }) : _modelOverride = model;

  /// Model this service will use on its next [connect].
  String get model => _modelOverride ?? SettingsService.deepgramModel;

  bool get isConnected => _isConnected;

  /// Builds the Deepgram `/v1/listen` WebSocket URI. Extracted as a pure,
  /// testable function so query-parameter changes get unit test coverage
  /// without opening a real socket.
  @visibleForTesting
  static Uri buildListenUri({
    required String model,
    required String language,
    required int sampleRate,
    required String encoding,
  }) {
    return Uri.parse(
      'wss://api.deepgram.com/v1/listen'
      '?model=$model'
      '&language=$language'
      '&punctuate=true'
      '&diarize=true'
      '&sample_rate=$sampleRate'
      '&encoding=$encoding'
      '&channels=1'
    );
  }

  Future<void> connect() async {
    if (_isConnected) return;

    try {
      final uri = buildListenUri(
        model: model,
        language: language,
        sampleRate: sampleRate,
        encoding: encoding,
      );

      _channel = WebSocketChannel.connect(
        uri,
        protocols: ['token', apiKey],
      );

      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          debugPrint('Deepgram WebSocket error: $error');
          onError?.call(error.toString());
          _isConnected = false;
        },
        onDone: () {
          debugPrint('Deepgram WebSocket closed');
          _isConnected = false;
        },
      );

      _isConnected = true;
      debugPrint('Connected to Deepgram (model: $model, encoding: $encoding, sampleRate: $sampleRate)');
    } catch (e) {
      debugPrint('Failed to connect to Deepgram: $e');
      onError?.call(e.toString());
      _isConnected = false;
    }
  }

  void _handleMessage(dynamic message) {
    try {
      // Decode once, then dispatch on the message type.
      final json = decodeDeepgramMessage(message as String);
      if (json == null) return;

      switch (json['type']) {
        case 'Results':
          final result = parseDeepgramResults(json);

          // Interim results repeat and extend the same audio window, so only
          // final results are billed. See DeepgramResult.billableMinutes.
          final minutes = result.billableMinutes;
          if (minutes > 0) {
            SettingsService.addDeepgramUsage(minutes);
          }

          if (result.segments.isNotEmpty) {
            onTranscript?.call(result.segments);
          }
        case 'Metadata':
          // Closing message; usage is already accounted for from the final
          // results, so this is logged for diagnostics only.
          debugPrint(
              'Deepgram Metadata received (total duration: ${json['duration']})');
      }
    } catch (e) {
      debugPrint('Error parsing Deepgram message: $e');
    }
  }

  void sendAudio(Uint8List audioData) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(audioData);
  }

  Future<void> disconnect() async {
    _isConnected = false;
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    debugPrint('Disconnected from Deepgram');
  }
}
