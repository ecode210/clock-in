import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/supabase_providers.dart';

/// Which slice of the app the current visitor belongs in. Derived rather than
/// stored, so a role change or sign-out takes effect on the next rebuild.
enum AppStage {
  /// Session restored but the profile has not arrived yet.
  loading,
  signedOut,

  /// Signed in, but the organisation has no administrator yet: the first
  /// account to arrive can claim the role with the setup code.
  firstRunSetup,

  /// Signed in with a profile that no administrator has activated. Accounts
  /// created by someone signing themselves up land here.
  awaitingApproval,

  /// Signed in with a password an administrator issued and has seen. Nothing
  /// else opens until it has been replaced.
  mustChangePassword,

  staff,
  admin,
}

final appStageProvider = Provider<AppStage>((ref) {
  if (ref.watch(currentUserIdProvider) == null) return AppStage.signedOut;

  final profile = ref.watch(myProfileProvider);
  final adminExists = ref.watch(adminExistsProvider);

  if (profile.isLoading || adminExists.isLoading) return AppStage.loading;

  final me = profile.value;
  if (me == null) return AppStage.loading;

  // Claiming the first admin role comes before everything else: an
  // organisation with nobody to administer it cannot resolve any other state.
  if (!(me.isAdmin && me.isActive) && adminExists.value == false) {
    return AppStage.firstRunSetup;
  }

  if (!me.isActive) return AppStage.awaitingApproval;
  if (me.mustChangePassword) return AppStage.mustChangePassword;
  if (me.isAdmin) return AppStage.admin;

  return AppStage.staff;
});
