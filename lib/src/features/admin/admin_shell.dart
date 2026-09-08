import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../routing/router.dart';
import '../../services/supabase_providers.dart';
import '../shared/nav_shell.dart';

class AdminShell extends ConsumerWidget {
  const AdminShell({required this.location, required this.child, super.key});

  final String location;
  final Widget child;

  /// Four tabs is the most that stays comfortable in a phone tab bar, so the
  /// less-used admin areas live behind the Settings tab instead.
  static const _destinations = [
    NavDestinationSpec(
      path: AppRoutes.adminDashboard,
      label: 'Today',
      icon: FLucideIcons.layoutGrid,
      selectedIcon: FLucideIcons.layoutGrid,
    ),
    NavDestinationSpec(
      path: AppRoutes.adminAttendance,
      label: 'Attendance',
      icon: FLucideIcons.calendarDays,
      selectedIcon: FLucideIcons.calendarDays,
    ),
    NavDestinationSpec(
      path: AppRoutes.adminStaff,
      label: 'Staff',
      icon: FLucideIcons.users,
      selectedIcon: FLucideIcons.users,
    ),
    NavDestinationSpec(
      path: AppRoutes.adminSettings,
      label: 'Settings',
      icon: FLucideIcons.settings,
      selectedIcon: FLucideIcons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(orgSettingsProvider).value;

    return AppNavShell(
      location: location,
      title: settings?.orgName,
      destinations: _destinations,
      child: child,
    );
  }
}
