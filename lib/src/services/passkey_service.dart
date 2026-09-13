// The passkey APIs are marked experimental upstream; this app opts into them
// deliberately as one of its two anti-buddy-punching measures.
// ignore_for_file: experimental_member_use

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/exceptions.dart' as pk;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_error.dart';
import '../core/dev_log.dart';
import 'supabase_providers.dart';

/// Wraps Supabase's WebAuthn support. A passkey ties a staff member's login to
/// the biometrics on their own device, so credentials cannot simply be handed
/// to a colleague to clock in on their behalf.
///
/// An account holds one passkey. Registering a second, or removing the one
/// that is there, is refused by triggers on the credential table, so neither
/// this class nor the UI offers a way to do it; only an administrator can,
/// through `reset_staff_passkey`.
class PasskeyService {
  PasskeyService(this._client);

  final SupabaseClient _client;
  final PasskeyAuthenticator _authenticator = PasskeyAuthenticator();

  GoTrueClient get _auth => _client.auth;

  Future<bool> isSupportedOnThisDevice() async {
    try {
      final availability = await _authenticator.getAvailability().web();
      return availability.hasPasskeySupport;
    } catch (_) {
      return false;
    }
  }

  Future<List<Passkey>> list() async {
    try {
      return await _auth.passkey.list();
    } catch (error) {
      // A JWT can still look signed-in after Auth has deleted the session
      // (for example after an admin password change). Drop the zombie session
      // so the router sends the person back to sign in instead of spinning.
      if (_isDeadSession(error)) {
        try {
          await _auth.signOut();
        } catch (signOutError, stack) {
          logFail('passkey.list_signout', signOutError, stack);
        }
      }
      throw _translate(error);
    }
  }

  bool _isDeadSession(Object error) {
    if (error is! AuthException) return false;
    final code = error.code ?? '';
    final message = error.message.toLowerCase();
    return code == 'session_not_found' ||
        code == 'session_expired' ||
        code == 'refresh_token_not_found' ||
        message.contains('session_not_found') ||
        message.contains('session from session_id');
  }

  Future<Passkey> register({String? friendlyName}) async {
    logAction('passkey.register', {'name': friendlyName});
    try {
      final passkey = await _auth.registerPasskey(
        _authenticator,
        friendlyName: friendlyName,
      );
      logDone('passkey.register');
      return passkey;
    } catch (error) {
      throw _translate(error, action: 'passkey.register');
    }
  }

  /// Signs in from the login screen with no email typed in: the authenticator
  /// resolves the account from the credential it holds.
  Future<AuthResponse> signIn() async {
    logAction('passkey.ceremony');
    try {
      final response = await _auth.signInWithPasskey(_authenticator);
      logDone('passkey.ceremony', {'user': response.user?.email});
      return response;
    } catch (error) {
      throw _translate(error, action: 'passkey.ceremony');
    }
  }

  /// Re-runs the biometric ceremony for an already signed-in user so the new
  /// access token carries a fresh WebAuthn entry in its `amr` claim, which the
  /// `clock_in` function checks.
  ///
  /// The ceremony is a full sign-in, and the prompt offers every passkey the
  /// device holds for this site: biometrics unlock the keychain, not one
  /// account. GoTrue then swaps the session before returning, so choosing a
  /// colleague's passkey would sign this device in as them and clock them in
  /// with a genuinely verified check. A mismatch therefore puts the original
  /// session back before failing.
  Future<void> reauthenticate({required String expectedUserId}) async {
    final previous = _auth.currentSession;

    final response = await signIn();
    final signedInId = response.user?.id;
    if (signedInId == expectedUserId) return;

    await _restore(previous);

    if (signedInId == null) {
      throw const AppError(
        'Passkey verification did not complete.',
        code: 'passkey_failed',
      );
    }
    throw const AppError(
      'That passkey belongs to a different account. Use your own passkey, or '
      'sign in as that person to clock them in.',
      code: 'passkey_wrong_account',
    );
  }

  /// Undoes the session swap a mismatched ceremony leaves behind. Signing out
  /// is the fallback, because staying signed in as someone else is the one
  /// outcome that must not survive this method.
  Future<void> _restore(Session? previous) async {
    logAction('passkey.restore');
    final refreshToken = previous?.refreshToken;

    if (refreshToken != null) {
      try {
        // Bounded because this runs while someone waits at the door: a stalled
        // restore must fall through to the sign-out below, not hang the
        // clock-in screen on its spinner.
        await _auth
            .setSession(refreshToken, accessToken: previous!.accessToken)
            .timeout(const Duration(seconds: 8));
        logDone('passkey.restore');
        return;
      } catch (error, stack) {
        logFail('passkey.restore', error, stack);
      }
    }

    try {
      await _auth.signOut();
    } catch (error, stack) {
      logFail('passkey.restore_signout', error, stack);
    }
  }

