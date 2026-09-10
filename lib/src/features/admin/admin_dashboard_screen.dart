import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../models/org_settings.dart';
import '../../models/profile.dart';
import '../../routing/router.dart';
import '../../services/attendance_repository.dart';
import '../../services/staff_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';
import 'attendance_row_tile.dart';

class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todayAttendanceProvider);
    final staff = ref.watch(staffListProvider);
    final settings = ref.watch(orgSettingsProvider);

    return AppScaffold(
      childPad: false,
      header: FHeader(
        title: const Text('Today'),
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: () {
              ref.invalidate(orgTodayProvider);
              ref.invalidate(todayAttendanceProvider);
              ref.invalidate(staffListProvider);
            },
          ),
        ],
      ),
      child: AsyncSection(
        value: settings,
        onRetry: () => ref.invalidate(orgSettingsProvider),
        builder: (settingsData) => AsyncSection(
          value: today,
          onRetry: () => ref.invalidate(todayAttendanceProvider),
          builder: (records) => PagePadding(
            maxWidth: 700,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!settingsData.isGeofenceConfigured) ...[
                  const _SetupPrompt(),
                  const SizedBox(height: gutter),
                ],
                _StatsCard(
                  records: records,
                  activeStaffCount: staff.value
                      ?.where((p) => p.isActive)
                      .length,
                ),
                const SizedBox(height: gutter),
                _VerificationSummary(settings: settingsData),
                const SizedBox(height: gutter),
                if (records.isEmpty)
                  const FCard(
                    child: EmptyState(
                      icon: FLucideIcons.users,
                      title: 'Nobody has clocked in yet',
                      message: 'Records appear here as staff arrive.',
                    ),
                  )
                else
                  FTileGroup(
                    label: Text('Clocked in · ${formatDay(DateTime.now())}'),
                    children: [
                      for (final record in records)
                        AttendanceRowTile(record: record),
                    ],
                  ),
                const SizedBox(height: 10),
                FButton(
                  variant: FButtonVariant.outline,
                  onPress: () => context.go(AppRoutes.adminAttendance),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  child: const ButtonLabel('All records'),
                ),
                const SizedBox(height: gutter),
                _AbsentCard(records: records, staff: staff.value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupPrompt extends StatelessWidget {
  const _SetupPrompt();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const FAlert(
        variant: FAlertVariant.destructive,
        icon: Icon(FLucideIcons.mapPinOff),
        title: Text('No clock-in zone has been set'),
        subtitle: Text('Nobody can mark attendance until you set one.'),
      ),
      const SizedBox(height: 10),
      FButton(
        onPress: () => context.go(AppRoutes.adminLocation),
        child: const ButtonLabel('Set up the zone'),
      ),
    ],
  );
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.records, required this.activeStaffCount});

  final List<AttendanceRecord> records;
  final int? activeStaffCount;

  @override
  Widget build(BuildContext context) {
    final onShift = records.where((r) => r.isOpen).length;
    final completed = records.length - onShift;

    // Three figures side by side rather than three cards: on a phone this
    // reads as one glanceable summary instead of a stack to scroll past.
    return ContentCard(
      child: MetricRow(
        figures: [
          MetricFigure(
            label: 'Clocked in',
            value:
                '${records.length}'
                '${activeStaffCount == null ? '' : '/$activeStaffCount'}',
          ),
          MetricFigure(label: 'On shift', value: '$onShift'),
          MetricFigure(label: 'Finished', value: '$completed'),
        ],
      ),
    );
  }
}

class _VerificationSummary extends StatelessWidget {
  const _VerificationSummary({required this.settings});

  final OrgSettings settings;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Active checks',
      subtitle: 'Applied to every clock-in, enforced by the database.',
      trailing: FButton(
        variant: FButtonVariant.primary,
        size: FButtonSizeVariant.sm,
        prefix: const Icon(FLucideIcons.settings2),
        onPress: () => context.go(AppRoutes.adminSecurity),
        child: const Text('Change'),
      ),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            StatusChip(
              label: settings.isGeofenceConfigured
                  ? '${settings.locationName} · '
                        '${formatDistance(settings.radiusMeters.toDouble())}'
                  : 'Location not set',
              icon: FLucideIcons.mapPin,
              tone: settings.isGeofenceConfigured
                  ? ChipTone.positive
                  : ChipTone.negative,
            ),
            StatusChip(
              label: settings.requirePasskey ? 'Passkey on' : 'Passkey off',
              icon: FLucideIcons.fingerprint,
              tone: settings.requirePasskey
                  ? ChipTone.positive
                  : ChipTone.neutral,
            ),
            StatusChip(
              label: settings.requireSelfie
                  ? 'Live photo on'
                  : 'Live photo off',
              icon: FLucideIcons.camera,
              tone: settings.requireSelfie
                  ? ChipTone.positive
                  : ChipTone.neutral,
            ),
          ],
        ),
      ],
    );
  }
}

/// Who has not shown up. This is usually the reason an admin opens the app.
class _AbsentCard extends StatelessWidget {
  const _AbsentCard({required this.records, required this.staff});

  final List<AttendanceRecord> records;
  final List<Profile>? staff;

  @override
  Widget build(BuildContext context) {
    final all = staff;
    if (all == null) return const SizedBox.shrink();

    final clockedIn = records.map((r) => r.userId).toSet();
    final absent = all
        .where((p) => p.isActive && !clockedIn.contains(p.id))
        .toList();

    return SectionCard(
      title: 'Not clocked in',
      subtitle:
          '${absent.length} of '
          '${all.where((p) => p.isActive).length} active staff',
      children: [
        if (absent.isEmpty)
          const EmptyState(
            icon: FLucideIcons.partyPopper,
            title: 'Everyone is accounted for',
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final person in absent)
                StatusChip(label: person.displayName),
            ],
          ),
      ],
    );
  }
}
