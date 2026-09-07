/// Pure-Dart background-session logic, importable from `flutter test` without
/// touching any plugin channel. See `docs/03-architecture.md` §2 and §5 for the
/// `BackgroundRunner` design this file supports, and
/// `docs/04-android-platform-notes.md` §3/§4 for the Android foreground-service
/// rules it encodes.
library;

/// Why a foreground service is needed right now. Maps 1:1 onto Android
/// `foregroundServiceType` values declared in the manifest.
enum BackgroundReason {
  /// A Bluetooth device (the Omi wearable) is connected and streaming audio.
  connectedDevice,

  /// The phone's own microphone is being recorded.
  microphone,
}

/// Returns [reasons] in the stable order the Android service types are
/// declared in: `connectedDevice` before `microphone`.
///
/// Callers that have to translate a reason into a plugin constant go through
/// this instead of iterating the set, so the order is defined in one place and
/// the translation stays an exhaustive switch.
List<BackgroundReason> orderedBackgroundReasons(Set<BackgroundReason> reasons) {
  return <BackgroundReason>[
    for (final reason in BackgroundReason.values)
      if (reasons.contains(reason)) reason,
  ];
}

/// Returns the manifest-style `foregroundServiceType` names for [reasons], in
/// the order of [orderedBackgroundReasons], e.g. `['connectedDevice']` or
/// `['connectedDevice', 'microphone']`. An empty set returns an empty list.
List<String> androidForegroundServiceTypes(Set<BackgroundReason> reasons) {
  return orderedBackgroundReasons(reasons)
      .map((reason) => switch (reason) {
            BackgroundReason.connectedDevice => 'connectedDevice',
            BackgroundReason.microphone => 'microphone',
          })
      .toList(growable: false);
}

/// True iff [reasons] contains [BackgroundReason.microphone].
///
/// From Android 14 (API 34) a `microphone`-type foreground service may only
/// be started while the app is in the foreground (see
/// `docs/04-android-platform-notes.md` §3/§4) — starting one from a
/// background callback throws. So a phone-mic session must always begin from
/// a foreground UI action (a button tap), never from a background callback.
bool requiresForegroundStart(Set<BackgroundReason> reasons) {
  return reasons.contains(BackgroundReason.microphone);
}

/// Formats [duration] as the persistent-notification duration string:
/// `mm:ss` (zero-padded) below one hour, e.g. `00:07`, `12:34`; `h:mm:ss` at
/// or above one hour, e.g. `1:02:03`. Negative durations clamp to `00:00`.
String formatConversationLength(Duration duration) {
  if (duration.isNegative) {
    return '00:00';
  }
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$mm:$ss';
  }
  return '$mm:$ss';
}

/// The three translated words [SessionNotificationText.forSession] picks
/// between, passed in rather than looked up (LO-62).
///
/// This file stays pure Dart — no plugin channel, no widget tree — so it
/// cannot reach `AppLocalizations` itself, and `lib/platform/` would gain a
/// `flutter/widgets` import it does not otherwise have. The caller that has
/// the locale supplies the words instead.
///
/// The English default exists for callers with no locale to hand — the unit
/// tests here, and any future call from an isolate where the resolved locale
/// and the settings store are both unset. Every production path runs in the
/// main isolate and passes translated labels.
class SessionNotificationLabels {
  const SessionNotificationLabels({
    this.phoneMic = 'Phone mic',
    this.omiConnected = 'Omi connected',
    this.omiDisconnected = 'Omi disconnected',
  });

  final String phoneMic;
  final String omiConnected;
  final String omiDisconnected;
}

/// The title/text shown on the persistent foreground-service notification.
class SessionNotificationText {
  const SessionNotificationText({required this.title, required this.text});

  /// Builds the notification text for the current session state.
  ///
  /// The source part is [SessionNotificationLabels.phoneMic] when
  /// [usingPhoneMic] is true; otherwise
  /// [SessionNotificationLabels.omiConnected] when [deviceConnected] is true,
  /// or [SessionNotificationLabels.omiDisconnected] when it is false. The full
  /// text is `'<source> · <duration>'`, where duration is formatted by
  /// [formatConversationLength].
  factory SessionNotificationText.forSession({
    required bool usingPhoneMic,
    required bool deviceConnected,
    required Duration conversationLength,
    SessionNotificationLabels labels = const SessionNotificationLabels(),
  }) {
    final String source;
    if (usingPhoneMic) {
      source = labels.phoneMic;
    } else if (deviceConnected) {
      source = labels.omiConnected;
    } else {
      source = labels.omiDisconnected;
    }
    final duration = formatConversationLength(conversationLength);
    return SessionNotificationText(
      // Not localised: the product name is the same in every language.
      title: 'LibreOmi',
      text: '$source · $duration',
    );
  }

  final String title;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SessionNotificationText &&
      other.title == title &&
      other.text == text;

  @override
  int get hashCode => Object.hash(title, text);

  @override
  String toString() => 'SessionNotificationText(title: $title, text: $text)';
}

/// Decides when an [SessionNotificationText] update is worth actually
/// pushing to the OS, so the persistent notification is not rewritten on
/// every transcript segment.
///
/// The current time is passed into [next] rather than read from a clock, so
/// this class can be tested deterministically without faking time globally.
class SessionNotificationThrottle {
  SessionNotificationThrottle({
    this.minInterval = const Duration(seconds: 30),
  });

  final Duration minInterval;

  SessionNotificationText? _lastPushed;
  DateTime? _lastPushedAt;

  /// Returns [candidate] when it should be pushed now, otherwise `null`.
  ///
  /// Pushes when: nothing has been pushed yet; [minInterval] has elapsed
  /// since the last push; or the "source" part of the text (everything
  /// before the duration) differs from the last pushed value, in which case
  /// it pushes immediately regardless of the interval. When only the
  /// duration changed, it respects [minInterval]. The push time is recorded
  /// only when this returns non-null.
  SessionNotificationText? next(SessionNotificationText candidate, DateTime now) {
    final lastPushed = _lastPushed;
    final lastPushedAt = _lastPushedAt;

    if (lastPushed == null || lastPushedAt == null) {
      _lastPushed = candidate;
      _lastPushedAt = now;
      return candidate;
    }

    final sourceChanged =
        candidate.title != lastPushed.title || _sourcePart(candidate.text) != _sourcePart(lastPushed.text);
    final intervalElapsed = now.difference(lastPushedAt) >= minInterval;

    if (sourceChanged || intervalElapsed) {
      _lastPushed = candidate;
      _lastPushedAt = now;
      return candidate;
    }

    return null;
  }

  /// Clears state so a new session starts fresh (the next [next] call will
  /// always push).
  void reset() {
    _lastPushed = null;
    _lastPushedAt = null;
  }

  static String _sourcePart(String text) {
    final separatorIndex = text.indexOf('·');
    return separatorIndex == -1 ? text : text.substring(0, separatorIndex);
  }
}
