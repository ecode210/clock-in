import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../models/org_settings.dart';
import '../../routing/router.dart';
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
    final me = ref.watch(myProfileProvider).value;

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
                  title: const Text('Clock-in zone'),
                  subtitle: Text(
                    settings == null
                        ? 'Set where staff may clock in'
                        : settings.isGeofenceConfigured
                        ? '${settings.locationName} · ${settings.radiusMeters} m'
                        : 'Not set up yet',
                  ),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(AppRoutes.adminLocation),
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
    if (settings == null) return 'Passkey and live photo checks';
    final checks = [
      if (settings.requirePasskey) 'Passkey',
      if (settings.requireSelfie) 'Live photo',
    ];
    return checks.isEmpty
        ? 'No checks required'
        : '${checks.join(' + ')} required';
  }
}
