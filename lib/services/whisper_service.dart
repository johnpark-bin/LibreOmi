/// Whisper transcription service using Sherpa-ONNX offline recognition
/// Supports tiny and base model sizes for local speech-to-text.
///
/// Model files are no longer downloaded here: they come from the
/// `ModelStore` in `transcription/model_store.dart`, which the models page
/// installs into ahead of time (see `transcription/model_catalog.dart` for
/// the tiny/base entries this service resolves via [modelSize]).
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../models/conversation.dart';
import '../transcription/model_catalog.dart';
import '../transcription/model_store.dart';

class WhisperService {
  sherpa.OfflineRecognizer? _recognizer;
  bool _isInitialized = false;
  bool _isProcessing = false;

  final Function(List<TranscriptSegment>)? onTranscript;
  final Function(String)? onError;

  // Model info - configurable size
  final String modelSize; // 'tiny' or 'base'

  /// Overrides model resolution for tests. When null, [initialize] asks
  /// [modelStore] (or a fresh [ModelStore]) for the installed directory.
  final String? modelDir;
  final ModelStore? modelStore;

  // Audio format settings
  static const int sampleRate = 16000;

  // Audio buffer for batch processing
  List<double> _audioBuffer = [];
  Timer? _processTimer;
  static const Duration _processInterval = Duration(seconds: 3); // Process every 3 seconds

  WhisperService({
    this.onTranscript,
    this.onError,
    this.modelSize = 'tiny', // Default to tiny for faster loading
    this.modelDir,
    this.modelStore,
  });

  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;

  /// Initialize Whisper with offline ASR model
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('Initializing Whisper $modelSize...');

      // The catalog is what decides which model a size string maps to, so
      // the file names below have to come from the same reduction — a stale
      // preference otherwise resolves to the tiny directory and then looks
      // for files named after a size that is not in it.
      final size = ModelCatalog.whisperSize(modelSize);
      final modelDir = this.modelDir ??
          await (modelStore ?? ModelStore())
              .requireInstalledDir(ModelCatalog.whisper(modelSize));
      debugPrint('Using Whisper model from: $modelDir');

      // Initialize sherpa-onnx bindings first
      sherpa.initBindings();
      
      // Configure the Whisper model
      final whisperConfig = sherpa.OfflineWhisperModelConfig(
        encoder: '$modelDir/$size-encoder.onnx',
        decoder: '$modelDir/$size-decoder.onnx',
      );
      
      final modelConfig = sherpa.OfflineModelConfig(
        whisper: whisperConfig,
        tokens: '$modelDir/$size-tokens.txt',
        debug: false,
        numThreads: 2,
      );
      
      final config = sherpa.OfflineRecognizerConfig(
        model: modelConfig,
      );
      
      _recognizer = sherpa.OfflineRecognizer(config);
      
      _isInitialized = true;
      debugPrint('Whisper $modelSize initialized successfully');
      
    } on ModelNotInstalledException catch (e) {
      debugPrint('Failed to initialize Whisper: ${e.message}');
      onError?.call(e.message);
      rethrow;
    } catch (e) {
      debugPrint('Failed to initialize Whisper: $e');
      onError?.call('Failed to initialize Whisper: $e');
      rethrow;
    }
  }

  /// Start processing audio
  void startProcessing() {
    if (!_isInitialized) {
      onError?.call('Whisper not initialized');
      return;
    }
    
    _audioBuffer = [];
    _isProcessing = true;
    
    // Start periodic processing timer
    _processTimer = Timer.periodic(_processInterval, (_) => _processBuffer());
    
    debugPrint('Whisper processing started');
  }

  /// Add audio data to buffer (expects PCM16 format)
  void addAudio(Uint8List audioData) {
    if (!_isProcessing || _recognizer == null) return;
    
    try {
      // Convert PCM16 bytes to float samples
      final samples = _bytesToFloatSamples(audioData);
      _audioBuffer.addAll(samples);
    } catch (e) {
      debugPrint('Whisper audio buffer error: $e');
    }
  }
  
  /// Convert PCM16 bytes to float samples
  List<double> _bytesToFloatSamples(Uint8List bytes) {
    // Ensure we have an even number of bytes
    final validLength = bytes.length - (bytes.length % 2);
    if (validLength == 0) return <double>[];
    
    // Use ByteData for safe access regardless of buffer alignment
    final byteData = ByteData.sublistView(bytes, 0, validLength);
    final numSamples = validLength ~/ 2;
    final floatSamples = <double>[];
    
    for (int i = 0; i < numSamples; i++) {
      final int16Value = byteData.getInt16(i * 2, Endian.little);
      floatSamples.add(int16Value / 32768.0);
    }
    return floatSamples;
  }

  /// Process the audio buffer
  void _processBuffer() {
    if (!_isProcessing || _recognizer == null || _audioBuffer.isEmpty) return;
    
    try {
      // Need at least 0.5 seconds of audio to process
      final minSamples = sampleRate ~/ 2;
      if (_audioBuffer.length < minSamples) return;
      
      // Take the buffer and clear it
      final samples = Float32List.fromList(_audioBuffer.map((e) => e.toDouble()).toList());
      _audioBuffer = [];
      
      debugPrint('Processing ${samples.length} samples with Whisper...');
      
      // Create stream and process
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(sampleRate: sampleRate, samples: samples);
      _recognizer!.decode(stream);
      
      final result = _recognizer!.getResult(stream);
      stream.free();
      
      if (result.text.isNotEmpty) {
        final text = result.text.trim();
        debugPrint('Whisper recognized: $text');
        
        // Emit as segment
        final segment = TranscriptSegment(
          text: text,
          speakerId: 0,
          startTime: 0,
          endTime: 0,
        );
        
        onTranscript?.call([segment]);
      }
    } catch (e) {
      debugPrint('Whisper processing error: $e');
    }
  }

  /// Stop processing
  void stopProcessing() {
    _processTimer?.cancel();
    _processTimer = null;
    _isProcessing = false;
    
    // Process any remaining audio
    if (_audioBuffer.isNotEmpty) {
      _processBuffer();
    }
    
    debugPrint('Whisper processing stopped');
  }

  /// Dispose resources
  void dispose() {
    stopProcessing();
    _recognizer?.free();
    _recognizer = null;
    _isInitialized = false;
  }
}
