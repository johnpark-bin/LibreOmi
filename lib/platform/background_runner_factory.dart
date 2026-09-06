/// Picks the [BackgroundRunner] implementation for the running platform.
library;

import 'dart:io' show Platform;

import 'android_foreground_runner.dart';
import 'background_runner.dart';
import 'noop_background_runner.dart';

/// Returns the runner for this platform: the foreground-service backed one on
/// Android, an inert one everywhere else.
///
/// Like `permission_gateway.dart` and `battery_optimization_gateway.dart`,
/// this file is allowed to branch on `Platform` (see `AGENTS.md`); keeping the
/// branch here means `controllers/`, `device/`, `audio/` and `transcription/`
/// never need one.
BackgroundRunner createBackgroundRunner() =>
    Platform.isAndroid ? AndroidForegroundRunner() : NoopBackgroundRunner();
