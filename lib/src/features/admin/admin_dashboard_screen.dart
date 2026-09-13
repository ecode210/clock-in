import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../models/org_settings.dart';
import '../../models/profile.dart';
import '../../routing/router.dart';
import '../../services/attendance_repository.dart';
import '../../services/locations_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';
import 'attendance_row_tile.dart';

class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(todaySnapshotProvider);
    final settings = ref.watch(orgSettingsProvider);
    final locations = ref.watch(activeLocationsProvider);

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
              ref.invalidate(todaySnapshotProvider);
              ref.invalidate(activeLocationsProvider);
            },
          ),
        ],
      ),
      child: AsyncSection(
        value: settings,
        onRetry: () => ref.invalidate(orgSettingsProvider),
        builder: (settingsData) => AsyncSection(
          value: locations,
          onRetry: () => ref.invalidate(activeLocationsProvider),
          builder: (locationList) => AsyncSection(
            value: snapshot,
            onRetry: () => ref.invalidate(todaySnapshotProvider),
            builder: (data) => PagePadding(
              maxWidth: 700,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (locationList.isEmpty) ...[
                    const _SetupPrompt(),
                    const SizedBox(height: gutter),
                  ],
                  _StatsCard(
                    people: data.people,
                    onShift: data.onShift,
                    completed: data.completed,
                    activeStaffCount: data.people + data.absent.length,
                  ),
                  const SizedBox(height: gutter),
                  _VerificationSummary(
                    settings: settingsData,
                    locationCount: locationList.length,
                  ),
                  const SizedBox(height: gutter),
                  if (data.recent.isEmpty)
                    const FCard(
                      child: EmptyState(
                        icon: FLucideIcons.users,
                        title: 'Nobody has clocked in yet',
                        message: 'Records appear here as staff arrive.',
                      ),
                    )
                  else
                    FTileGroup(
                      label: Text(
                        'Visits · ${formatDay(data.workDate)}',
                      ),
                      children: [
                        for (final record in data.recent)
                          AttendanceRowTile(
                            record: record,
                            timezone: settingsData.timezone,
                            onReviewed: () =>
                                ref.invalidate(todaySnapshotProvider),
                          ),
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
                  _AbsentCard(absent: data.absent),
                ],
              ),
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
        title: Text('No clock-in locations have been set'),
        subtitle: Text('Nobody can mark attendance until you add one.'),
      ),
      const SizedBox(height: 10),
      FButton(
        onPress: () => context.go(AppRoutes.adminLocations),
        child: const ButtonLabel('Add a location'),
      ),
    ],
  );
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.people,
    required this.onShift,
    required this.completed,
    required this.activeStaffCount,
  });

  final int people;
  final int onShift;
  final int completed;
  final int activeStaffCount;

  @override
  Widget build(BuildContext context) {
    return ContentCard(
      child: MetricRow(
        figures: [
          MetricFigure(
            label: 'People',
            value: '$people/$activeStaffCount',
          ),
          MetricFigure(label: 'On shift', value: '$onShift'),
          MetricFigure(label: 'Visits done', value: '$completed'),
        ],
      ),
    );
  }
}

class _VerificationSummary extends StatelessWidget {
  const _VerificationSummary({
    required this.settings,
    required this.locationCount,
  });

  final OrgSettings settings;
  final int locationCount;

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
              label: locationCount == 0
                  ? 'No locations'
                  : '$locationCount '
                        '${locationCount == 1 ? 'location' : 'locations'}',
              icon: FLucideIcons.mapPin,
              tone: locationCount == 0 ? ChipTone.negative : ChipTone.positive,
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
  const _AbsentCard({required this.absent});

  final List<Profile> absent;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Not clocked in',
      subtitle: '${absent.length} active staff still to arrive',
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
