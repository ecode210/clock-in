import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_error.dart';
import '../../models/org_settings.dart';
import '../../routing/router.dart';
import '../../services/settings_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

/// Fraud prevention is a policy decision, not a build-time one: the two checks
/// can be used together, individually, or not at all. `clock_in` reads the same
/// row, so switching one on takes effect immediately and cannot be bypassed by
/// an out-of-date browser tab.
class SecuritySettingsScreen extends ConsumerWidget {
  const SecuritySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(orgSettingsProvider);

    return AppScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('Verification'),
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(AppRoutes.adminSettings),
          ),
        ],
      ),
      child: AsyncSection(
        value: settings,
        onRetry: () => ref.invalidate(orgSettingsProvider),
        builder: (data) => _SecurityForm(settings: data),
      ),
    );
  }
}

class _SecurityForm extends ConsumerStatefulWidget {
  const _SecurityForm({required this.settings});

  final OrgSettings settings;

  @override
  ConsumerState<_SecurityForm> createState() => _SecurityFormState();
}

class _SecurityFormState extends ConsumerState<_SecurityForm> {
  String? _pendingField;

  /// Each toggle saves on its own so the admin never has to remember to press
  /// a save button for a security setting.
  Future<void> _patch(String field, Map<String, dynamic> changes) async {
    setState(() => _pendingField = field);
    try {
      await ref.read(settingsRepositoryProvider).patch(changes);
      ref.invalidate(orgSettingsProvider);
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _pendingField = null);
    }
  }

  bool _isBusy(String field) => _pendingField == field;
  bool get _anyBusy => _pendingField != null;

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final theme = context.theme;
    final activeChecks = [
      if (settings.requirePasskey) 'passkey',
      if (settings.requireSelfie) 'live photo',
    ];

    return PagePadding(
      maxWidth: 700,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryAlert(activeChecks: activeChecks),
          const SizedBox(height: gutter),
          FTileGroup(
            label: const Text('Identity checks at clock-in'),
            description: const Text(
              'Location is always checked. These add proof that the right '
              'person is the one standing there.',
            ),
            children: [
              FTile(
                prefix: const TileIcon(FLucideIcons.fingerprint),
                title: const Text('Require a passkey'),
                subtitle: const TileSubtitle(
                  'Staff confirm with the fingerprint or face unlock on their '
                  'own device every time they clock in.',
                ),
                suffix: FSwitch(
                  value: settings.requirePasskey,
                  enabled: !_anyBusy,
                  onChange: (value) =>
                      _patch('passkey', {'require_passkey': value}),
                ),
              ),
              FTile(
                prefix: const TileIcon(FLucideIcons.camera),
                title: const Text('Require a live photo'),
                subtitle: const TileSubtitle(
                  'A photo is taken from the camera at the moment of clock-in '
                  'and attached to the record for you to review.',
                ),
                suffix: FSwitch(
                  value: settings.requireSelfie,
                  enabled: !_anyBusy,
                  onChange: (value) =>
                      _patch('selfie', {'require_selfie': value}),
                ),
              ),
            ],
          ),
          if (settings.requirePasskey) ...[
            const SizedBox(height: gutter),
            _FreshnessCard(
              value: settings.passkeyFreshnessSeconds,
              busy: _isBusy('freshness'),
              onChanged: (value) =>
                  _patch('freshness', {'passkey_freshness_seconds': value}),
            ),
          ],
          const SizedBox(height: gutter),
          FTileGroup(
            label: const Text('Clock-out'),
            children: [
              FTile(
                prefix: const TileIcon(FLucideIcons.doorOpen),
                title: const Text('Allow clocking out from anywhere'),
                subtitle: const TileSubtitle(
                  'Useful when staff forget to clock out before leaving. '
                  'Clock-in always requires being on site.',
                ),
                suffix: FSwitch(
                  value: settings.allowClockOutOutsideGeofence,
                  enabled: !_anyBusy,
                  onChange: (value) => _patch('clockout', {
                    'allow_clock_out_outside_geofence': value,
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: gutter),
          ContentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      FLucideIcons.circleAlert,
                      size: 18,
                      color: theme.colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Before switching on passkeys',
                        style: theme.titleStyle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Staff can only pass the passkey check once they have '
                  'registered one from their account page. Give them a chance '
                  'to enrol first, or they will not be able to clock in. '
                  'Passkeys also need the site to be served over HTTPS.',
                  style: theme.mutedStyle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryAlert extends StatelessWidget {
  const _SummaryAlert({required this.activeChecks});

  final List<String> activeChecks;

  @override
  Widget build(BuildContext context) {
    final isStrict = activeChecks.isNotEmpty;

    final message = switch (activeChecks.length) {
      0 =>
        'Only location is checked. Anyone with a staff password could clock '
            'in for a colleague who is on site.',
      1 => 'Location plus ${activeChecks.first} is checked at every clock-in.',
      _ =>
        'Location, ${activeChecks.first} and ${activeChecks.last} are all '
            'checked at every clock-in.',
    };

    return FAlert(
      variant: isStrict ? FAlertVariant.primary : FAlertVariant.destructive,
      icon: Icon(
        isStrict ? FLucideIcons.shieldCheck : FLucideIcons.triangleAlert,
      ),
      title: Text(isStrict ? 'Verification is on' : 'Location only'),
      subtitle: Text(message),
    );
  }
}

/// How recently the passkey ceremony must have happened for `clock_in` to
/// accept it. Short windows force a fresh biometric prompt each time.
class _FreshnessCard extends StatelessWidget {
  const _FreshnessCard({
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final int value;
  final bool busy;
  final ValueChanged<int> onChanged;

  static const _options = {
    '1 minute': 60,
    '5 minutes': 300,
    '15 minutes': 900,
    '1 hour': 3600,
  };

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Passkey freshness',
      subtitle:
          'Shorter is stricter. Staff are prompted again if their last '
          'passkey check is older than this.',
      children: [
        FSelect<int>(
          items: _options,
          control: FSelectControl.lifted(
            value: value,
            onChange: (selected) {
              if (selected != null) onChanged(selected);
            },
          ),
          label: const Text('Passkey must have been used within'),
          enabled: !busy,
        ),
      ],
    );
  }
}
