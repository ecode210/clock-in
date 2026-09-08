import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/app_error.dart';
import '../../core/formatters.dart';
import '../../models/org_settings.dart';
import '../../routing/router.dart';
import '../../services/location_service.dart';
import '../../services/settings_repository.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';
import 'timezone_picker.dart';

/// Where the geofence is actually configured: drop a pin, drag the radius,
/// save. Kept deliberately visual so it can be set up without knowing what a
/// coordinate is.
class GeofenceSettingsScreen extends ConsumerWidget {
  const GeofenceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(orgSettingsProvider);

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('Clock-in zone'),
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(AppRoutes.adminSettings),
          ),
        ],
      ),
      child: AsyncSection(
        value: settings,
        onRetry: () => ref.invalidate(orgSettingsProvider),
        // Keyed so the editor resets its draft if the row changes underneath.
        builder: (data) => _GeofenceEditor(
          key: ValueKey('${data.geofenceLat},${data.geofenceLng}'),
          initial: data,
        ),
      ),
    );
  }
}

class _GeofenceEditor extends ConsumerStatefulWidget {
  const _GeofenceEditor({required this.initial, super.key});

  final OrgSettings initial;

  @override
  ConsumerState<_GeofenceEditor> createState() => _GeofenceEditorState();
}

class _GeofenceEditorState extends ConsumerState<_GeofenceEditor> {
  static const _fallbackCenter = LatLng(6.5244, 3.3792);
  static const _minRadius = 10.0;
  static const _maxRadius = 1000.0;

  final _mapController = MapController();
  late final TextEditingController _orgNameController;
  late final TextEditingController _locationNameController;

  late LatLng? _center;
  late double _radius;
  late String _timezone;
  late int? _maxAccuracy;

