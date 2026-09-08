import 'package:supabase_flutter/supabase_flutter.dart';

import 'dev_log.dart';

/// Machine-readable failure reasons, so the UI can react without matching on
/// prose. Most are raised by the database in the `hint` field of its
/// exceptions; the last two are decided here on the client.
class ClockErrorCode {
  const ClockErrorCode._();

  static const outsideGeofence = 'outside_geofence';
  static const geofenceNotConfigured = 'geofence_not_configured';
  static const selfieRequired = 'selfie_required';
  static const selfieMissing = 'selfie_missing';
  static const selfieStale = 'selfie_stale';
  static const passkeyRequired = 'passkey_required';
  static const poorAccuracy = 'poor_accuracy';
  static const alreadyClockedIn = 'already_clocked_in';
  static const alreadyClockedOut = 'already_clocked_out';
  static const notClockedIn = 'not_clocked_in';
  static const accountInactive = 'account_inactive';
  static const adminAlreadyExists = 'admin_already_exists';
  static const missingLocation = 'missing_location';
  static const locationMocked = 'location_mocked';
  static const stepTimeout = 'step_timeout';
  static const interrupted = 'interrupted';
}

/// Shown when the cause is something the user can neither understand nor act
/// on. Deliberately vague on screen; the real cause goes to [logFail].
const String _genericMessage =
    'Something went wrong on our end. Please try again, and contact your '
    'administrator if it keeps happening.';

const String _offlineMessage =
    'Could not reach the server. Check your internet connection and try again.';

/// An error whose [message] is always safe to show to a user.
///
/// [message] is user-facing prose: never a code, status number, SQLSTATE, JSON
/// body or exception class name. [code] is for the app to branch on and
/// [technical] is for logs; neither is ever rendered.
class AppError implements Exception {
  const AppError(this.message, {this.code, this.technical});

  final String message;
  final String? code;
  final String? technical;

  @override
  String toString() => message;
}

/// Normalises the exception types the Supabase SDK throws into an [AppError]
/// with a message fit for the screen.
///
/// Server text is only passed through where it was deliberately written for
/// users: our Postgres functions raise friendly prose and set `hint`, and the
/// `manage-staff` function returns a friendly `error` field. Everything else
/// collapses to a generic message so internal detail cannot leak into the UI.
AppError toAppError(Object error) {
  if (error is AppError) return error;

  if (_isOffline(error)) {
    return const AppError(_offlineMessage, code: 'offline');
  }

  if (error is PostgrestException) {
    if (error.code == '42501' ||
        error.message.contains('row-level security')) {
      return const AppError(
        'You do not have permission to do that.',
        code: 'forbidden',
      );
    }
    // Our functions `raise exception`, which arrives as SQLSTATE P0001 with a
    // message written for staff and `hint` set to a code we chose. PostgREST
    // and Postgres set hints of their own, about foreign keys and column
    // names, so the deliberate raise is what makes a message safe to show.
    final hint = error.hint;
    if (error.code == 'P0001' && hint != null && hint.isNotEmpty) {
      return AppError(error.message, code: hint);
    }
    return AppError(
      _genericMessage,
      code: error.code ?? 'database_error',
      technical: error.message,
    );
  }

  if (error is FunctionException) {
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return AppError(details['error'] as String, code: 'function_error');
    }
    return AppError(
      _genericMessage,
      code: 'function_error',
      technical: 'status ${error.status} ${error.reasonPhrase ?? ''}'.trim(),
    );
  }

  if (error is StorageException) {
    return AppError(
      _storageMessage(error),
      code: error.statusCode,
      technical: error.message,
    );
  }

  if (error is AuthException) {
    return _authError(error);
  }

  return AppError(
    _genericMessage,
    code: 'unknown',
    technical: error.toString(),
  );
}

