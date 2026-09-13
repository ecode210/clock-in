import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../models/org_settings.dart';
import '../../routing/router.dart';
import '../../services/locations_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

/// Hub for the admin areas that do not warrant a tab of their own.
///
/// Each row pushes a sub-page with a back button, which is the hierarchy a
/// phone user expects.
class AdminSettingsScreen extends ConsumerWidget {
  const AdminSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(orgSettingsProvider).value;
    final locations = ref.watch(locationsProvider).value;
    final me = ref.watch(myProfileProvider).value;
    final activeCount =
        locations?.where((l) => l.isActive).length ?? 0;

    return AppScaffold(
      childPad: false,
      header: FHeader(title: const Text('Settings')),
      child: PagePadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionLabel('Organisation'),
            FTileGroup(
              children: [
                FTile(
                  prefix: const TileIcon(FLucideIcons.mapPin),
                  title: const Text('Clock-in locations'),
                  subtitle: Text(
                    locations == null
                        ? 'Set where staff may clock in'
                        : activeCount == 0
                        ? 'None set up yet'
                        : '$activeCount '
                            '${activeCount == 1 ? 'location' : 'locations'}',
                  ),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(AppRoutes.adminLocations),
                ),
                FTile(
                  prefix: const TileIcon(FLucideIcons.shieldCheck),
                  title: const Text('Verification'),
                  subtitle: Text(_verificationSummary(settings)),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(AppRoutes.adminSecurity),
                ),
              ],
            ),
            const SizedBox(height: gutter),
            const SectionLabel('You'),
            FTileGroup(
              children: [
                FTile(
                  prefix: const TileIcon(FLucideIcons.circleUserRound),
                  title: const Text('Account'),
                  subtitle: Text(me?.displayName ?? 'Profile and passkeys'),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(AppRoutes.adminAccount),
                ),
                FTile(
                  prefix: const TileIcon(FLucideIcons.fingerprint),
                  title: const Text('Staff area'),
                  subtitle: const Text(
                    'Clock in and out, and see your own history',
                  ),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(AppRoutes.clockIn),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _verificationSummary(OrgSettings? settings) {
    if (settings == null) return 'Passkey and live photo';
    final checks = <String>[
      if (settings.requirePasskey) 'Passkey',
      if (settings.requireSelfie) 'Live photo',
    ];
    if (checks.isEmpty) return 'Location only';
    return checks.join(' · ');
  }
}