  bool _saving = false;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _orgNameController = TextEditingController(text: widget.initial.orgName);
    _locationNameController = TextEditingController(
      text: widget.initial.locationName,
    );
    _center = widget.initial.center;
    _radius = widget.initial.radiusMeters.toDouble();
    _timezone = widget.initial.timezone;
    _maxAccuracy = widget.initial.maxAccuracyMeters;
  }

  @override
  void dispose() {
    _orgNameController.dispose();
    _locationNameController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  bool get _isDirty =>
      _center != widget.initial.center ||
      _radius != widget.initial.radiusMeters ||
      _timezone != widget.initial.timezone ||
      _maxAccuracy != widget.initial.maxAccuracyMeters ||
      _orgNameController.text.trim() != widget.initial.orgName ||
      _locationNameController.text.trim() != widget.initial.locationName;

  /// Forui's slider works in fractions of its track, so the radius is mapped
  /// on and off a 0-1 scale here rather than in the widget tree.
  double get _radiusFraction =>
      ((_radius - _minRadius) / (_maxRadius - _minRadius)).clamp(0.0, 1.0);

  double _radiusFromFraction(double fraction) =>
      _minRadius + fraction * (_maxRadius - _minRadius);

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      final fix = await ref.read(locationServiceProvider).currentFix();
      final point = LatLng(fix.latitude, fix.longitude);
      setState(() => _center = point);
      _mapController.move(point, 17);
      if (mounted) {
        showSnack(
          context,
          'Pin moved to your position '
          '(accurate to ${formatDistance(fix.accuracyMeters)}).',
        );
      }
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    final center = _center;
    if (center == null) {
      showSnack(
        context,
        'Tap the map to place the clock-in pin first.',
        isError: true,
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await ref.read(settingsRepositoryProvider).save(
        widget.initial.copyWith(
          orgName: _orgNameController.text.trim().isEmpty
              ? widget.initial.orgName
              : _orgNameController.text.trim(),
          locationName: _locationNameController.text.trim().isEmpty
              ? widget.initial.locationName
              : _locationNameController.text.trim(),
          timezone: _timezone,
          radiusMeters: _radius.round(),
          geofenceLat: center.latitude,
          geofenceLng: center.longitude,
          maxAccuracyMeters: _maxAccuracy,
          clearMaxAccuracy: _maxAccuracy == null,
        ),
      );
      ref.invalidate(orgSettingsProvider);
      if (mounted) showSnack(context, 'Clock-in zone saved.');
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final center = _center;

    return PagePadding(
      maxWidth: 700,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: 'Where staff may clock in',
            subtitle: center == null
                ? 'Tap the map to drop the pin on your site, then set how far '
                      'from it staff may clock in.'
                : 'Tap the map to move the pin, or drag the slider to resize '
                      'the zone.',
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 300,
                  child: Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: center ?? _fallbackCenter,
                          initialZoom: center == null ? 12 : 17,
                          onTap: (_, point) => setState(() => _center = point),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.clock_in',
                            maxNativeZoom: 19,
                          ),
                          if (center != null)
                            CircleLayer(
                              circles: [
                                CircleMarker(
                                  point: center,
                                  radius: _radius,
                                  useRadiusInMeter: true,
                                  color: theme.colors.primary.withValues(
                                    alpha: 0.18,
                                  ),
                                  borderColor: theme.colors.primary,
                                  borderStrokeWidth: 2,
                                ),
                              ],
                            ),
                          if (center != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: center,
                                  width: 32,
                                  height: 32,
                                  alignment: Alignment.topCenter,
                                  child: Icon(
                                    FLucideIcons.mapPin,
                                    size: 32,
                                    color: theme.colors.error,
                                  ),
                                ),
                              ],
                            ),
                          const _OsmAttribution(),
                        ],
                      ),
                      if (center == null)
                        Positioned(
                          left: 12,
                          top: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colors.destructive,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Tap the map to place the pin',
                              style: theme.typography.body.sm.copyWith(
                                color: theme.colors.destructiveForeground,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FButton(
                variant: FButtonVariant.outline,
                onPress: _locating ? null : _useMyLocation,
                prefix: const Icon(FLucideIcons.locateFixed),
                child: ButtonLabel(
                  _locating ? 'Locating…' : 'Use my location',
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: Text('Radius', style: theme.titleStyle)),
                  Text(
                    formatDistance(_radius),
                    style: theme.titleStyle.copyWith(
                      color: theme.colors.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FSlider(
                control: FSliderControl.managedContinuous(
                  initial: FSliderValue(max: _radiusFraction),
                  onChange: (value) => setState(
                    () => _radius = _radiusFromFraction(value.max),
                  ),
                ),
                tooltipBuilder: (_, fraction) =>
                    Text(formatDistance(_radiusFromFraction(fraction))),
                semanticValueFormatterCallback: (fraction) =>
                    formatDistance(_radiusFromFraction(fraction)),
              ),
              const SizedBox(height: 12),
              Text(
                'A tighter radius is harder to game, but browser GPS is often '
                'only accurate to 20-50 m indoors. 100 m is a sensible '
                'starting point for a single building or small site.',
                style: theme.captionStyle,
              ),
              if (center != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Pin: ${center.latitude.toStringAsFixed(6)}, '
                  '${center.longitude.toStringAsFixed(6)}',
                  style: theme.captionStyle,
                ),
              ],
            ],
          ),
          const SizedBox(height: gutter),
          SectionCard(
            title: 'Naming and timing',
            subtitle:
                'Shown to staff, and used to decide which day a clock-in '
                'belongs to.',
            children: [
              FTextField(
                control: FTextFieldControl.managed(
                  controller: _orgNameController,
                  onChange: (_) => setState(() {}),
                ),
                label: const Text('Organisation name'),
              ),
              const SizedBox(height: 12),
              FTextField(
                control: FTextFieldControl.managed(
                  controller: _locationNameController,
                  onChange: (_) => setState(() {}),
                ),
                label: const Text('Site name'),
                description: const Text(
                  'For example "Main Building" or "North Yard".',
                ),
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
            ],
          ),
          const SizedBox(height: gutter),
          _AccuracyCard(
            value: _maxAccuracy,
            onChanged: (value) => setState(() => _maxAccuracy = value),
          ),
          const SizedBox(height: 20),
          FButton(
            size: FButtonSizeVariant.lg,
            onPress: (_saving || !_isDirty) ? null : _save,
            prefix: _saving ? const FCircularProgress() : null,
            child: ButtonLabel(
              _saving
                  ? 'Saving…'
                  : _isDirty
                  ? 'Save clock-in zone'
                  : 'Saved',
            ),
          ),
        ],
      ),
    );
  }
}

/// Rejecting low-confidence GPS readings closes an easy loophole: a device
/// reporting a 2 km error radius could otherwise "just about" be in the zone.
class _AccuracyCard extends StatelessWidget {
  const _AccuracyCard({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int?> onChanged;

  /// `FSelect` keys items by value, so "no limit" needs a value rather than
  /// null. Zero is safe: a limit of zero metres would reject everything.
  static const _noLimit = 0;
  static const _options = <int>[_noLimit, 25, 50, 100, 250];

  static String _label(int option) =>
      option == _noLimit ? 'No limit' : 'Within $option m';

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'GPS accuracy limit',
      subtitle:
          'Refuse clock-ins when the device is not confident about its '
          'position.',
      children: [
        FSelect<int>(
          items: {for (final option in _options) _label(option): option},
          control: FSelectControl.lifted(
            value: value ?? _noLimit,
            onChange: (selected) =>
                onChanged(selected == null || selected == _noLimit
                    ? null
                    : selected),
          ),
          label: const Text('Reject readings worse than'),
        ),
      ],
    );
  }
}

class _OsmAttribution extends StatelessWidget {
  const _OsmAttribution();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: BoxDecoration(color: Color(0xCCFFFFFF)),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(
              '© OpenStreetMap contributors',
              style: TextStyle(fontSize: 10, color: Color(0xFF333333)),
            ),
          ),
        ),
      ),
    );
  }
}
