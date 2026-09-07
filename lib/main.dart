import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'services/settings_service.dart';
import 'services/notification_service.dart'; // Added
import 'platform/permission_gateway.dart';
import 'controllers/chat_controller.dart';
import 'controllers/device_controller.dart';
import 'controllers/library_controller.dart';
import 'controllers/sdcard_controller.dart';
import 'controllers/session_controller.dart';
import 'device/device_manager.dart';
import 'l10n/l10n.dart';
import 'l10n/locale_controller.dart';
import 'pages/home_page.dart';
import 'pages/permissions_rationale_page.dart';
import 'transcription/model_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Initialize settings
    await SettingsService.init();

    // Initialize notifications
    await NotificationService().initialize();
  } catch (e) {
    debugPrint('Settings init error: $e');
  }

  final showRationale = shouldShowRationale();

  runApp(LibreOmiApp(showRationale: showRationale));

  // On first launch the permissions & privacy screen goes first and the
  // request waits until the user has read it (docs/08 §8): Play's prominent
  // disclosure has to precede the permission dialog, not race it.
  if (!showRationale) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(requestLaunchPermissions()),
    );
  }
}

/// Whether this launch should open the permissions & privacy screen instead
/// of the home page (LO-64). Shown once; the screen sets the flag itself.
///
/// A settings store that failed to initialise errs towards showing it: the
/// disclosure appearing twice is harmless, silently skipping it is not.
bool shouldShowRationale() {
  try {
    return !SettingsService.rationaleShown;
  } catch (e) {
    debugPrint('Rationale flag unreadable, showing the screen: $e');
    return true;
  }
}

/// Notifications are the only permission requested at launch (docs/04 §3):
/// every notification the app posts, including the persistent session one,
/// needs it from Android 13 on. BLE and microphone are requested at the point
/// of use instead. Called after the first frame so the dialog has an attached
/// activity, and never awaited by the caller: a denial only means the user
/// gets no notifications, which must not block the UI from coming up.
Future<void> requestLaunchPermissions() async {
  try {
    await appPermissions.ensureNotifications();
  } catch (e) {
    debugPrint('Notification permission request failed: $e');
  }
}

class LibreOmiApp extends StatefulWidget {
  const LibreOmiApp({super.key, this.showRationale = false});

  /// Whether to open on the permissions & privacy screen. Captured once at
  /// startup so the flag flipping mid-session cannot swap the root screen
  /// under the user.
  final bool showRationale;

  @override
  State<LibreOmiApp> createState() => _LibreOmiAppState();
}

class _LibreOmiAppState extends State<LibreOmiApp> {
  late bool _showRationale;
  late final LocaleController _locale;
  late final DeviceManager _deviceManager;
  late final LibraryController _library;
  late final ChatController _chat;
  late final SessionController _session;
  late final DeviceController _device;
  late final SdCardController _sdCard;

  @override
  void initState() {
    super.initState();

    _showRationale = widget.showRationale;
    _locale = LocaleController();
    _deviceManager = createDeviceManager();
    _library = LibraryController();
    _chat = ChatController(library: _library);
    _session = SessionController(
      deviceManager: _deviceManager,
      library: _library,
      chat: _chat,
    );
    _device = DeviceController(deviceManager: _deviceManager, session: _session);
    // `DeviceController` owns the auto-reconnect flag and the backoff ladder
    // and depends on the session rather than the other way round, so the
    // audio self-test's "connect to my saved device" is wired here.
    _session.ensureSavedDeviceConnection = _device.scanAndConnectToSavedDevice;
    _sdCard = SdCardController(
      syncService: () => _device.sdCardSyncService,
      hasStorage: () => _device.hasStorageSupport,
      processFile: _session.processLocalAudioFile,
      deviceChanges: _device,
      onConversationImported: _library.reloadAll,
    );

    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    // Nothing is recording yet, so any foreground service still up belongs to
    // a previous process that did not shut down cleanly. Reap it, otherwise a
    // notification claiming to record would survive with no session behind
    // it. Awaited on purpose: it has to finish before the device-state
    // listener `_device.init()` wires up can start a session, or the reap
    // could take that session's service down instead.
    await _session.reapStaleBackgroundService();

    try {
      // Connection-state + button subscriptions, then the first reconnect
      // schedule.
      await _device.init();

      // Load saved conversations, memories, and tasks
      await _library.loadConversations();
      await _library.loadMemories();
      await _library.loadTasks();

      // New in LO-34: chat history is persisted.
      await _chat.load();

      // One-time LO-40 migration: moves any pre-LO-40 model downloads out of
      // the backed-up documents directory and into the models store's own,
      // excluded-from-backup directory (docs/04-android-platform-notes.md
      // §8). Its own try/catch, not the outer one: a model that cannot be
      // moved is a cosmetic problem, and it must not skip the session init
      // and finalization drain below.
      try {
        final store = ModelStore();
        await store.migrateLegacyInstalls();
        // Startup is the one moment no install can be in flight, so it is
        // also the only safe moment to drop scratch left by a download the
        // OS killed halfway.
        await store.clearScratch();
      } catch (e) {
        debugPrint('Model migration error: $e');
      }

      // Deliberately after the loads: the finalization queue lives entirely
      // in the database, so starting it before storage has proven usable
      // would only arm a timer with nothing to drain. Anything left over
      // from a previous process (killed mid-retry, or queued while offline)
      // is picked up by this first drain. See `SessionController.init()`.
      await _session.init();
    } catch (e) {
      debugPrint('App init error: $e');
    }
  }

