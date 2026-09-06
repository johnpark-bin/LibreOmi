/// Sherpa-ONNX transcription service with real-time streaming ASR
/// Using streaming-zipformer-en-20M model for English.
///
/// Model files are no longer downloaded here: they come from the
/// `ModelStore` in `transcription/model_store.dart`, which the models page
/// installs into ahead of time (see `transcription/model_catalog.dart` for
/// which model this service uses).
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../models/conversation.dart';
import '../transcription/model_catalog.dart';
import '../transcription/model_store.dart';

class SherpaService {
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  bool _isInitialized = false;
  bool _isProcessing = false;

  final Function(List<TranscriptSegment>)? onTranscript;
  final Function(String)? onError;

  /// Overrides model resolution for tests. When null, [initialize] asks
  /// [modelStore] (or a fresh [ModelStore]) for the installed directory.
  final String? modelDir;
  final ModelStore? modelStore;

  // Audio format settings
  static const int sampleRate = 16000;

  // State for buffering
  String _lastText = '';
  Timer? _emitTimer;

  SherpaService({
    this.onTranscript,
    this.onError,
    this.modelDir,
    this.modelStore,
  });

  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;

  /// Initialize Sherpa-ONNX with streaming ASR model
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('Initializing Sherpa-ONNX...');

      final modelDir = this.modelDir ??
          await (modelStore ?? ModelStore())
              .requireInstalledDir(ModelCatalog.defaultStreaming);
      debugPrint('Using model from: $modelDir');

      // Initialize sherpa-onnx bindings first
      sherpa.initBindings();
      
      // Configure the transducer model
      final transducer = sherpa.OnlineTransducerModelConfig(
        encoder: '$modelDir/encoder-epoch-99-avg-1.onnx',
        decoder: '$modelDir/decoder-epoch-99-avg-1.onnx',
        joiner: '$modelDir/joiner-epoch-99-avg-1.onnx',
      );
      
      final modelConfig = sherpa.OnlineModelConfig(
        transducer: transducer,
        tokens: '$modelDir/tokens.txt',
        debug: false,
        numThreads: 2,
      );
      
      final config = sherpa.OnlineRecognizerConfig(
        model: modelConfig,
        enableEndpoint: true,
      );
      
      _recognizer = sherpa.OnlineRecognizer(config);
      _stream = _recognizer!.createStream();
      
      _isInitialized = true;
      debugPrint('Sherpa-ONNX initialized successfully');
      
    } on ModelNotInstalledException catch (e) {
      debugPrint('Failed to initialize Sherpa-ONNX: ${e.message}');
      onError?.call(e.message);
      rethrow;
    } catch (e) {
      debugPrint('Failed to initialize Sherpa-ONNX: $e');
      onError?.call('Failed to initialize Sherpa-ONNX: $e');
      rethrow;
    }
  }

  /// Start processing audio
  void startProcessing() {
    if (!_isInitialized) {
      onError?.call('Sherpa-ONNX not initialized');
      return;
    }
    
    _lastText = '';
    _isProcessing = true;
    
    debugPrint('Sherpa-ONNX processing started');
  }

  /// Add audio data to stream (expects PCM16 format)
  void addAudio(Uint8List audioData) {
    if (!_isProcessing || _recognizer == null || _stream == null) return;
    
    try {
      // Convert PCM16 bytes to float samples
      final samples = _bytesToFloatSamples(audioData);
      
      // Feed to recognizer
      _stream!.acceptWaveform(sampleRate: sampleRate, samples: samples);
      
      // Process all ready frames
      while (_recognizer!.isReady(_stream!)) {
        _recognizer!.decode(_stream!);
      }
      
      // Check for valid endpoint (end of sentence/utterance)
      // This is crucial to avoid emitting partial duplicates
      final isEndpoint = _recognizer!.isEndpoint(_stream!);
      
      if (isEndpoint) {
        final result = _recognizer!.getResult(_stream!);
        if (result.text.isNotEmpty) {
          _lastText = result.text;
          _checkAndEmit(); // Emit the final segment
        }
      }
    } catch (e) {
      debugPrint('Sherpa-ONNX audio processing error: $e');
    }
  }
  
  /// Convert PCM16 bytes to float samples
  Float32List _bytesToFloatSamples(Uint8List bytes) {
    // Ensure we have an even number of bytes
    final validLength = bytes.length - (bytes.length % 2);
    if (validLength == 0) return Float32List(0);
    
    // Use ByteData for safe access regardless of buffer alignment
    final byteData = ByteData.sublistView(bytes, 0, validLength);
    final numSamples = validLength ~/ 2;
    final floatSamples = Float32List(numSamples);
    
    for (int i = 0; i < numSamples; i++) {
      final int16Value = byteData.getInt16(i * 2, Endian.little);
      floatSamples[i] = int16Value / 32768.0;
    }
    return floatSamples;
  }

  /// Emit segment and reset stream
  void _checkAndEmit() {
    if (_lastText.isEmpty) return;
    
    final text = _lastText.trim();
    if (text.isEmpty) return;
    
    debugPrint('Sherpa finalized: $text');
    
    // Emit as segment
    final segment = TranscriptSegment(
      text: text,
      speakerId: 0,
      startTime: 0,
      endTime: 0,
    );
    
    onTranscript?.call([segment]);
    
    // Reset stream for next utterance
    if (_recognizer != null && _stream != null) {
      _recognizer!.reset(_stream!);
      _lastText = '';
    }
  }

  /// Stop processing
  void stopProcessing() {
    _emitTimer?.cancel();
    _emitTimer = null;
    _isProcessing = false;
    
    // Emit any remaining text
    if (_lastText.isNotEmpty) {
      _checkAndEmit();
    }
    
    debugPrint('Sherpa-ONNX processing stopped');
  }

  /// Dispose resources
  void dispose() {
    stopProcessing();
    _stream?.free();
    _recognizer?.free();
    _stream = null;
    _recognizer = null;
    _isInitialized = false;
  }
}
