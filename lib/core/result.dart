/// A minimal `Result<T>` type for representing an operation that either
/// succeeds with a value or fails with a message and an optional cause.
///
/// This is pure Dart (no Flutter import) so it can be used from `device/`,
/// `audio/`, `transcription/`, and `intelligence/` without pulling in the
/// Flutter SDK. See docs/03-architecture.md §1 (`core/`).
library;

/// The result of an operation that can either succeed with a value of type
/// [T] or fail with an error message.
///
/// Use [Success] and [Failure] to construct instances, and [fold] (or the
/// [isSuccess] / [isFailure] / [valueOrNull] accessors) to consume them.
sealed class Result<T> {
  const Result();

  /// Whether this result is a [Success].
  bool get isSuccess => this is Success<T>;

  /// Whether this result is a [Failure].
  bool get isFailure => this is Failure<T>;

  /// The success value, or `null` if this is a [Failure].
  T? get valueOrNull => switch (this) {
        Success<T>(:final value) => value,
        Failure<T>() => null,
      };

  /// Reduces this result to a single value of type [R] by invoking
  /// [onSuccess] with the success value or [onFailure] with the failure
  /// message and cause.
  R fold<R>({
    required R Function(T value) onSuccess,
    required R Function(String message, Object? cause) onFailure,
  }) {
    return switch (this) {
      Success<T>(:final value) => onSuccess(value),
      Failure<T>(:final message, :final cause) => onFailure(message, cause),
    };
  }
}

/// A successful [Result] holding the produced [value].
final class Success<T> extends Result<T> {
  /// Creates a successful result wrapping [value].
  const Success(this.value);

  /// The value produced by the operation.
  final T value;
}

/// A failed [Result] holding a human-readable [message] and an optional
/// [cause] (typically the caught exception or error).
final class Failure<T> extends Result<T> {
  /// Creates a failed result with [message] and an optional [cause].
  const Failure(this.message, {this.cause});

  /// A human-readable description of the failure.
  final String message;

  /// The underlying exception/error that caused the failure, if any.
  final Object? cause;
}
