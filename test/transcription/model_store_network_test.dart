@Tags(['network'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/model_store.dart';

/// Installs a real catalog model from the real release URL.
///
/// Skipped unless `LIBREOMI_NETWORK_TESTS=1`, because it downloads ~122 MB
/// and CI has neither the time nor the bandwidth budget for it
/// (`docs/08-dev-workflow.md` §2). Run it by hand after changing the catalog
/// or the extraction path:
///
/// ```bash
/// LIBREOMI_NETWORK_TESTS=1 mise exec -- flutter test -t network \
///   test/transcription/model_store_network_test.dart
/// ```
///
/// Everything lands in the git-ignored `.tmp/` directory inside the checkout,
/// not in the system temp directory, so a run that dies halfway leaves the
/// evidence where it can be found and deleted.
void main() {
  final enabled = Platform.environment['LIBREOMI_NETWORK_TESTS'] == '1';

  test(
    'installs the streaming zipformer from its real release URL',
    () async {
      final spec = ModelCatalog.defaultStreaming;
      final support = Directory('${Directory.current.path}/.tmp/network-test')
        ..createSync(recursive: true);
      addTearDown(() => support.deleteSync(recursive: true));

      final store = ModelStore(supportDirectory: () async => support);
      final started = DateTime.now();
      var lastReported = 0;

      await for (final progress in store.install(spec)) {
        if (progress.phase == ModelInstallPhase.downloading &&
            progress.receivedBytes - lastReported > 16 * 1024 * 1024) {
          lastReported = progress.receivedBytes;
          // ignore: avoid_print
          print('downloaded ${progress.receivedBytes} / '
              '${progress.totalBytes} bytes');
        } else if (progress.phase != ModelInstallPhase.downloading) {
          // ignore: avoid_print
          print('phase ${progress.phase.name} at '
              '${DateTime.now().difference(started).inSeconds}s');
        }
      }

      expect(await store.isInstalled(spec), isTrue);
      final dir = await store.installedDir(spec);
      for (final relative in spec.requiredFiles) {
        final file = File('${dir.path}/$relative');
        expect(file.existsSync(), isTrue, reason: relative);
        // ignore: avoid_print
        print('$relative: ${file.lengthSync()} bytes');
      }
      // Only the required files, so the install is far smaller than the
      // archive it came from.
      expect(dir.listSync(recursive: true).whereType<File>().length,
          spec.requiredFiles.length);

      final onDisk = await store.sizeOnDisk(spec);
      // ignore: avoid_print
      print('installed $onDisk bytes in '
          '${DateTime.now().difference(started).inSeconds}s '
          '(catalog estimate ${spec.installedBytes})');
      expect(onDisk, spec.installedBytes);
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: enabled
        ? false
        : 'Downloads ~122 MB. Set LIBREOMI_NETWORK_TESTS=1 to run.',
  );
}
