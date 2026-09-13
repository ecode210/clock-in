import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_dashboard_screen.dart';
import '../features/admin/admin_settings_screen.dart';
import '../features/admin/admin_shell.dart';
import '../features/admin/attendance_day_screen.dart';
import '../features/admin/attendance_export_screen.dart';
import '../features/admin/attendance_history_screen.dart';
import '../features/admin/location_editor_screen.dart';
import '../features/admin/locations_list_screen.dart';
import '../features/admin/security_settings_screen.dart';
import '../features/admin/staff_management_screen.dart';
import '../features/auth/awaiting_approval_screen.dart';
import '../features/auth/change_password_screen.dart';
import '../features/auth/first_admin_screen.dart';
import '../features/auth/login_screen.dart';
import '../core/dev_log.dart';
import '../features/shared/account_screen.dart';
import '../features/staff/clock_busy.dart';
import '../features/staff/staff_history_screen.dart';
import '../features/staff/staff_home_screen.dart';
import '../features/staff/staff_settings_screen.dart';
import '../features/staff/staff_shell.dart';
import 'app_stage.dart';

class AppRoutes {
  const AppRoutes._();

  static const login = '/login';
  static const setup = '/setup';
  static const pending = '/pending';
  static const changePassword = '/change-password';

  static const clockIn = '/';
  static const myHistory = '/history';

  /// Hub tab, with the account page nested under it so the tab stays selected.
  static const settings = '/settings';
  static const account = '/settings/account';

  static const adminDashboard = '/admin';
  static const adminAttendance = '/admin/attendance';
  static const adminStaff = '/admin/staff';

  /// Day list under Attendance, so the tab stays selected.
  static String adminAttendanceDay(String date) => '$adminAttendance/$date';

  /// Export form under Attendance. Registered before `:date` so the path is
  /// not treated as a calendar day.
  static const adminAttendanceExport = '/admin/attendance/export';

  /// Hub tab. The three routes below sit under it so the tab stays selected
  /// while a sub-page is open.
  static const adminSettings = '/admin/settings';
  static const adminLocations = '/admin/settings/locations';
  static const adminLocationNew = '/admin/settings/locations/new';
  static String adminLocationEdit(String id) => '$adminLocations/$id';

  /// Kept so old bookmarks to the single-zone page still land somewhere useful.
  static const adminLocation = adminLocations;

  static const adminSecurity = '/admin/settings/security';
  static const adminAccount = '/admin/settings/account';
}

/// Bridges the Riverpod providers the redirect reads into something `GoRouter`
/// will listen to, so signing in or out, or starting a clock-in, re-evaluates
/// the redirect immediately.
class _RouterListenable extends ChangeNotifier {
  _RouterListenable(Ref ref) {
    ref.listen<AppStage>(
      appStageProvider,
      (_, _) => notifyListeners(),
      fireImmediately: false,
    );
    ref.listen<String?>(
      clockBusyProvider,
      (_, _) => notifyListeners(),
      fireImmediately: false,
    );
  }
}

/// The screens that come before the app proper. Someone who has made it past
/// all of them has no business on any of them, so both signed-in stages bounce
/// off these back to their own home screen.
bool _isPreAppRoute(String location) =>
    location == AppRoutes.login ||
    location == AppRoutes.setup ||
    location == AppRoutes.pending ||
    location == AppRoutes.changePassword;

String? _stageRedirect(AppStage stage, String location) {
  final isAdminArea = location.startsWith('/admin');

  return switch (stage) {
    // Hold position; the boot gate covers the screen meanwhile.
    AppStage.loading => null,
    AppStage.signedOut => location == AppRoutes.login ? null : AppRoutes.login,
    AppStage.firstRunSetup =>
      location == AppRoutes.setup ? null : AppRoutes.setup,
    AppStage.awaitingApproval =>
      location == AppRoutes.pending ? null : AppRoutes.pending,
    AppStage.mustChangePassword =>
      location == AppRoutes.changePassword ? null : AppRoutes.changePassword,
    // Staff must not reach the admin area even by typing the URL; the
    // database would refuse the writes anyway, but this avoids dead ends.
    AppStage.staff =>
      _isPreAppRoute(location) || isAdminArea ? AppRoutes.clockIn : null,
    // Admins keep access to their own clock-in screen.
    AppStage.admin =>
      _isPreAppRoute(location) ? AppRoutes.adminDashboard : null,
  };
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _RouterListenable(ref);
  ref.onDispose(listenable.dispose);

  return GoRouter(
    initialLocation: AppRoutes.clockIn,
    refreshListenable: listenable,
    redirect: (context, state) {
      final location = state.matchedLocation;

      // Signing out mid-flow still has to win, so the stage decides first.
      final stageRedirect = _stageRedirect(
        ref.read(appStageProvider),
        location,
      );
      if (stageRedirect != null) return stageRedirect;

      // A clock-in or clock-out is running. Its screen owns the progress and
      // the error, so leaving orphans the flow. The overlay blocks the tabs;
      // this covers a hand-edited URL.
      if (ref.read(clockBusyProvider) != null &&
          location != AppRoutes.clockIn) {
        logNote('navigation blocked while clocking', {'to': location});
        return AppRoutes.clockIn;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.setup,
        builder: (context, state) => const FirstAdminScreen(),
      ),
      GoRoute(
        path: AppRoutes.pending,
        builder: (context, state) => const AwaitingApprovalScreen(),
      ),
      GoRoute(
        path: AppRoutes.changePassword,
        builder: (context, state) => const ChangePasswordScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            StaffShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: AppRoutes.clockIn,
            builder: (context, state) => const StaffHomeScreen(),
          ),
          GoRoute(
            path: AppRoutes.myHistory,
            builder: (context, state) => const StaffHistoryScreen(),
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const StaffSettingsScreen(),
          ),
          GoRoute(
            path: AppRoutes.account,
            builder: (context, state) => const AccountScreen(),
          ),
        ],
      ),
      ShellRoute(
        builder: (context, state, child) =>
            AdminShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: AppRoutes.adminDashboard,
            builder: (context, state) => const AdminDashboardScreen(),
          ),
          GoRoute(
            path: AppRoutes.adminAttendance,
            builder: (context, state) => const AttendanceHistoryScreen(),
          ),
          GoRoute(
            path: AppRoutes.adminAttendanceExport,
            builder: (context, state) => AttendanceExportScreen(
              initialFrom: state.uri.queryParameters['from'],
              initialTo: state.uri.queryParameters['to'],
            ),
          ),
          GoRoute(
            path: '${AppRoutes.adminAttendance}/:date',
            builder: (context, state) => AttendanceDayScreen(
              date: state.pathParameters['date']!,
            ),
          ),
          GoRoute(
            path: AppRoutes.adminStaff,
            builder: (context, state) => const StaffManagementScreen(),
          ),
          GoRoute(
            path: AppRoutes.adminSettings,
            builder: (context, state) => const AdminSettingsScreen(),
          ),
          GoRoute(
            path: AppRoutes.adminLocations,
            builder: (context, state) => const LocationsListScreen(),
          ),
          GoRoute(
            path: AppRoutes.adminLocationNew,
            builder: (context, state) => const LocationEditorScreen(),
          ),
          GoRoute(
            path: '${AppRoutes.adminLocations}/:id',
            builder: (context, state) => LocationEditorScreen(
              locationId: state.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: AppRoutes.adminSecurity,
            builder: (context, state) => const SecuritySettingsScreen(),
          ),
          GoRoute(
            path: AppRoutes.adminAccount,
            builder: (context, state) => const AccountScreen(),
          ),
        ],
      ),
    ],
  );
});