  AppError _translate(Object error, {String action = 'passkey'}) {
    logFail(action, error);

    if (error is pk.AuthenticatorException) {
      return _authenticatorError(error);
    }

    // On web the passkeys plugin rethrows unmapped browser codes as a raw
    // PlatformException instead of wrapping them as AuthenticatorException.
    if (error is PlatformException) {
      return _ceremonyCodeError(error.code, error.message, error.details);
    }

    if (error is AuthException) {
      // The one-passkey rule is enforced by a trigger, so it reaches us as a
      // database failure rather than as a code GoTrue knows about.
      if (error.message.contains('already has a passkey')) {
        return const AppError(
          'This account already has a passkey. Ask an administrator to reset '
          'it before setting one up on another device.',
          code: 'passkey_already_registered',
        );
      }
      return toAppError(error);
    }

    final mapped = toAppError(error);
    if (mapped.code == 'offline') return mapped;
    return AppError(
      'Passkey verification could not be completed. Use the passkey you set '
      'up for this account, or try again.',
      code: 'passkey_failed',
      technical: error.toString(),
    );
  }

  AppError _authenticatorError(pk.AuthenticatorException error) {
    return switch (error) {
      pk.PasskeyAuthCancelledException() => const AppError(
        'Passkey verification was cancelled.',
        code: 'passkey_cancelled',
      ),
      pk.NoCredentialsAvailableException() => const AppError(
        'No passkey for this app is available on this device. Sign in with '
        'your password, then add a passkey from Settings.',
        code: 'passkey_not_registered',
      ),
      pk.DeviceNotSupportedException() ||
      pk.PasskeyUnsupportedException() => const AppError(
        'This device or browser does not support passkeys.',
        code: 'passkey_unsupported',
      ),
      pk.TimeoutException() => const AppError(
        'The passkey prompt timed out. Please try again.',
        code: 'passkey_expired',
      ),
      pk.DomainNotAssociatedException() => const AppError(
        'Passkeys are not configured for this domain yet. Ask your '
        'administrator to check the passkey settings.',
        code: 'passkey_domain',
      ),
      pk.MissingGoogleSignInException() => const AppError(
        'Sign in to your Google account on this device, then try the '
        'passkey again.',
        code: 'passkey_google_signin',
      ),
      pk.SyncAccountNotAvailableException() => const AppError(
        'This device could not reach the account that stores your passkeys. '
        'Check that you are signed in to Google, then try again.',
        code: 'passkey_sync_account',
      ),
      pk.ExcludeCredentialsCanNotBeRegisteredException() => const AppError(
        'A passkey for this account is already on this device.',
        code: 'passkey_exists',
      ),
      pk.NoCreateOptionException() => const AppError(
        'This device has no passkey provider available. Enable passkeys in '
        'the device settings, then try again.',
        code: 'passkey_no_provider',
      ),
      pk.UnhandledAuthenticatorException(
        :final code,
        :final message,
        :final details,
      ) =>
        _ceremonyCodeError(code, message, details),
      _ => AppError(
        'Passkey verification could not be completed. Use the passkey you '
        'set up for this account, or try again.',
        code: 'passkey_failed',
        technical: error.toString(),
      ),
    };
  }

  /// Maps browser and plugin ceremony codes that never become a typed
  /// [pk.AuthenticatorException] on web.
  AppError _ceremonyCodeError(String code, String? message, Object? details) {
    final key = code.toLowerCase();
    final technical = [code, message, details].whereType<Object>().join(' ');

    if (key == 'cancelled' ||
        key == 'cancelled-by-user' ||
        key == 'notallowederror' ||
        key == 'aborterror' ||
        key == 'suppressed') {
      return AppError(
        'Passkey verification was cancelled or this device rejected it. '
        'Try again with your own passkey.',
        code: 'passkey_cancelled',
        technical: technical,
      );
    }
    if (key.contains('timeout')) {
      return AppError(
        'The passkey prompt timed out. Please try again.',
        code: 'passkey_expired',
        technical: technical,
      );
    }
    if (key == 'no-credentials-available' || key == 'android-no-credential') {
      return AppError(
        'No passkey for this app is available on this device. Sign in with '
        'your password, then add a passkey from Settings.',
        code: 'passkey_not_registered',
        technical: technical,
      );
    }
    if (key.contains('unsupported') ||
        key == 'devicenotsupported' ||
        key == 'notsupportederror') {
      return AppError(
        'This device or browser does not support passkeys.',
        code: 'passkey_unsupported',
        technical: technical,
      );
    }
    if (key == 'domain-not-associated') {
      return AppError(
        'Passkeys are not configured for this domain yet. Ask your '
        'administrator to check the passkey settings.',
        code: 'passkey_domain',
        technical: technical,
      );
    }
    if (key == 'securityerror') {
      return AppError(
        'This browser blocked the passkey check. Use a secure connection '
        'and try again.',
        code: 'passkey_blocked',
        technical: technical,
      );
    }
    if (key == 'invalidstateerror') {
      return AppError(
        'That passkey could not be used. Try again, or pick the one you '
        'set up for this account.',
        code: 'passkey_invalid_state',
        technical: technical,
      );
    }

    return AppError(
      'That passkey could not be verified. Use the passkey you set up for '
      'this account, then try again.',
      code: 'passkey_rejected',
      technical: technical,
    );
  }
}

final passkeyServiceProvider = Provider<PasskeyService>(
  (ref) => PasskeyService(ref.watch(supabaseClientProvider)),
);

final myPasskeysProvider = FutureProvider<List<Passkey>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Future.value(const []);
  return ref.watch(passkeyServiceProvider).list();
});
