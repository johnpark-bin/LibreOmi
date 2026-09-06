/// The set of on-device speech models the app knows how to install, and the
/// facts `model_store.dart` needs to install and verify one.
///
/// Everything here is data: no I/O, no plugins, no Flutter. See
/// `docs/03-architecture.md` §1 for why `transcription/` may not reach past
/// its own plugin and `core/`.
library;

/// What a model is used for. Determines which recognizer the transcription
/// layer builds around it, not how it is downloaded.
enum ModelKind {
  /// sherpa-onnx streaming transducer (encoder/decoder/joiner + tokens).
  streamingZipformer,

  /// sherpa-onnx offline Whisper (encoder/decoder + tokens).
  whisper,

  /// Voice activity detection (Silero). No catalog entry yet: the VAD model
  /// arrives with LO-42, which is what will need it.
  vad,
}

/// One installable model.
///
/// [url] points at a `.tar.bz2` whose entries all sit under a single
/// [archiveTopDir]; [requiredFiles] are paths *relative to that directory*.
/// The store extracts exactly those and nothing else, which is why the
/// installed size is far below the archive size — the upstream archives ship
/// int8 copies of every weight plus `test_wavs/` that this app never opens.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.url,
    required this.archiveTopDir,
    required this.requiredFiles,
    required this.archiveBytes,
    required this.installedBytes,
    required this.languages,
    this.sha256,
  });

  /// Stable directory name under `<support>/models/`. Never change one for an
  /// existing entry: it is what an installed copy is found by.
  final String id;

  final ModelKind kind;

  /// Shown in the models page.
  final String displayName;

  /// Download location of the `.tar.bz2` archive.
  final String url;

  /// The single top-level directory every archive entry is nested under.
  final String archiveTopDir;

  /// Paths inside [archiveTopDir] that must exist after extraction, and the
  /// only ones extracted. Order is irrelevant.
  final List<String> requiredFiles;

  /// Size of the compressed archive, for the "this will download N MB"
  /// label and as the progress denominator when the server sends no
  /// `Content-Length`.
  final int archiveBytes;

  /// Approximate on-disk size of [requiredFiles] once extracted, for the
  /// "this will use N MB" label. The store reports the real size after
  /// installing.
  final int installedBytes;

  /// BCP-47-ish language tags, or `['multi']` for a multilingual model.
  final List<String> languages;

  /// Expected SHA-256 of the downloaded archive, or null when upstream
  /// publishes none.
  ///
  /// Every current entry is null, and nothing reads this yet. The k2-fsa
  /// `asr-models` release predates GitHub's asset digests (all three assets
  /// come back with `digest: null` from the releases API), so the only hash
  /// we could pin is one computed from our own download — and if upstream
  /// re-uploaded an asset that pin would become a permanent, unfixable
  /// install failure for every user. Until a model with a published digest
  /// is added, `ModelStore` verifies an install by checking that every
  /// [requiredFiles] entry exists and is non-empty; wiring an actual hash
  /// check also needs `package:crypto` promoted to a direct dependency,
  /// which is out of scope here.
  final String? sha256;

  /// Directory name the archive's files land in, relative to the models root.
  String get directoryName => id;
}

/// The models shipped in the app's catalog.
///
/// The three entries are the ones the current transcription paths already
/// expect by name (`services/sherpa_service.dart`,
/// `services/whisper_service.dart`); file names and sizes were read off the
/// upstream repositories rather than guessed.
class ModelCatalog {
  const ModelCatalog._();

  static const String _releaseBase =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

  /// English streaming transducer used by the "Local (Sherpa-ONNX)" mode.
  static const ModelSpec streamingZipformerEn20M = ModelSpec(
    id: 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17',
    kind: ModelKind.streamingZipformer,
    displayName: 'Streaming Zipformer (English, 20M)',
    url: '$_releaseBase/'
        'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2',
    archiveTopDir: 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17',
    requiredFiles: [
      'encoder-epoch-99-avg-1.onnx',
      'decoder-epoch-99-avg-1.onnx',
      'joiner-epoch-99-avg-1.onnx',
      'tokens.txt',
    ],
    archiveBytes: 127887156,
    installedBytes: 91928372,
    languages: ['en'],
  );

  /// Offline multilingual Whisper, tiny.
  static const ModelSpec whisperTiny = ModelSpec(
    id: 'sherpa-onnx-whisper-tiny',
    kind: ModelKind.whisper,
    displayName: 'Whisper tiny',
    url: '$_releaseBase/sherpa-onnx-whisper-tiny.tar.bz2',
    archiveTopDir: 'sherpa-onnx-whisper-tiny',
    requiredFiles: [
      'tiny-encoder.onnx',
      'tiny-decoder.onnx',
      'tiny-tokens.txt',
    ],
    archiveBytes: 116204861,
    installedBytes: 152969611,
    languages: ['multi'],
  );

  /// Offline multilingual Whisper, base. Slower and ~2x the disk of [whisperTiny].
  static const ModelSpec whisperBase = ModelSpec(
    id: 'sherpa-onnx-whisper-base',
    kind: ModelKind.whisper,
    displayName: 'Whisper base',
    url: '$_releaseBase/sherpa-onnx-whisper-base.tar.bz2',
    archiveTopDir: 'sherpa-onnx-whisper-base',
    requiredFiles: [
      'base-encoder.onnx',
      'base-decoder.onnx',
      'base-tokens.txt',
    ],
    archiveBytes: 207557382,
    installedBytes: 292452882,
    languages: ['multi'],
  );

  /// Every entry, in the order the models page lists them.
  static const List<ModelSpec> all = [
    streamingZipformerEn20M,
    whisperTiny,
    whisperBase,
  ];

  /// The spec with [id], or null if the catalog has no such entry — which is
  /// what a directory left behind by an older build looks like.
  static ModelSpec? byId(String id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  /// `SettingsService.whisperModelSize` reduced to a size this catalog has,
  /// so a stale or corrupted preference cannot leave the app with no model.
  ///
  /// Callers that build file names out of the size — `WhisperService` opens
  /// `<size>-encoder.onnx` — must go through this rather than the raw
  /// preference, or they would look for `small-encoder.onnx` inside the tiny
  /// model's directory.
  static String whisperSize(String size) => size == 'base' ? 'base' : 'tiny';

  /// The Whisper model for `SettingsService.whisperModelSize` (`'tiny'` or
  /// `'base'`), via [whisperSize].
  static ModelSpec whisper(String size) {
    return whisperSize(size) == 'base' ? whisperBase : whisperTiny;
  }

  /// The model the streaming (Sherpa) transcription mode uses.
  static ModelSpec get defaultStreaming => streamingZipformerEn20M;
}
