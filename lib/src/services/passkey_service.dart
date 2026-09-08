// The passkey APIs are marked experimental upstream; this app opts into them
// deliberately as one of its two anti-buddy-punching measures.
// ignore_for_file: experimental_member_use

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
      throw _translate(error);
    }
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
      return switch (error) {
        pk.PasskeyAuthCancelledException() => const AppError(
          'Passkey verification was cancelled.',
          code: 'passkey_cancelled',
        ),
        pk.NoCredentialsAvailableException() => const AppError(
          'No passkey for this app is available on this device. Sign in with '
          'your password, then add a passkey from your account page.',
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
        _ => AppError(
          'Passkey verification could not be completed. Please try again, or '
          'sign in with your password instead.',
          code: 'passkey_failed',
          technical: error.toString(),
        ),
      };
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

      return switch (error.code) {
        'passkey_disabled' => const AppError(
          'Passkeys are not enabled for this organisation yet.',
          code: 'passkey_disabled',
        ),
        'webauthn_credential_not_found' => const AppError(
          'This device has no passkey registered for the app. Sign in with '
          'your password, then add a passkey from your account page.',
          code: 'passkey_not_registered',
        ),
        'webauthn_credential_exists' => const AppError(
          'This device already has a passkey registered for your account.',
          code: 'passkey_exists',
        ),
        'webauthn_challenge_expired' => const AppError(
          'The passkey prompt timed out. Please try again.',
          code: 'passkey_expired',
        ),
        _ => toAppError(error),
      };
    }

    return toAppError(error);
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
