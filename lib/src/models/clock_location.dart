import 'package:latlong2/latlong.dart';

/// One clock-in site: name, map pin, and radius. Soft-archived with
/// [isActive] so past attendance can still name the place.
class ClockLocation {
  const ClockLocation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radiusMeters,
    required this.isActive,
  });

  factory ClockLocation.fromMap(Map<String, dynamic> map) => ClockLocation(
    id: map['id'] as String,
    name: (map['name'] as String?) ?? 'Location',
    lat: (map['lat'] as num).toDouble(),
    lng: (map['lng'] as num).toDouble(),
    radiusMeters: (map['radius_meters'] as num?)?.toInt() ?? 100,
    isActive: (map['is_active'] as bool?) ?? true,
  );

  final String id;
  final String name;
  final double lat;
  final double lng;
  final int radiusMeters;
  final bool isActive;

  LatLng get center => LatLng(lat, lng);

  ClockLocation copyWith({
    String? id,
    String? name,
    double? lat,
    double? lng,
    int? radiusMeters,
    bool? isActive,
  }) => ClockLocation(
    id: id ?? this.id,
    name: name ?? this.name,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    radiusMeters: radiusMeters ?? this.radiusMeters,
    isActive: isActive ?? this.isActive,
  );

  Map<String, dynamic> toInsertMap() => {
    'name': name,
    'lat': lat,
    'lng': lng,
    'radius_meters': radiusMeters,
    'is_active': isActive,
  };

  Map<String, dynamic> toUpdateMap() => {
    'name': name,
    'lat': lat,
    'lng': lng,
    'radius_meters': radiusMeters,
    'is_active': isActive,
  };
}
