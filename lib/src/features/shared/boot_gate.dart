import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_error.dart';
import '../../routing/app_stage.dart';
import '../../services/supabase_providers.dart';
import 'widgets.dart';

/// Covers the whole app while the restored session's profile is being loaded,
/// so the router never renders a screen for a role it does not know yet.
class BootGate extends ConsumerWidget {
  const BootGate({required this.child, super.key});

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stage = ref.watch(appStageProvider);
    if (stage != AppStage.loading) {
      return child ?? const SizedBox.shrink();
    }

    final profile = ref.watch(myProfileProvider);
    final settingsError = ref.watch(adminExistsProvider).error;
    final error = profile.error ?? settingsError;

    if (error != null) {
      return _StartupFailure(error: error);
    }

    // A signed-in session with no profile row means the mirroring trigger did
    // not run for this account; retrying will not help, so offer a way out.
    if (!profile.isLoading && profile.value == null) {
      return const _StartupFailure(
        error: AppError(
          'This account has no staff profile. Ask an administrator to '
          're-create it.',
        ),
      );
    }

    return AppScaffold(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FLucideIcons.clock,
              size: 40,
              color: context.theme.colors.primary,
            ),
            const SizedBox(height: 20),
            const FCircularProgress(),
          ],
        ),
      ),
    );
  }
}

class _StartupFailure extends ConsumerWidget {
  const _StartupFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AuthPage(
    icon: FLucideIcons.triangleAlert,
    title: 'Could not start the app',
    subtitle: errorMessage(error),
    children: [
      FButton(
        onPress: () {
          ref.invalidate(myProfileProvider);
          ref.invalidate(adminExistsProvider);
        },
        prefix: const Icon(FLucideIcons.refreshCw),
        child: const ButtonLabel('Try again'),
      ),
      const SizedBox(height: 10),
      FButton(
        variant: FButtonVariant.outline,
        onPress: () => Supabase.instance.client.auth.signOut(),
        child: const ButtonLabel('Sign out'),
      ),
    ],
  );
}
