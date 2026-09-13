import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/app_error.dart';
import '../../core/formatters.dart';
import '../../models/clock_location.dart';
import '../../routing/router.dart';
import '../../services/location_service.dart';
import '../../services/locations_repository.dart';
import '../shared/widgets.dart';

/// Add or edit one clock-in site: pin, radius, and name.
class LocationEditorScreen extends ConsumerWidget {
  const LocationEditorScreen({this.locationId, super.key});

  /// Null means create a new location.
  final String? locationId;

  bool get _isNew => locationId == null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_isNew) {
      return _EditorScaffold(
        title: 'New location',
        child: _LocationEditor(initial: null),
      );
    }

    final locations = ref.watch(locationsProvider);
    return AppScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('Edit location'),
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(AppRoutes.adminLocations),
          ),
        ],
      ),
      child: AsyncSection(
        value: locations,
        onRetry: () => ref.invalidate(locationsProvider),
        builder: (items) {
          final match = items.where((l) => l.id == locationId).firstOrNull;
          if (match == null) {
            return PagePadding(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FAlert(
                    variant: FAlertVariant.destructive,
                    title: Text('That location could not be found.'),
                  ),
                  const SizedBox(height: 12),
                  FButton(
                    onPress: () => context.go(AppRoutes.adminLocations),
                    child: const ButtonLabel('Back to locations'),
                  ),
                ],
              ),
            );
          }
          return _LocationEditor(
            key: ValueKey('${match.id}-${match.lat}-${match.lng}'),
            initial: match,
          );
        },
      ),
    );
  }
}

