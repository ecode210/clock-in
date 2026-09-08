import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_error.dart';
import '../../core/dev_log.dart';
import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../models/org_settings.dart';
import '../../routing/router.dart';
import '../../services/attendance_repository.dart';
import '../../services/location_service.dart';
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

  /// Runs the clock-in gauntlet in the order the checks make sense: prove where
  /// you are, prove who you are, then prove you were there.
  Future<void> _clockIn(OrgSettings settings) async {
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
      final status = GeofenceStatus.from(settings, fix);

      if (!status.isInside) {
        throw AppError(
          'You are ${formatDistance(status.distanceMeters)} from '
          '${settings.locationName}. Move within '
          '${formatDistance(settings.radiusMeters.toDouble())} of it and try '
          'again.',
          code: ClockErrorCode.outsideGeofence,
        );
      }
      if (!status.accuracyAcceptable) {
        throw AppError(
          'Your location is only accurate to '
          '${formatDistance(status.accuracyMeters)}. Move somewhere with a '
          'better signal and try again.',
          code: ClockErrorCode.poorAccuracy,
        );
      }

      if (settings.requirePasskey) {
        // The prompt offers every passkey on the device. With none of your
        // own, the only thing you could pick is a colleague's, so stop here
        // rather than starting a ceremony that cannot legitimately succeed.
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
        // Uncapped: the camera sheet is someone framing a photo, and it has
        // its own cancel button.
        _setProgress('Waiting for your photo…');
        // Only reachable if the session dropped, since navigation is locked.
        // Fail rather than return, so the attempt never ends in silence.
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
      await withStepTimeout(
        _container.read(attendanceRepositoryProvider).clockIn(
          latitude: fix.latitude,
          longitude: fix.longitude,
          accuracyMeters: fix.accuracyMeters,
          selfiePath: selfiePath,
        ),
        limit: _writeLimit,
        message:
            'We could not confirm your clock-in in time. Pull to refresh in a '
            'moment to check whether it went through.',
        code: ClockErrorCode.stepTimeout,
      );

      _refreshRecords();
      if (mounted) showSnack(context, 'Clocked in. Have a good shift.');
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      _finish();
    }
  }

  Future<void> _clockOut(OrgSettings settings) async {
    setState(() => _error = null);
    _setProgress('Checking your location…');

    try {
      LocationFix? fix;
      try {
        fix = await withStepTimeout(
          _locationFix(),
          limit: _locationLimit,
          message:
              'Could not pin down where you are. Move near a window or step '
              'outside, then try again.',
          code: ClockErrorCode.stepTimeout,
        );
      } catch (error) {
        // Clocking out may be allowed without a fix; let the server decide.
        if (!settings.allowClockOutOutsideGeofence) throw toAppError(error);
      }

      _setProgress('Recording your clock-out…');
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

      _refreshRecords();
      if (mounted) showSnack(context, 'Clocked out. See you tomorrow.');
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      _finish();
    }
  }

  void _refreshRecords() {
    _container
      ..invalidate(myTodayRecordProvider)
      ..invalidate(myHistoryProvider);
  }

  void _finish() => _container.read(clockBusyProvider.notifier).clear();

  void _refresh() {
    ref.invalidate(locationStreamProvider);
    ref.invalidate(myTodayRecordProvider);
    ref.invalidate(orgSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(orgSettingsProvider);
    final today = ref.watch(myTodayRecordProvider);
    final me = ref.watch(myProfileProvider).value;
    final firstName = me?.displayName.split(' ').first;

    return FScaffold(
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
          value: today,
          onRetry: () => ref.invalidate(myTodayRecordProvider),
          builder: (record) => PagePadding(
            child: !settingsData.isGeofenceConfigured
                ? const _NotConfiguredNotice()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // The action comes first: on a phone this is the only
                      // thing most people open the app to do.
                      _HeroPanel(
                        record: record,
                        settings: settingsData,
                        progress: _progress,
                        busy: _busy,
                        onClockIn: () => _clockIn(settingsData),
                        onClockOut: () => _clockOut(settingsData),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: gutter),
                        ErrorNotice(error: AppError(_error!)),
                      ],
                      const SizedBox(height: gutter),
                      _LocationCard(settings: settingsData),
                      if (record != null) ...[
                        const SizedBox(height: gutter),
                        _ShiftCard(record: record),
                      ],
                      const SizedBox(height: gutter),
                      _RequirementsSection(settings: settingsData),
                    ],
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
          'An administrator still needs to mark your work location on the '
          'map. You will be able to clock in once that is done.',
    ),
  );
}

/// The headline state of the day plus the one button that acts on it.
class _HeroPanel extends ConsumerWidget {
  const _HeroPanel({
    required this.record,
    required this.settings,
    required this.progress,
    required this.busy,
    required this.onClockIn,
    required this.onClockOut,
  });

  final AttendanceRecord? record;
  final OrgSettings settings;
  final String? progress;
  final bool busy;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final done = record != null && !record!.isOpen;
    final isClockOut = record != null && record!.isOpen;

