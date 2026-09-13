import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_error.dart';
import '../core/dev_log.dart';
import '../models/clock_location.dart';
import 'supabase_providers.dart';

class LocationsRepository {
  const LocationsRepository(this._client);

  final SupabaseClient _client;

  Future<List<ClockLocation>> list({bool activeOnly = false}) async {
    var query = _client.from('locations').select();
    if (activeOnly) {
      query = query.eq('is_active', true);
    }
    final rows = await query.order('name');
    return rows.map(ClockLocation.fromMap).toList();
  }

  Future<ClockLocation> create({
    required String name,
    required double lat,
    required double lng,
    required int radiusMeters,
  }) async {
    logAction('location.create', {'name': name, 'radius': radiusMeters});
    try {
      final row = await _client
          .from('locations')
          .insert({
            'name': name,
            'lat': lat,
            'lng': lng,
            'radius_meters': radiusMeters,
          })
          .select()
          .single();
      logDone('location.create');
      return ClockLocation.fromMap(row);
    } catch (error, stack) {
      logFail('location.create', error, stack);
      throw toAppError(error);
    }
  }

  Future<ClockLocation> update(ClockLocation location) async {
    logAction('location.update', {
      'id': location.id,
      'name': location.name,
      'radius': location.radiusMeters,
    });
    try {
      final row = await _client
          .from('locations')
          .update(location.toUpdateMap())
          .eq('id', location.id)
          .select()
          .single();
      logDone('location.update');
      return ClockLocation.fromMap(row);
    } catch (error, stack) {
      logFail('location.update', error, stack);
      throw toAppError(error);
    }
  }

  /// Soft-delete: history still points at the row.
  Future<ClockLocation> archive(String id) async {
    logAction('location.archive', {'id': id});
    try {
      final row = await _client
          .from('locations')
          .update({'is_active': false})
          .eq('id', id)
          .select()
          .single();
      logDone('location.archive');
      return ClockLocation.fromMap(row);
    } catch (error, stack) {
      logFail('location.archive', error, stack);
      throw toAppError(error);
    }
  }

  Future<ClockLocation> restore(String id) async {
    logAction('location.restore', {'id': id});
    try {
      final row = await _client
          .from('locations')
          .update({'is_active': true})
          .eq('id', id)
          .select()
          .single();
      logDone('location.restore');
      return ClockLocation.fromMap(row);
    } catch (error, stack) {
      logFail('location.restore', error, stack);
      throw toAppError(error);
    }
  }
}

final locationsRepositoryProvider = Provider<LocationsRepository>(
  (ref) => LocationsRepository(ref.watch(supabaseClientProvider)),
);

/// Every location, including archived ones, for the admin list.
final locationsProvider = FutureProvider<List<ClockLocation>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(locationsRepositoryProvider).list();
});

/// Active sites only: what staff may clock in at.
final activeLocationsProvider = FutureProvider<List<ClockLocation>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(locationsRepositoryProvider).list(activeOnly: true);
});
