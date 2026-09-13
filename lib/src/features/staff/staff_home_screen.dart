import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_error.dart';
import '../../core/dev_log.dart';
import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../models/clock_location.dart';
import '../../models/org_settings.dart';
import '../../routing/router.dart';
import '../../services/attendance_repository.dart';
import '../../services/location_service.dart';
import '../../services/locations_repository.dart';
import '../../services/passkey_service.dart';
import '../../services/selfie_service.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';
import 'clock_busy.dart';
import 'geofence_status.dart';
import 'selfie_capture_dialog.dart';

class StaffHomeScreen extends ConsumerStatefulWidget {
  const StaffHomeScreen({super.key});

  @override
  ConsumerState<StaffHomeScreen> createState() => _StaffHomeScreenState();
}

class _StaffHomeScreenState extends ConsumerState<StaffHomeScreen> {
  String? _error;

  /// Read through instead of `ref` for everything the flows touch after their
  /// first `await`: `ref` throws once this screen is disposed, which happens
  /// if the session drops mid-flow, and the lock has to be released even then.
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  /// Progress lives in [clockBusyProvider] rather than here so the shell can
  /// lock the tabs while a flow runs.
  String? get _progress => ref.watch(clockBusyProvider);

  bool get _busy => _progress != null;

  void _setProgress(String step) =>
      _container.read(clockBusyProvider.notifier).update(step);

  /// Timeouts for the steps that wait on a machine. The two that wait on a
  /// person, the passkey prompt and the camera sheet, are handled separately:
  /// they are slow for good reasons.
  static const _locationLimit = Duration(seconds: 35);
  static const _passkeyLimit = Duration(seconds: 90);
  static const _uploadLimit = Duration(seconds: 20);
  static const _writeLimit = Duration(seconds: 20);

  /// The location card keeps a position stream open, so a recent reading is
  /// usually already in hand. Reuse it rather than starting another
  /// high-accuracy lookup, falling back to a fresh one when it is too stale.
  Future<LocationFix> _locationFix() async {
    final live = _container.read(locationStreamProvider).value;
    if (live != null && live.age <= LocationService.maxReusableFixAge) {
      logNote('reusing live location fix', {
        'age_s': live.age.inSeconds,
        'accuracy': live.accuracyMeters.round(),
      });
      return live;
    }
    return _container.read(locationServiceProvider).currentFix();
  }