    final fix = ref.watch(locationStreamProvider).value;
    final status = fix == null ? null : GeofenceStatus.from(settings, fix);

    // Clocking out may be permitted from anywhere, depending on settings.
    final locationOk = isClockOut
        ? settings.allowClockOutOutsideGeofence || (status?.canClockIn ?? false)
        : (status?.canClockIn ?? false);

    // With no passkey of their own, the only credential the prompt could offer
    // is a colleague's, so there is nothing this person can legitimately prove.
    final needsPasskey =
        !isClockOut &&
        settings.requirePasskey &&
        (ref.watch(myPasskeysProvider).value?.isEmpty ?? false);

    return ContentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(formatDay(DateTime.now()), style: theme.mutedStyle),
              ),
              if (done)
                const StatusChip(
                  label: 'Complete',
                  icon: FLucideIcons.check,
                  tone: ChipTone.neutral,
                )
              else if (isClockOut)
                const StatusChip(
                  label: 'On shift',
                  icon: FLucideIcons.clock,
                  tone: ChipTone.positive,
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (done)
            _HeroFigure(
              label: 'Worked today',
              value: formatDuration(record!.workedDuration),
            )
          else if (isClockOut)
            _LiveElapsed(since: record!.clockInAt)
          else
            _HeroFigure(label: 'Right now', value: formatTime(DateTime.now())),
          const SizedBox(height: 20),
          if (done)
            FAlert(
              icon: const Icon(FLucideIcons.partyPopper),
              title: const Text('Your attendance for today is complete.'),
            )
          else
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
          if (!done && !busy && (!locationOk || needsPasskey)) ...[
            const SizedBox(height: 10),
            Text(
              needsPasskey
                  ? 'Add your own passkey below before you can clock in.'
                  : status == null
                  ? 'Waiting for your location before you can '
                        '${isClockOut ? 'clock out' : 'clock in'}.'
                  : 'Move inside the clock-in zone to enable this button.',
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
    value: formatElapsed(DateTime.now().difference(widget.since)),
  );
}

/// Live distance readout, refreshed from the browser's geolocation watcher.
class _LocationCard extends ConsumerWidget {
  const _LocationCard({required this.settings});

  final OrgSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final fix = ref.watch(locationStreamProvider);

    return SectionCard(
      title: 'Your location',
      subtitle:
          '${settings.locationName} · '
          '${formatDistance(settings.radiusMeters.toDouble())} radius',
      trailing: FButton.icon(
        variant: FButtonVariant.primary,
        size: FButtonSizeVariant.sm,
        onPress: () => ref.invalidate(locationStreamProvider),
        semanticsLabel: 'Recheck location',
        child: const Icon(FLucideIcons.locateFixed),
      ),
      children: [
        fix.when(
          skipLoadingOnRefresh: false,
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
          data: (data) {
            final status = GeofenceStatus.from(settings, data);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      status.isInside
                          ? FLucideIcons.circleCheck
                          : FLucideIcons.circleAlert,
                      size: 18,
                      color: status.isInside
                          ? theme.colors.primary
                          : theme.colors.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        status.isInside
                            ? 'You are inside the clock-in zone, '
                                  '${formatDistance(status.distanceMeters)} '
                                  'from the centre.'
                            : 'You are '
                                  '${formatDistance(status.metersOutside)} '
                                  'outside the zone.',
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
                      label: status.isInside ? 'In zone' : 'Out of zone',
                      icon: status.isInside
                          ? FLucideIcons.mapPin
                          : FLucideIcons.mapPinOff,
                      tone: status.canClockIn
                          ? ChipTone.positive
                          : ChipTone.negative,
                    ),
                    StatusChip(
                      label:
                          'Accuracy ${formatDistance(status.accuracyMeters)}',
                      icon: FLucideIcons.crosshair,
                      tone: status.accuracyAcceptable
                          ? ChipTone.neutral
                          : ChipTone.warning,
                    ),
                  ],
                ),
                if (!status.accuracyAcceptable) ...[
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

/// Times and verification evidence for today's record.
class _ShiftCard extends StatelessWidget {
  const _ShiftCard({required this.record});

  final AttendanceRecord record;

  @override
  Widget build(BuildContext context) => FTileGroup(
    label: const Text("Today's shift"),
    children: [
      FTile(
        prefix: const TileIcon(FLucideIcons.logIn),
        title: const Text('Clocked in'),
        details: Text(formatTime(record.clockInAt)),
      ),
      FTile(
        prefix: const TileIcon(FLucideIcons.logOut),
        title: const Text('Clocked out'),
        details: Text(formatTime(record.clockOutAt)),
      ),
      if (record.verifiedWithPasskey)
        FTile(
          prefix: const TileIcon(FLucideIcons.fingerprint),
          title: const Text('Passkey'),
          details: const Text('Verified'),
        ),
      if (record.verifiedWithSelfie)
        FTile(
          prefix: const TileIcon(FLucideIcons.camera),
          title: const Text('Live photo'),
          details: const Text('Captured'),
        ),
    ],
  );
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
