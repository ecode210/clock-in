import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/clock_location.dart';
import '../../services/location_service.dart';
import '../../services/locations_repository.dart';
import '../../services/supabase_providers.dart';

/// Client-side view of whether the user may clock in from where they stand.
/// This exists purely to keep the button honest and explain the situation:
/// `clock_in` recomputes all of it server-side because browser coordinates can
/// be faked.
class GeofenceStatus {
  const GeofenceStatus({
    required this.distanceMeters,
    required this.radiusMeters,
    required this.accuracyMeters,
    required this.isInside,
    required this.accuracyAcceptable,
    this.locationName,
  });

  factory GeofenceStatus.fromLocation(
    ClockLocation location,
    LocationFix fix, {
    int? maxAccuracyMeters,
  }) {
    final distance = fix.distanceTo(location.lat, location.lng);

    return GeofenceStatus(
      distanceMeters: distance,
      radiusMeters: location.radiusMeters,
      accuracyMeters: fix.accuracyMeters,
      isInside: distance <= location.radiusMeters,
      accuracyAcceptable:
          maxAccuracyMeters == null || fix.accuracyMeters <= maxAccuracyMeters,
      locationName: location.name,
    );
  }

  final double distanceMeters;
  final int radiusMeters;
  final double accuracyMeters;
  final bool isInside;
  final bool accuracyAcceptable;
  final String? locationName;

  bool get canClockIn => isInside && accuracyAcceptable;

  /// How far past the boundary the user is, for the "move closer" hint.
  double get metersOutside =>
      isInside ? 0 : distanceMeters - radiusMeters;
}

/// Which of [locations] the person is standing inside right now, nearest first.
class InRangeLocations {
  const InRangeLocations({
    required this.matches,
    required this.accuracyAcceptable,
    required this.accuracyMeters,
  });

  factory InRangeLocations.evaluate({
    required List<ClockLocation> locations,
    required LocationFix fix,
    int? maxAccuracyMeters,
  }) {
    final accuracyOk =
        maxAccuracyMeters == null || fix.accuracyMeters <= maxAccuracyMeters;

    final matches = <({ClockLocation location, GeofenceStatus status})>[];
    for (final location in locations) {
      final status = GeofenceStatus.fromLocation(
        location,
        fix,
        maxAccuracyMeters: maxAccuracyMeters,
      );
      if (status.isInside) {
        matches.add((location: location, status: status));
      }
    }
    matches.sort(
      (a, b) => a.status.distanceMeters.compareTo(b.status.distanceMeters),
    );

    return InRangeLocations(
      matches: matches,
      accuracyAcceptable: accuracyOk,
      accuracyMeters: fix.accuracyMeters,
    );
  }

  final List<({ClockLocation location, GeofenceStatus status})> matches;
  final bool accuracyAcceptable;
  final double accuracyMeters;

  bool get isInsideAny => matches.isNotEmpty;

  bool get canClockIn => isInsideAny && accuracyAcceptable;

  List<ClockLocation> get locations =>
      matches.map((m) => m.location).toList(growable: false);
}

/// Shared geofence evaluation for the staff home screen so the hero button and
/// location card do not recompute distances twice per GPS update.
final inRangeLocationsProvider = Provider<AsyncValue<InRangeLocations?>>((
  ref,
) {
  final fixAsync = ref.watch(locationStreamProvider);
  final locationsAsync = ref.watch(activeLocationsProvider);
  final settingsAsync = ref.watch(orgSettingsProvider);

  if (fixAsync.hasError) {
    return AsyncValue.error(fixAsync.error!, fixAsync.stackTrace!);
  }
  if (locationsAsync.hasError) {
    return AsyncValue.error(locationsAsync.error!, locationsAsync.stackTrace!);
  }
  if (settingsAsync.hasError) {
    return AsyncValue.error(settingsAsync.error!, settingsAsync.stackTrace!);
  }

  if (fixAsync.isLoading ||
      locationsAsync.isLoading ||
      settingsAsync.isLoading) {
    return const AsyncValue.loading();
  }

  final fix = fixAsync.value;
  final locations = locationsAsync.value;
  final settings = settingsAsync.value;
  if (fix == null || locations == null || settings == null) {
    return const AsyncValue.data(null);
  }

  return AsyncValue.data(
    InRangeLocations.evaluate(
      locations: locations,
      fix: fix,
      maxAccuracyMeters: settings.maxAccuracyMeters,
    ),
  );
});
