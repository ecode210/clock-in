import '../../models/org_settings.dart';
import '../../services/location_service.dart';

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
  });

  factory GeofenceStatus.from(OrgSettings settings, LocationFix fix) {
    final distance = fix.distanceTo(
      settings.geofenceLat!,
      settings.geofenceLng!,
    );
    final maxAccuracy = settings.maxAccuracyMeters;

    return GeofenceStatus(
      distanceMeters: distance,
      radiusMeters: settings.radiusMeters,
      accuracyMeters: fix.accuracyMeters,
      isInside: distance <= settings.radiusMeters,
      accuracyAcceptable:
          maxAccuracy == null || fix.accuracyMeters <= maxAccuracy,
    );
  }

  final double distanceMeters;
  final int radiusMeters;
  final double accuracyMeters;
  final bool isInside;
  final bool accuracyAcceptable;

  bool get canClockIn => isInside && accuracyAcceptable;

  /// How far past the boundary the user is, for the "move closer" hint.
  double get metersOutside =>
      isInside ? 0 : distanceMeters - radiusMeters;
}
