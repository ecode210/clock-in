import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../routing/router.dart';
import '../../services/supabase_providers.dart';
import '../shared/nav_shell.dart';
import 'clock_busy.dart';

class StaffShell extends ConsumerWidget {
  const StaffShell({required this.location, required this.child, super.key});

  final String location;
  final Widget child;

  static const _destinations = [
    NavDestinationSpec(
      path: AppRoutes.clockIn,
      label: 'Clock in',
      icon: FLucideIcons.fingerprint,
      selectedIcon: FLucideIcons.fingerprint,
    ),
    NavDestinationSpec(
      path: AppRoutes.myHistory,
      label: 'History',
      icon: FLucideIcons.history,
      selectedIcon: FLucideIcons.history,
    ),
    NavDestinationSpec(
      path: AppRoutes.settings,
      label: 'Settings',
      icon: FLucideIcons.settings,
      selectedIcon: FLucideIcons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(orgSettingsProvider).value;
    final busy = ref.watch(clockBusyProvider);

    return Stack(
      fit: StackFit.expand,
      children: [
        AppNavShell(
          location: location,
          title: settings?.orgName,
          destinations: _destinations,
          child: child,
        ),
        if (busy != null) ClockBusyOverlay(progress: busy),
      ],
    );
  }
}