class _EditorScaffold extends StatelessWidget {
  const _EditorScaffold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      childPad: false,
      header: FHeader.nested(
        title: Text(title),
        prefixes: [
          FHeaderAction.back(
            onPress: () => context.go(AppRoutes.adminLocations),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _LocationEditor extends ConsumerStatefulWidget {
  const _LocationEditor({required this.initial, super.key});

  final ClockLocation? initial;

  @override
  ConsumerState<_LocationEditor> createState() => _LocationEditorState();
}

class _LocationEditorState extends ConsumerState<_LocationEditor> {
  static const _fallbackCenter = LatLng(6.5244, 3.3792);
  static const _minRadius = 10.0;
  static const _maxRadius = 1000.0;

  final _mapController = MapController();
  late final FContinuousSliderController _radiusController;
  late final TextEditingController _nameController;

  late LatLng? _center;
  late double _radius;
  bool _saving = false;
  bool _locating = false;
  bool _archiving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _center = initial?.center;
    _radius = (initial?.radiusMeters ?? 100).toDouble();
    _radiusController = FContinuousSliderController(
      value: FSliderValue(max: _radiusFraction),
    );
  }

  @override
  void dispose() {
    _radiusController.dispose();
    _nameController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  bool get _isNew => widget.initial == null;

  bool get _isDirty {
    final initial = widget.initial;
    if (initial == null) {
      return _center != null || _nameController.text.trim().isNotEmpty;
    }
    return _center != initial.center ||
        _radius != initial.radiusMeters ||
        _nameController.text.trim() != initial.name;
  }

  double get _radiusFraction =>
      ((_radius - _minRadius) / (_maxRadius - _minRadius)).clamp(0.0, 1.0);

  double _radiusFromFraction(double fraction) =>
      _minRadius + fraction * (_maxRadius - _minRadius);

  void _onRadiusChange(FSliderValue value) {
    final next = _radiusFromFraction(value.max);
    if (next == _radius) return;

    void apply() {
      if (!mounted) return;
      final latest = _radiusFromFraction(_radiusController.value.max);
      if (latest == _radius) return;
      setState(() => _radius = latest);
    }

    switch (SchedulerBinding.instance.schedulerPhase) {
      case SchedulerPhase.idle:
      case SchedulerPhase.postFrameCallbacks:
        apply();
      case SchedulerPhase.transientCallbacks:
      case SchedulerPhase.midFrameMicrotasks:
      case SchedulerPhase.persistentCallbacks:
        WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    }
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      final fix = await ref.read(locationServiceProvider).currentFix();
      if (!mounted) return;
      final point = LatLng(fix.latitude, fix.longitude);
      setState(() => _center = point);
      _mapController.move(point, 17);
      showSnack(
        context,
        'Pin moved to your position '
        '(accurate to ${formatDistance(fix.accuracyMeters)}).',
      );
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    final center = _center;
    final name = _nameController.text.trim();
    if (center == null) {
      showSnack(
        context,
        'Tap the map to place the clock-in pin first.',
        isError: true,
      );
      return;
    }
    if (name.isEmpty) {
      showSnack(context, 'Give this location a name.', isError: true);
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(locationsRepositoryProvider);
      if (_isNew) {
        await repo.create(
          name: name,
          lat: center.latitude,
          lng: center.longitude,
          radiusMeters: _radius.round(),
        );
      } else {
        await repo.update(
          widget.initial!.copyWith(
            name: name,
            lat: center.latitude,
            lng: center.longitude,
            radiusMeters: _radius.round(),
          ),
        );
      }
      ref.invalidate(locationsProvider);
      ref.invalidate(activeLocationsProvider);
      if (!mounted) return;
      showSnack(
        context,
        _isNew ? 'Location added.' : 'Location saved.',
      );
      context.go(AppRoutes.adminLocations);
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _archive() async {
    final initial = widget.initial;
    if (initial == null) return;

    final confirmed = await confirmAction(
      context,
      title: 'Archive ${initial.name}?',
      message:
          'Staff will no longer be able to clock in here. Past attendance '
          'still shows this name.',
      confirmLabel: 'Archive',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _archiving = true);
    try {
      await ref.read(locationsRepositoryProvider).archive(initial.id);
      ref.invalidate(locationsProvider);
      ref.invalidate(activeLocationsProvider);
      if (!mounted) return;
      showSnack(context, 'Location archived.');
      context.go(AppRoutes.adminLocations);
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  Future<void> _restore() async {
    final initial = widget.initial;
    if (initial == null) return;

    setState(() => _archiving = true);
    try {
      await ref.read(locationsRepositoryProvider).restore(initial.id);
      ref.invalidate(locationsProvider);
      ref.invalidate(activeLocationsProvider);
      if (!mounted) return;
      showSnack(context, 'Location restored.');
      context.go(AppRoutes.adminLocations);
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final center = _center;
    final initial = widget.initial;

    return PagePadding(
      maxWidth: 700,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: 'Where staff may clock in',
            subtitle: center == null
                ? 'Tap the map to drop the pin on this site, then set how far '
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
                  controller: _radiusController,
                  onChange: _onRadiusChange,
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
            title: 'Name',
            children: [
              FTextField(
                control: FTextFieldControl.managed(
                  controller: _nameController,
                  onChange: (_) => setState(() {}),
                ),
                label: const Text('Site name'),
                description: const Text(
                  'For example "Main Building" or "North Yard".',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          FButton(
            size: FButtonSizeVariant.lg,
            onPress: (_saving || !_isDirty) ? null : _save,
            prefix: _saving ? const FCircularProgress() : null,
            child: ButtonLabel(
              _saving
                  ? 'Saving…'
                  : _isNew
                  ? 'Add location'
                  : _isDirty
                  ? 'Save location'
                  : 'Saved',
            ),
          ),
          if (initial != null) ...[
            const SizedBox(height: 10),
            if (initial.isActive)
              FButton(
                variant: FButtonVariant.destructive,
                onPress: _archiving ? null : _archive,
                prefix: _archiving ? const FCircularProgress() : null,
                child: ButtonLabel(
                  _archiving ? 'Working…' : 'Archive location',
                ),
              )
            else
              FButton(
                variant: FButtonVariant.outline,
                onPress: _archiving ? null : _restore,
                prefix: _archiving ? const FCircularProgress() : null,
                child: ButtonLabel(
                  _archiving ? 'Working…' : 'Restore location',
                ),
              ),
          ],
        ],
      ),
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
