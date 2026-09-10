import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_stage.dart';
import '../../routing/router.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

/// Hub for everything on the staff side that is not clocking in.
///
/// Mirrors the admin hub: each row pushes a sub-page with a back button.
class StaffSettingsScreen extends ConsumerWidget {
  const StaffSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myProfileProvider).value;
    final isAdmin = ref.watch(appStageProvider) == AppStage.admin;

    return AppScaffold(
      childPad: false,
      header: FHeader(title: const Text('Settings')),
      child: PagePadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionLabel('You'),
            FTileGroup(
              children: [
                FTile(
                  prefix: const TileIcon(FLucideIcons.circleUserRound),
                  title: const Text('Account'),
                  subtitle: Text(me?.displayName ?? 'Profile and passkeys'),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(AppRoutes.account),
                ),
              ],
            ),
            if (isAdmin) ...[
              const SizedBox(height: gutter),
              const SectionLabel('Administration'),
              FTileGroup(
                children: [
                  FTile(
                    prefix: const TileIcon(FLucideIcons.layoutGrid),
                    title: const Text('Admin area'),
                    subtitle: const Text(
                      'Manage staff, attendance and settings',
                    ),
                    suffix: const Icon(FLucideIcons.chevronRight),
                    onPress: () => context.go(AppRoutes.adminDashboard),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
