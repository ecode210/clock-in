import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

/// Shown to accounts that exist but have not been activated. Anyone who
/// registers themselves rather than being added by an administrator ends up
/// here, and cannot clock in until someone activates them.
class AwaitingApprovalScreen extends ConsumerWidget {
  const AwaitingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myProfileProvider).value;

    return AuthPage(
      icon: FLucideIcons.hourglass,
      title: 'Waiting for approval',
      subtitle:
          'Your account exists but has not been activated yet. Ask your '
          'administrator to activate it, then check again.',
      maxWidth: 420,
      children: [
        if (me?.email != null) ...[
          FTileGroup(
            children: [
              FTile(
                prefix: const TileIcon(FLucideIcons.mail),
                title: Text(me!.email!),
                subtitle: Text(
                  me.fullName.isEmpty ? 'No name set' : me.fullName,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        FButton(
          onPress: () {
            ref.invalidate(myProfileProvider);
            ref.invalidate(adminExistsProvider);
          },
          prefix: const Icon(FLucideIcons.refreshCw),
          child: const ButtonLabel('Check again'),
        ),
        const SizedBox(height: 10),
        FButton(
          variant: FButtonVariant.outline,
          onPress: () => ref.read(supabaseClientProvider).auth.signOut(),
          child: const ButtonLabel('Sign out'),
        ),
      ],
    );
  }
}
