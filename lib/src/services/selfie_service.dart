import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../core/app_error.dart';
import '../core/dev_log.dart';
import 'supabase_providers.dart';

/// A photo captured from the live camera feed, held in memory until the
/// clock-in succeeds.
class CapturedSelfie {
  const CapturedSelfie({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;

  String get fileExtension => switch (mimeType) {
    'image/png' => 'png',
    'image/webp' => 'webp',
    _ => 'jpg',
  };
}

class SelfieService {
  const SelfieService(this._client);

  final SupabaseClient _client;

  /// Uploads into the caller's own folder, which is the only place storage
  /// policies allow them to write, and which `clock_in` re-verifies.
  Future<String> upload(CapturedSelfie selfie) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const AppError(
        'You must be signed in to upload a photo.',
        code: 'not_authenticated',
      );
    }

    final path =
        '$userId/${DateTime.now().toUtc().millisecondsSinceEpoch}'
        '.${selfie.fileExtension}';

    logAction('selfie.upload', {
      'bytes': selfie.bytes.length,
      'type': selfie.mimeType,
    });
    try {
      await _client.storage
          .from(SupabaseConfig.selfieBucket)
          .uploadBinary(
            path,
            selfie.bytes,
            fileOptions: FileOptions(
              contentType: selfie.mimeType,
              upsert: false,
            ),
          );
      logDone('selfie.upload');
      return path;
    } catch (error, stack) {
      logFail('selfie.upload', error, stack);
      throw toAppError(error);
    }
  }

  /// Selfies live in a private bucket, so viewing one needs a signed URL.
  Future<String> signedUrl(String path, {int expiresInSeconds = 600}) async {
    try {
      return await _client.storage
          .from(SupabaseConfig.selfieBucket)
          .createSignedUrl(path, expiresInSeconds);
    } catch (error) {
      throw toAppError(error);
    }
  }
}

final selfieServiceProvider = Provider<SelfieService>(
  (ref) => SelfieService(ref.watch(supabaseClientProvider)),
);

/// Signed URLs are requested per selfie path and cached for the provider's
/// lifetime so scrolling a list does not re-sign the same file repeatedly.
final selfieUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => ref.watch(selfieServiceProvider).signedUrl(path),
);
