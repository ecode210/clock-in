import 'package:clock_in/src/features/staff/geofence_status.dart';
import 'package:clock_in/src/models/org_settings.dart';
import 'package:clock_in/src/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

OrgSettings _settings({int radius = 100, int? maxAccuracy}) => OrgSettings(
  orgName: 'Test Org',
  locationName: 'Main Site',
  timezone: 'UTC',
  radiusMeters: radius,
  requireSelfie: false,
  requirePasskey: false,
  passkeyFreshnessSeconds: 300,
  allowClockOutOutsideGeofence: false,
  geofenceLat: 6.5244,
  geofenceLng: 3.3792,
  maxAccuracyMeters: maxAccuracy,
);

LocationFix _fix({
  double lat = 6.5244,
  double lng = 3.3792,
  double accuracy = 10,
}) => LocationFix(
  latitude: lat,
  longitude: lng,
  accuracyMeters: accuracy,
  timestamp: DateTime.utc(2026, 1, 1),
);

void main() {
  group('GeofenceStatus', () {
    test('standing on the pin is inside the zone', () {
      final status = GeofenceStatus.from(_settings(), _fix());

      expect(status.distanceMeters, lessThan(1));
      expect(status.isInside, isTrue);
      expect(status.canClockIn, isTrue);
      expect(status.metersOutside, 0);
    });

    test('just outside the radius is rejected', () {
      // ~0.0018 degrees of latitude is a little over 200 m.
      final status = GeofenceStatus.from(
        _settings(radius: 100),
        _fix(lat: 6.5262),
      );

      expect(status.isInside, isFalse);
      expect(status.canClockIn, isFalse);
      expect(status.metersOutside, greaterThan(90));
    });

    test('a poor GPS fix blocks clock-in even when inside the zone', () {
      final status = GeofenceStatus.from(
        _settings(maxAccuracy: 50),
        _fix(accuracy: 400),
      );

      expect(status.isInside, isTrue);
      expect(status.accuracyAcceptable, isFalse);
      expect(status.canClockIn, isFalse);
    });

    test('no accuracy limit accepts any fix inside the zone', () {
      final status = GeofenceStatus.from(_settings(), _fix(accuracy: 900));

      expect(status.accuracyAcceptable, isTrue);
      expect(status.canClockIn, isTrue);
    });
  });
}