  /// Runs the clock-in gauntlet: prove where you are, pick the site, prove who
  /// you are, then record the visit. Location is chosen before passkey/selfie
  /// so a slow site picker cannot stale a fresh photo.
  Future<void> _clockIn(
    OrgSettings settings,
    List<ClockLocation> locations,
  ) async {
    final userId = _container.read(currentUserIdProvider);
    if (userId == null) return;

    setState(() => _error = null);
    _setProgress('Checking your location…');

    try {
      final fix = await withStepTimeout(
        _locationFix(),
        limit: _locationLimit,
        message:
            'Could not pin down where you are. Move near a window or step '
            'outside, then try again.',
        code: ClockErrorCode.stepTimeout,
      );
      final inRange = InRangeLocations.evaluate(
        locations: locations,
        fix: fix,
        maxAccuracyMeters: settings.maxAccuracyMeters,
      );

      if (!inRange.isInsideAny) {
        throw const AppError(
          'You are not inside any clock-in location. Move into a site zone '
          'and try again.',
          code: ClockErrorCode.outsideGeofence,
        );
      }
      if (!inRange.accuracyAcceptable) {
        throw AppError(
          'Your location is only accurate to '
          '${formatDistance(inRange.accuracyMeters)}. Move somewhere with a '
          'better signal and try again.',
          code: ClockErrorCode.poorAccuracy,
        );
      }

      if (!mounted) {
        throw const AppError(
          'Clocking in was interrupted before you chose a location. Please '
          'try again.',
          code: ClockErrorCode.interrupted,
        );
      }

      _setProgress('Choose a location…');
      final chosen = inRange.matches.length == 1
          ? inRange.matches.first.location
          : await _pickLocation(inRange.matches);
      if (chosen == null) {
        throw const AppError(
          'Pick which location you are at to finish clocking in.',
          code: ClockErrorCode.missingLocation,
        );
      }

      if (settings.requirePasskey) {
        if ((await _container.read(myPasskeysProvider.future)).isEmpty) {
          throw const AppError(
            'You need your own passkey before you can clock in. Add one from '
            'Settings, then try again.',
            code: ClockErrorCode.passkeyRequired,
          );
        }

        _setProgress('Waiting for your passkey…');
        await withStepTimeout(
          _container
              .read(passkeyServiceProvider)
              .reauthenticate(expectedUserId: userId),
          limit: _passkeyLimit,
          message:
              'The passkey check did not finish in time. Please try again.',
          code: ClockErrorCode.stepTimeout,
        );
      }

      String? selfiePath;
      if (settings.requireSelfie) {
        _setProgress('Waiting for your photo…');
        if (!mounted) {
          throw const AppError(
            'Clocking in was interrupted before your photo was taken. Please '
            'try again.',
            code: ClockErrorCode.interrupted,
          );
        }
        final selfie = await SelfieCaptureDialog.show(context);
        if (selfie == null) {
          throw const AppError(
            'A live photo is required to clock in.',
            code: ClockErrorCode.selfieRequired,
          );
        }
        _setProgress('Uploading your photo…');
        selfiePath = await withStepTimeout(
          _container.read(selfieServiceProvider).upload(selfie),
          limit: _uploadLimit,
          message:
              'Your photo did not finish uploading. Check your connection and '
              'try again.',
          code: ClockErrorCode.stepTimeout,
        );
      }

      _setProgress('Recording your clock-in…');
      try {
        await withStepTimeout(
          _container.read(attendanceRepositoryProvider).clockIn(
            latitude: fix.latitude,
            longitude: fix.longitude,
            locationId: chosen.id,
            accuracyMeters: fix.accuracyMeters,
            selfiePath: selfiePath,
          ),
          limit: _writeLimit,
          message:
              'We could not confirm your clock-in in time. Pull to refresh in a '
              'moment to check whether it went through.',
          code: ClockErrorCode.stepTimeout,
        );
      } on AppError catch (error) {
        if (error.code != ClockErrorCode.stepTimeout) rethrow;
        final open = await _reconcileOpenShift();
        if (open != null) {
          if (mounted) {
            showSnack(
              context,
              'Clocked in at ${chosen.name}. Have a good shift.',
            );
          }
          return;
        }
        rethrow;
      }

      _refreshRecords();
      if (mounted) {
        showSnack(context, 'Clocked in at ${chosen.name}. Have a good shift.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      _finish();
    }
  }

  Future<ClockLocation?> _pickLocation(
    List<({ClockLocation location, GeofenceStatus status})> matches,
  ) {
    return showFSheet<ClockLocation>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: null,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Which location are you at?',
                style: sheetContext.theme.titleStyle,
              ),
            ),
            FTileGroup(
              children: [
                for (final match in matches)
                  FTile(
                    prefix: const TileIcon(FLucideIcons.mapPin),
                    title: Text(match.location.name),
                    subtitle: Text(
                      '${formatDistance(match.status.distanceMeters)} from '
                      'the centre',
                    ),
                    onPress: () => Navigator.of(sheetContext).pop(
                      match.location,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            FButton(
              variant: FButtonVariant.outline,
              onPress: () => Navigator.of(sheetContext).pop(),
              child: const ButtonLabel('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clockOut() async {
    setState(() => _error = null);
    _setProgress('Checking your location…');

    try {
      LocationFix? fix;
      try {
        fix = await withStepTimeout(
          _locationFix(),
          limit: _locationLimit,
          message:
              'Could not pin down where you are. You can still clock out '
              'without it.',
          code: ClockErrorCode.stepTimeout,
        );
      } catch (_) {
        // Clock-out is allowed from anywhere; a missing fix is fine.
        fix = null;
      }

      _setProgress('Recording your clock-out…');
      try {
        await withStepTimeout(
          _container.read(attendanceRepositoryProvider).clockOut(
            latitude: fix?.latitude,
            longitude: fix?.longitude,
            accuracyMeters: fix?.accuracyMeters,
          ),
          limit: _writeLimit,
          message:
              'We could not confirm your clock-out in time. Pull to refresh in a '
              'moment to check whether it went through.',
          code: ClockErrorCode.stepTimeout,
        );
      } on AppError catch (error) {
        if (error.code != ClockErrorCode.stepTimeout) rethrow;
        final open = await _reconcileOpenShift();
        if (open == null) {
          if (mounted) showSnack(context, 'Clocked out.');
          return;
        }
        rethrow;
      }

      _refreshRecords();
      if (mounted) showSnack(context, 'Clocked out.');
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      _finish();
    }
  }

  Future<AttendanceRecord?> _reconcileOpenShift() async {
    _container
      ..invalidate(myTodayRecordsProvider)
      ..invalidate(myOpenRecordProvider);
    try {
      return await _container.read(myOpenRecordProvider.future);
    } catch (_) {
      return null;
    }
  }

  void _refreshRecords() {
    _container
      ..invalidate(myTodayRecordsProvider)
      ..invalidate(myOpenRecordProvider);
  }

  void _finish() => _container.read(clockBusyProvider.notifier).clear();

  void _refresh() {
    ref.invalidate(locationStreamProvider);
    ref.invalidate(myTodayRecordsProvider);
    ref.invalidate(myOpenRecordProvider);
    ref.invalidate(orgSettingsProvider);
    ref.invalidate(activeLocationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(orgSettingsProvider);
    final locations = ref.watch(activeLocationsProvider);
    final open = ref.watch(myOpenRecordProvider);
    final today = ref.watch(myTodayRecordsProvider);
    final me = ref.watch(myProfileProvider).value;
    final firstName = me?.displayName.split(' ').first;

    return AppScaffold(
      childPad: false,
      header: FHeader(
        title: Text(firstName == null ? 'Clock in' : 'Hi, $firstName'),
        suffixes: [
          HeaderAction(
            icon: FLucideIcons.refreshCw,
            semanticsLabel: 'Refresh',
            onPress: _refresh,
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
            value: open,
            onRetry: () => ref.invalidate(myOpenRecordProvider),
            builder: (openRecord) => AsyncSection(
              value: today,
              onRetry: () => ref.invalidate(myTodayRecordsProvider),
              builder: (todayRecords) => PagePadding(
                child: locationList.isEmpty
                    ? const _NotConfiguredNotice()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _HeroPanel(
                            openRecord: openRecord,
                            settings: settingsData,
                            locations: locationList,
                            progress: _progress,
                            busy: _busy,
                            onClockIn: () =>
                                _clockIn(settingsData, locationList),
                            onClockOut: _clockOut,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: gutter),
                            ErrorNotice(error: AppError(_error!)),
                          ],
                          const SizedBox(height: gutter),
                          _LocationCard(
                            settings: settingsData,
                            locations: locationList,
                          ),
                          if (todayRecords.isNotEmpty) ...[
                            const SizedBox(height: gutter),
                            _TodayVisitsCard(records: todayRecords),
                          ],
                          const SizedBox(height: gutter),
                          _RequirementsSection(settings: settingsData),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotConfiguredNotice extends StatelessWidget {
  const _NotConfiguredNotice();

  @override
  Widget build(BuildContext context) => const FCard(
    child: EmptyState(
      icon: FLucideIcons.mapPinOff,
      title: 'Clock-in is not set up yet',
      message:
          'An administrator still needs to add at least one work location. '
          'You will be able to clock in once that is done.',
    ),
  );
}

/// The headline state plus the one button that acts on it.
class _HeroPanel extends ConsumerWidget {
  const _HeroPanel({
    required this.openRecord,
    required this.settings,
    required this.locations,
    required this.progress,
    required this.busy,
    required this.onClockIn,
    required this.onClockOut,
  });

  final AttendanceRecord? openRecord;
  final OrgSettings settings;
  final List<ClockLocation> locations;
  final String? progress;
  final bool busy;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final isClockOut = openRecord != null;
    final timezone = settings.timezone;
    final now = orgNow(timezone);

    final inRange = ref.watch(inRangeLocationsProvider).value;
    final fixLoading = ref.watch(locationStreamProvider).isLoading;

    // Clock-out works from anywhere. Clock-in needs an in-range site.
    final locationOk = isClockOut || (inRange?.canClockIn ?? false);

    final passkeys = ref.watch(myPasskeysProvider);
    final needsPasskey =
        !isClockOut &&
        settings.requirePasskey &&
        (passkeys.isLoading || (passkeys.value?.isEmpty ?? true));

    return ContentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatDay(now, timezone: timezone),
                  style: theme.mutedStyle,
                ),
              ),
              if (isClockOut)
                const StatusChip(
                  label: 'On shift',
                  icon: FLucideIcons.clock,
                  tone: ChipTone.positive,
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (isClockOut)
            _LiveElapsed(since: openRecord!.clockInAt)
          else
            _HeroFigure(
              label: 'Right now',
              value: formatTime(now, timezone: timezone),
            ),
          if (isClockOut && openRecord!.locationName != null) ...[
            const SizedBox(height: 8),
            Text(
              'At ${openRecord!.displayLocationName}',
              style: theme.mutedStyle,
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 60,
            child: FButton(
              size: FButtonSizeVariant.lg,
              variant: isClockOut
                  ? FButtonVariant.secondary
                  : FButtonVariant.primary,
              onPress: busy || !locationOk || needsPasskey
                  ? null
                  : (isClockOut ? onClockOut : onClockIn),
              prefix: busy
                  ? const FCircularProgress()
                  : Icon(
                      isClockOut ? FLucideIcons.logOut : FLucideIcons.logIn,
                      size: 22,
                    ),
              child: ButtonLabel(
                progress ?? (isClockOut ? 'Clock out' : 'Clock in'),
              ),
            ),
          ),
          if (!busy && (!locationOk || needsPasskey)) ...[
            const SizedBox(height: 10),
            Text(
              needsPasskey
                  ? passkeys.isLoading
                        ? 'Checking your passkey…'
                        : 'Add your own passkey below before you can clock in.'
                  : fixLoading || inRange == null
                  ? 'Waiting for your location before you can clock in.'
                  : 'Move inside a clock-in location to enable this button.',
              textAlign: TextAlign.center,
              style: theme.captionStyle,
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroFigure extends StatelessWidget {
  const _HeroFigure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.captionStyle),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: theme.headingStyle),
        ),
      ],
    );
  }
}

/// Ticking counter so an open shift feels live rather than stale.
class _LiveElapsed extends StatefulWidget {
  const _LiveElapsed({required this.since});

  final DateTime since;

  @override
  State<_LiveElapsed> createState() => _LiveElapsedState();
}

class _LiveElapsedState extends State<_LiveElapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _HeroFigure(
    label: 'On shift for',
    value: formatElapsed(DateTime.now().toUtc().difference(widget.since.toUtc())),
  );
}

/// Live distance readout against every active location.
class _LocationCard extends ConsumerWidget {
  const _LocationCard({required this.settings, required this.locations});

  final OrgSettings settings;
  final List<ClockLocation> locations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final inRangeAsync = ref.watch(inRangeLocationsProvider);

    return SectionCard(
      title: 'Your location',
      subtitle:
          '${locations.length} '
          '${locations.length == 1 ? 'location' : 'locations'}',
      trailing: FButton.icon(
        variant: FButtonVariant.primary,
        size: FButtonSizeVariant.sm,
        onPress: () => ref.invalidate(locationStreamProvider),
        semanticsLabel: 'Recheck location',
        child: const Icon(FLucideIcons.locateFixed),
      ),
      children: [
        inRangeAsync.when(
          skipLoadingOnRefresh: true,
          loading: () => Row(
            children: [
              const FCircularProgress(),
              const SizedBox(width: 12),
              Text('Finding your location…', style: theme.bodyStyle),
            ],
          ),
          error: (error, _) => ErrorNotice(
            error: error,
            onRetry: () => ref.invalidate(locationStreamProvider),
          ),
          data: (inRange) {
            if (inRange == null) {
              return Row(
                children: [
                  const FCircularProgress(),
                  const SizedBox(width: 12),
                  Text('Finding your location…', style: theme.bodyStyle),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      inRange.isInsideAny
                          ? FLucideIcons.circleCheck
                          : FLucideIcons.circleAlert,
                      size: 18,
                      color: inRange.isInsideAny
                          ? theme.colors.primary
                          : theme.colors.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        inRange.isInsideAny
                            ? inRange.matches.length == 1
                                  ? 'You are inside '
                                        '${inRange.matches.first.location.name}, '
                                        '${formatDistance(inRange.matches.first.status.distanceMeters)} '
                                        'from the centre.'
                                  : 'You are inside '
                                        '${inRange.matches.length} locations. '
                                        'You will choose which one when you '
                                        'clock in.'
                            : 'You are not inside any clock-in location.',
                        style: theme.bodyStyle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatusChip(
                      label: inRange.isInsideAny
                          ? 'In zone'
                          : 'Out of zone',
                      icon: inRange.isInsideAny
                          ? FLucideIcons.mapPin
                          : FLucideIcons.mapPinOff,
                      tone: inRange.canClockIn
                          ? ChipTone.positive
                          : ChipTone.negative,
                    ),
                    StatusChip(
                      label:
                          'Accuracy ${formatDistance(inRange.accuracyMeters)}',
                      icon: FLucideIcons.crosshair,
                      tone: inRange.accuracyAcceptable
                          ? ChipTone.neutral
                          : ChipTone.warning,
                    ),
                    for (final match in inRange.matches)
                      StatusChip(
                        label: match.location.name,
                        icon: FLucideIcons.mapPin,
                        tone: ChipTone.positive,
                      ),
                  ],
                ),
                if (!inRange.accuracyAcceptable) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Your device is not confident about this position. Move '
                    'near a window or step outside for a moment.',
                    style: theme.captionStyle,
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Every visit today, newest first.
class _TodayVisitsCard extends ConsumerWidget {
  const _TodayVisitsCard({required this.records});

  final List<AttendanceRecord> records;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timezone = ref.watch(orgSettingsProvider).value?.timezone;
    return FTileGroup(
      label: const Text("Today's visits"),
      children: [
        for (final record in records)
          FTile(
            prefix: TileIcon(
              record.isOpen ? FLucideIcons.hourglass : FLucideIcons.circleCheck,
            ),
            title: Text(record.displayLocationName),
            subtitle: Text(
              '${formatTime(record.clockInAt, timezone: timezone)} → '
              '${formatTime(record.clockOutAt, timezone: timezone)}'
              '${record.isOpen ? '' : ' · ${formatDuration(record.workedDuration)}'}',
            ),
            details: Text(record.isOpen ? 'On shift' : 'Done'),
          ),
      ],
    );
  }
}

/// Tells staff up front which checks they will be asked to pass, and nudges
/// them to enrol a passkey before they need one.
class _RequirementsSection extends ConsumerWidget {
  const _RequirementsSection({required this.settings});

  final OrgSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!settings.requireSelfie && !settings.requirePasskey) {
      return const SizedBox.shrink();
    }

    final passkeys = ref.watch(myPasskeysProvider);
    final needsEnrolment =
        settings.requirePasskey && (passkeys.value?.isEmpty ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTileGroup(
          label: const Text('Checks at clock-in'),
          children: [
            if (settings.requirePasskey)
              FTile(
                prefix: const TileIcon(FLucideIcons.fingerprint),
                title: const Text('Passkey'),
                subtitle: const TileSubtitle(
                  'Confirm with the fingerprint or face unlock on your device.',
                ),
              ),
            if (settings.requireSelfie)
              FTile(
                prefix: const TileIcon(FLucideIcons.camera),
                title: const Text('Live photo'),
                subtitle: const TileSubtitle(
                  'Take a photo with your camera at clock-in.',
                ),
              ),
          ],
        ),
        if (needsEnrolment) ...[
          const SizedBox(height: 12),
          FAlert(
            icon: const Icon(FLucideIcons.triangleAlert),
            title: const Text('You have not added a passkey yet'),
            subtitle: const Text(
              'Add one now so you can clock in without help.',
            ),
          ),
          const SizedBox(height: 10),
          FButton(
            variant: FButtonVariant.outline,
            onPress: () => context.go(AppRoutes.account),
            prefix: const Icon(FLucideIcons.plus),
            child: const ButtonLabel('Add a passkey'),
          ),
        ],
      ],
    );
  }
}
