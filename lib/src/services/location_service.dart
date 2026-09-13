import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../core/app_error.dart';
import '../core/dev_log.dart';

/// A location reading paired with how far it is from the configured geofence.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.timestamp,
    this.isMocked = false,
  });

  factory LocationFix.fromPosition(Position position) => LocationFix(
    latitude: position.latitude,
    longitude: position.longitude,
    accuracyMeters: position.accuracy,
    timestamp: position.timestamp,
    isMocked: position.isMocked,
  );

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime timestamp;

  /// The platform says this reading came from a mock provider rather than the
  /// hardware. Only Android reports it; on the web the browser exposes nothing
  /// of the sort, which is why `clock_in` recomputes the geofence server-side
  /// rather than trusting any of this.
  final bool isMocked;

  /// How stale this reading is. Compared in UTC because the browser and the
  /// device may not agree on the local zone.
  Duration get age => DateTime.now().toUtc().difference(timestamp.toUtc());

  double distanceTo(double lat, double lng) =>
      Geolocator.distanceBetween(latitude, longitude, lat, lng);
}

class LocationService {
  const LocationService();

  /// A reading from the live stream may stand in for a fresh lookup while it
  /// is younger than this.
  ///
  /// Acquiring a new high-accuracy fix in a browser can take tens of seconds,
  /// and the clock-in screen already holds a position stream open, so the
  /// wait is usually redundant. Kept short so the reading still describes
  /// where the person is standing, and safe regardless: `clock_in` recomputes
  /// the distance server-side and re-applies the accuracy limit, so a reused
  /// fix cannot be used to clock in from somewhere else.
  static const maxReusableFixAge = Duration(seconds: 20);

  static const _settings = LocationSettings(
    accuracy: LocationAccuracy.best,
    timeLimit: Duration(seconds: 30),
  );

  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const AppError(
        'Location services are switched off. Turn them on and try again.',
        code: 'location_disabled',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      throw const AppError(
        'Location access is blocked for this site. Allow it in your browser '
        'settings, then reload the page.',
        code: 'location_denied_forever',
      );
    }
    if (permission == LocationPermission.denied) {
      throw const AppError(
        'Location access is needed to clock in. Allow it when your browser '
        'asks.',
        code: 'location_denied',
      );
    }
  }

  /// A reading the device itself says was faked. Refusing it costs an attacker
  /// nothing more than turning the mock provider off, so treat it as tidying
  /// up the obvious case rather than as a real defence.
  static const _mockedMessage =
      'Your device is reporting a simulated location. Turn off any mock '
      'location app and try again.';

  Future<LocationFix> currentFix() async {
    await _ensurePermission();
    logAction('location.fix');
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: _settings,
      );
      final fix = LocationFix.fromPosition(position);
      if (fix.isMocked) {
        logFail('location.fix', 'mocked position reported');
        throw const AppError(
          _mockedMessage,
          code: ClockErrorCode.locationMocked,
        );
      }
      logDone('location.fix', {'accuracy': fix.accuracyMeters.round()});
      return fix;
    } on TimeoutException catch (error) {
      logFail('location.fix', error);
      throw const AppError(
        'Could not get a location fix in time. Move near a window or step '
        'outside and try again.',
        code: 'location_timeout',
      );
    }
  }

  /// Continuous updates for the live distance readout on the clock-in screen.
  /// Uses high (not best) accuracy and a short distance filter so the UI does
  /// not thrash while the person stands still.
  Stream<LocationFix> watch() async* {
    await _ensurePermission();
    yield* Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 8,
      ),
    ).map((position) {
      final fix = LocationFix.fromPosition(position);
      if (fix.isMocked) {
        throw const AppError(_mockedMessage, code: 'location_mocked');
      }
      return fix;
    });
  }
}

final locationServiceProvider = Provider<LocationService>(
  (ref) => const LocationService(),
);

/// Live position stream, restarted whenever the caller invalidates it.
final locationStreamProvider = StreamProvider<LocationFix>(
  (ref) => ref.watch(locationServiceProvider).watch(),
);
