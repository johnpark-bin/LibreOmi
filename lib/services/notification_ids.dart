/// Stable notification identifiers for scheduled task reminders.
///
/// Awesome Notifications addresses a scheduled notification by a 32-bit signed
/// integer, so the id has to be derived from something the app already stores.
/// `Task.id` is a v4 UUID string and `String.hashCode` is only stable within a
/// single Dart isolate run, which means a reminder scheduled before a restart
/// could not be cancelled after it — the app would compute a different id for
/// the same task.
///
/// `Task.createdAt` is persisted (`created_at`, milliseconds since epoch) and
/// never changes once a task exists, so it survives restarts and DB reads.
///
/// This is deliberately temporary: LO-35 adds a `notification_id` column to the
/// tasks table and this helper is then replaced by a read of that column.
library;

import '../models/conversation.dart';

/// The notification id used for [task]'s due-date reminder.
///
/// Folds `createdAt` in milliseconds into a positive 31-bit integer. Two
/// consequences worth knowing:
///
/// * The value repeats roughly every 24.8 days (2^31 ms), so two tasks created
///   exactly that far apart share an id. Reminders live for hours or days, not
///   weeks, so the practical collision window is small — and it disappears with
///   LO-35.
/// * Millisecond resolution is kept on purpose. Truncating to seconds would give
///   the same id to every task created inside one summarisation pass, which is
///   exactly the case that produces several tasks at once.
/// * Two tasks created within the same millisecond still collide, and the second
///   reminder would replace the first. Each iteration of that pass awaits a
///   duplicate check, an insert and a platform-channel call, so landing in one
///   millisecond is improbable; LO-35 removes the risk entirely.
int notificationIdForTask(Task task) =>
    task.createdAt.millisecondsSinceEpoch & 0x7fffffff;