  @override
  void dispose() {
    // The session's teardown closes the audio transport, which reaches back
    // into the device manager (via `_device.dispose()`), so it must go down
    // first. `_sdCard` listens to `_device`, so it must go down before it.
    _session.dispose();
    _sdCard.dispose();
    _device.dispose();
    _chat.dispose();
    _library.dispose();
    _locale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryController>.value(value: _library),
        ChangeNotifierProvider<ChatController>.value(value: _chat),
        ChangeNotifierProvider<SessionController>.value(value: _session),
        ChangeNotifierProvider<DeviceController>.value(value: _device),
        ChangeNotifierProvider<SdCardController>.value(value: _sdCard),
        ChangeNotifierProvider<LocaleController>.value(value: _locale),
      ],
      child: Consumer<LocaleController>(
        builder: (context, locale, _) => _buildApp(locale),
      ),
    );
  }

  Widget _buildApp(LocaleController locale) {
    return MaterialApp(
      // Not localised: the product name is the same in every language.
      title: 'LibreOmi',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // `null` means follow the system language, which is what
      // `LocaleController` stores for the default setting.
      locale: locale.appLocale,
      // Flutter hands this the `locale` above when it is set and the device
      // locale otherwise, so it is the one place that sees the locale the
      // UI actually renders in. Recording it lets `L10n.current` answer for
      // the notification and controller strings that have no context.
      localeResolutionCallback: (candidate, supported) {
        final resolved = L10n.resolve(candidate);
        L10n.locale = resolved;
        return resolved;
      },
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(
          0xFF0A0A0A,
        ), // Deep premium black
        primaryColor: const Color(0xFF6C5CE7), // Vivid violet
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C5CE7),
          secondary: Color(0xFFA29BFE), // Soft purple
          surface: Color(0xFF1E1E1E), // Slightly lighter card bg
          background: Color(0xFF0A0A0A),
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1E1E1E),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withOpacity(0.05)),
          ),
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6C5CE7),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFFA29BFE),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E1E1E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.05)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF6C5CE7)),
          ),
          contentPadding: const EdgeInsets.all(16),
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF2D2D2D),
          contentTextStyle: const TextStyle(color: Colors.white),
          actionTextColor: const Color(0xFFA29BFE),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        dropdownMenuTheme: DropdownMenuThemeData(
          menuStyle: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(const Color(0xFF2D2D2D)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        popupMenuTheme: const PopupMenuThemeData(color: Color(0xFF2D2D2D)),
        useMaterial3: true,
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: _showRationale
          ? PermissionsRationalePage(
              isFirstRun: true,
              onContinue: () {
                setState(() => _showRationale = false);
                // Deferred to here rather than to the first frame so the
                // notification dialog lands after the disclosure the user
                // just read.
                unawaited(requestLaunchPermissions());
              },
            )
          : const HomePage(),
      builder: (context, child) {
        return Stack(
          children: [if (child != null) child, const ListeningOverlay()],
        );
      },
    );
  }
}

class ListeningOverlay extends StatelessWidget {
  const ListeningOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionController>(
      builder: (context, session, child) {
        if (!session.isHoldToAskActive) return const SizedBox.shrink();

        return Material(
          color: Colors.black.withOpacity(0.7),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).primaryColor.withOpacity(0.5),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.mic, color: Colors.white, size: 48),
                ),
                const SizedBox(height: 24),
                Text(
                  L10n.of(context).overlay_listening_title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  L10n.of(context).overlay_listening_hint,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 16,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