/// Maps GoTrue failures onto prose. Anything unrecognised is treated as a
/// server fault rather than echoed, since GoTrue messages range from
/// "Invalid login credentials" to raw JSON bodies on a 500.
AppError _authError(AuthException error) {
  final code = error.code ?? '';
  final text = error.message.toLowerCase();

  bool has(String needle) => code == needle || text.contains(needle);

  if (has('invalid_credentials') || text.contains('invalid login credentials')) {
    return const AppError(
      'That email and password combination is not correct.',
      code: 'invalid_credentials',
    );
  }
  if (has('email_not_confirmed')) {
    return const AppError(
      'Confirm your email address before signing in.',
      code: 'email_not_confirmed',
    );
  }
  if (has('user_not_found')) {
    return const AppError(
      'There is no account for that email address.',
      code: 'user_not_found',
    );
  }
  if (has('weak_password')) {
    return const AppError(
      'That password is too easy to guess. Use at least 8 characters with a '
      'mix of letters and numbers.',
      code: 'weak_password',
    );
  }
  if (has('same_password')) {
    return const AppError(
      'That is already your current password. Choose a different one.',
      code: 'same_password',
    );
  }
  if (has('signup_disabled') || has('email_provider_disabled')) {
    return const AppError(
      'New accounts cannot be created here. Ask your administrator to add you.',
      code: 'signup_disabled',
    );
  }
  if (has('rate_limit') || has('over_request_rate_limit') ||
      error.statusCode == '429') {
    return const AppError(
      'Too many attempts. Wait a minute and try again.',
      code: 'rate_limited',
    );
  }
  if (has('session_not_found') ||
      has('refresh_token_not_found') ||
      has('session_expired')) {
    return const AppError(
      'Your session has expired. Sign in again to continue.',
      code: 'session_expired',
    );
  }
  if (has('user_banned')) {
    return const AppError(
      'This account has been suspended. Contact your administrator.',
      code: 'user_banned',
    );
  }

  return AppError(
    _genericMessage,
    code: code.isEmpty ? 'auth_error' : code,
    technical: '${error.statusCode ?? ''} ${error.message}'.trim(),
  );
}

String _storageMessage(StorageException error) {
  final text = error.message.toLowerCase();
  if (error.statusCode == '413' || text.contains('too large')) {
    return 'That photo is too large. Try again.';
  }
  if (error.statusCode == '403' || text.contains('unauthorized')) {
    return 'You do not have permission to do that.';
  }
  return 'The photo could not be uploaded. Please try again.';
}

/// Detects a failed request rather than a rejected one. Matched by name and
/// text because the relevant types come from `dart:io` and `package:http`,
/// neither of which this web-only app should import directly.
bool _isOffline(Object error) {
  if (error is AuthRetryableFetchException) return true;

  final name = error.runtimeType.toString();
  if (name == 'ClientException' || name == 'SocketException') return true;

  final text = error.toString().toLowerCase();
  return text.contains('failed to fetch') ||
      text.contains('xmlhttprequest error') ||
      text.contains('connection refused') ||
      text.contains('network is unreachable');
}

/// Runs [request], retrying once if PostgREST rejects the token's `iat` as
/// being in the future.
///
/// GoTrue mints the token and PostgREST validates it with no clock leeway, so
/// a sub-second difference between those two services makes the first request
/// after signing in fail with PGRST303. Waiting out the skew fixes it.
Future<T> withClockSkewRetry<T>(Future<T> Function() request) async {
  try {
    return await request();
  } on PostgrestException catch (error) {
    if (error.code != 'PGRST303') rethrow;
    logNote('retrying after JWT clock skew');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    return request();
  }
}

/// Fails [future] with user-facing prose once [limit] passes.
///
/// The work already sent to the server is not cancelled: it may well land a
/// moment later. This only stops the person waiting on a spinner forever, so
/// every caller must be safe to retry or to leave alone.
Future<T> withStepTimeout<T>(
  Future<T> future, {
  required Duration limit,
  required String message,
  required String code,
}) => future.timeout(
  limit,
  onTimeout: () {
    logFail('step timeout [$code]', 'exceeded ${limit.inSeconds}s');
    throw AppError(message, code: code);
  },
);

/// The user-facing message for [error]. Also records the technical cause, so
/// detail withheld from the screen is still visible while developing.
String errorMessage(Object error) {
  final appError = toAppError(error);
  if (appError.technical != null) {
    logFail('surfaced error [${appError.code}]', appError.technical!);
  }
  return appError.message;
}
