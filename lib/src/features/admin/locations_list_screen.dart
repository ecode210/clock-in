import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_error.dart';
import '../../core/formatters.dart';
import '../../models/clock_location.dart';
import '../../models/org_settings.dart';
import '../../routing/router.dart';
import '../../services/locations_repository.dart';
import '../../services/settings_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';
import 'timezone_picker.dart';

/// Organisation settings that used to sit on the single-zone page, plus the
/// list of clock-in sites.
class LocationsListScreen extends ConsumerWidget {
  const LocationsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(orgSettingsProvider);
    final locations = ref.watch(locationsProvider);

    return AppScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('Clock-in locations'),
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(AppRoutes.adminSettings),
          ),
        ],
      ),
      child: AsyncSection(
        value: settings,
        onRetry: () => ref.invalidate(orgSettingsProvider),
        builder: (settingsData) => AsyncSection(
          value: locations,
          onRetry: () => ref.invalidate(locationsProvider),
          builder: (items) => PagePadding(
            maxWidth: 700,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OrganisationCard(settings: settingsData),
                const SizedBox(height: gutter),
                _AccuracyCard(settings: settingsData),
                const SizedBox(height: gutter),
                _LocationsSection(locations: items),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OrganisationCard extends ConsumerStatefulWidget {
  const _OrganisationCard({required this.settings});

  final OrgSettings settings;

  @override
  ConsumerState<_OrganisationCard> createState() => _OrganisationCardState();
}

class _OrganisationCardState extends ConsumerState<_OrganisationCard> {
  late final TextEditingController _orgNameController;
  late String _timezone;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _orgNameController = TextEditingController(text: widget.settings.orgName);
    _timezone = widget.settings.timezone;
  }

  @override
  void dispose() {
    _orgNameController.dispose();
    super.dispose();
  }

  bool get _isDirty =>
      _orgNameController.text.trim() != widget.settings.orgName ||
      _timezone != widget.settings.timezone;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsRepositoryProvider).save(
        widget.settings.copyWith(
          orgName: _orgNameController.text.trim().isEmpty
              ? widget.settings.orgName
              : _orgNameController.text.trim(),
          timezone: _timezone,
        ),
      );
      ref.invalidate(orgSettingsProvider);
      if (mounted) showSnack(context, 'Organisation details saved.');
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return SectionCard(
      title: 'Organisation',
      subtitle:
          'Shown to staff, and used to decide which day a clock-in belongs to.',
      children: [
        FTextField(
          control: FTextFieldControl.managed(
            controller: _orgNameController,
            onChange: (_) => setState(() {}),
          ),
          label: const Text('Organisation name'),
        ),
        const SizedBox(height: 12),
        TimezonePicker(
          value: _timezone,
          onChanged: (value) => setState(() => _timezone = value),
        ),
        const SizedBox(height: 8),
        Text(
          'The working day rolls over at midnight in this timezone.',
          style: theme.captionStyle,
        ),
        const SizedBox(height: 16),
        FButton(
          onPress: (_saving || !_isDirty) ? null : _save,
          prefix: _saving ? const FCircularProgress() : null,
          child: ButtonLabel(_saving ? 'Saving…' : 'Save organisation'),
        ),
      ],
    );
  }
}

class _AccuracyCard extends ConsumerStatefulWidget {
  const _AccuracyCard({required this.settings});

  final OrgSettings settings;

  @override
  ConsumerState<_AccuracyCard> createState() => _AccuracyCardState();
}

class _AccuracyCardState extends ConsumerState<_AccuracyCard> {
  bool _busy = false;

  static const _noLimit = 0;
  static const _options = <int>[_noLimit, 25, 50, 100, 250];

  static String _label(int option) =>
      option == _noLimit ? 'No limit' : 'Within $option m';

  Future<void> _save(int? value) async {
    setState(() => _busy = true);
    try {
      await ref.read(settingsRepositoryProvider).patch({
        'max_accuracy_meters': value,
      });
      ref.invalidate(orgSettingsProvider);
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'GPS accuracy limit',
      subtitle:
          'Refuse clock-ins when the device is not confident about its '
          'position. Applies to every location.',
      children: [
        FSelect<int>(
          items: {for (final option in _options) _label(option): option},
          control: FSelectControl.lifted(
            value: widget.settings.maxAccuracyMeters ?? _noLimit,
            onChange: (selected) {
              if (_busy) return;
              _save(
                selected == null || selected == _noLimit ? null : selected,
              );
            },
          ),
          label: const Text('Reject readings worse than'),
        ),
      ],
    );
  }
}

class _LocationsSection extends ConsumerWidget {
  const _LocationsSection({required this.locations});

  final List<ClockLocation> locations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = locations.where((l) => l.isActive).toList();
    final archived = locations.where((l) => !l.isActive).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (active.isEmpty)
          const FAlert(
            variant: FAlertVariant.destructive,
            icon: Icon(FLucideIcons.mapPinOff),
            title: Text('No active locations'),
            subtitle: Text(
              'Staff cannot clock in until you add at least one site.',
            ),
          )
        else
          FTileGroup(
            label: Text('${active.length} '
                '${active.length == 1 ? 'location' : 'locations'}'),
            children: [
              for (final location in active)
                FTile(
                  prefix: const TileIcon(FLucideIcons.mapPin),
                  title: Text(location.name),
                  subtitle: Text(
                    '${formatDistance(location.radiusMeters.toDouble())} radius',
                  ),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(
                    AppRoutes.adminLocationEdit(location.id),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 12),
        FButton(
          onPress: () => context.go(AppRoutes.adminLocationNew),
          prefix: const Icon(FLucideIcons.plus),
          child: const ButtonLabel('Add a location'),
        ),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: gutter),
          FTileGroup(
            label: const Text('Archived'),
            children: [
              for (final location in archived)
                FTile(
                  prefix: const TileIcon(FLucideIcons.archive),
                  title: Text(location.name),
                  subtitle: const TileSubtitle(
                    'Hidden from clock-in. Past records still name it.',
                  ),
                  suffix: const Icon(FLucideIcons.chevronRight),
                  onPress: () => context.go(
                    AppRoutes.adminLocationEdit(location.id),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
