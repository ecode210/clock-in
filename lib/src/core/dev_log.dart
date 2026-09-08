import 'package:flutter/foundation.dart';

/// Development logging for user-initiated actions.
///
/// Every call is behind [kDebugMode], so these statements are tree-shaken out
/// of release builds. That matters here: the payloads carry coordinates, staff
/// identifiers and error details that must not reach a production browser
/// console.
///
/// Technical detail belongs here and nowhere else. Anything shown on screen
/// goes through `AppError.message` instead; see `.cursor/rules/`.
const String _tag = 'clock-in';

/// Records that an action was started. Pair with [logDone] or [logFail].
void logAction(String action, [Map<String, Object?>? data]) {
  if (!kDebugMode) return;
  debugPrint('[$_tag] → $action${_render(data)}');
}

/// Records that an action succeeded.
void logDone(String action, [Map<String, Object?>? data]) {
  if (!kDebugMode) return;
  debugPrint('[$_tag] ✓ $action${_render(data)}');
}

/// Records that an action failed, including the technical detail that was
/// deliberately withheld from the user-facing message.
void logFail(String action, Object error, [StackTrace? stack]) {
  if (!kDebugMode) return;
  debugPrint('[$_tag] ✗ $action: $error');
  if (stack != null) debugPrintStack(stackTrace: stack, label: '[$_tag] $action');
}

/// Records a non-fatal oddity worth noticing while developing.
void logNote(String message, [Map<String, Object?>? data]) {
  if (!kDebugMode) return;
  debugPrint('[$_tag] · $message${_render(data)}');
}

String _render(Map<String, Object?>? data) {
  if (data == null || data.isEmpty) return '';
  final pairs = data.entries
      .where((e) => e.value != null)
      .map((e) => '${e.key}=${e.value}')
      .join(' ');
  return pairs.isEmpty ? '' : ' ($pairs)';
}
