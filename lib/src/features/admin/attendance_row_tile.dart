import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';
import '../../core/formatters.dart';
import '../../models/attendance_record.dart';
import '../../services/attendance_repository.dart';
import '../../services/selfie_service.dart';
import '../../services/supabase_providers.dart';
import '../shared/widgets.dart';

/// One attendance row as the admin sees it: who, when, how far out, and the
/// verification evidence.
class AttendanceRowTile extends StatelessWidget with FTileMixin {
  const AttendanceRowTile({
    required this.record,
    this.showDate = false,
    this.timezone,
    this.onReviewed,
    super.key,
  });

  final AttendanceRecord record;
  final bool showDate;

  /// Organisation timezone for clock-in/out stamps. Falls back to the device
  /// zone only when settings have not loaded yet.
  final String? timezone;

  /// Called after the review state changes, so the list this row belongs to
  /// can refetch. Each screen holds its own query, so neither can invalidate
  /// the other's from here.
  final VoidCallback? onReviewed;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final staff = record.staff;

    return FTile(
      prefix: SelfieThumbnail(record: record, onReviewed: onReviewed),
      title: Text(staff?.displayName ?? 'Unknown staff member'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${showDate ? '${formatShortDay(record.workDate)} · ' : ''}'
            '${formatTime(record.clockInAt, timezone: timezone)} → '
            '${formatTime(record.clockOutAt, timezone: timezone)}',
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              StatusChip(
                label: record.displayLocationName,
                icon: FLucideIcons.mapPin,
              ),
              StatusChip(
                label: '${formatDistance(record.clockInDistanceMeters)} out',
                icon: FLucideIcons.crosshair,
              ),
              if (record.verifiedWithPasskey)
                const StatusChip(
                  label: 'Passkey',
                  icon: FLucideIcons.fingerprint,
                  tone: ChipTone.positive,
                ),
              if (record.verifiedWithSelfie && record.selfiePath != null)
                const StatusChip(
                  label: 'Photo',
                  icon: FLucideIcons.camera,
                  tone: ChipTone.positive,
                ),
              if (record.verifiedWithSelfie && record.selfiePath == null)
                const StatusChip(
                  label: 'Photo missing',
                  icon: FLucideIcons.imageOff,
                  tone: ChipTone.negative,
                ),
              if (record.reviewStatus == ReviewStatus.flagged)
                const StatusChip(
                  label: 'Flagged',
                  icon: FLucideIcons.flag,
                  tone: ChipTone.negative,
                ),
              if (record.reviewStatus == ReviewStatus.reviewed)
                const StatusChip(
                  label: 'Reviewed',
                  icon: FLucideIcons.check,
                  tone: ChipTone.warning,
                ),
            ],
          ),
        ],
      ),
      // The status goes in the suffix rather than the details slot: FTile
      // gives a text details slot only the width the title column leaves
      // over, and the wrapped chips above claim nearly all of it.
      suffix: Text(
        record.isOpen ? 'On shift' : formatDuration(record.workedDuration),
        style: theme.bodyStyle.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Selfies sit in a private bucket, so each thumbnail resolves its own signed
/// URL. Tapping opens the full photo for a proper look, and for the verdict.
class SelfieThumbnail extends ConsumerWidget {
  const SelfieThumbnail({required this.record, this.onReviewed, super.key});

  final AttendanceRecord record;
  final VoidCallback? onReviewed;

  static const _size = 40.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = record.selfiePath;

    if (path == null) {
      return FAvatar.raw(
        size: _size,
        child: Text(record.staff?.initials ?? '?'),
      );
    }

    final url = ref.watch(selfieUrlProvider(path));

    return url.when(
      loading: () => FAvatar.raw(size: _size),
      error: (_, _) => GestureDetector(
        onTap: () => ref.invalidate(selfieUrlProvider(path)),
        child: FAvatar.raw(
          size: _size,
          child: Icon(
            FLucideIcons.refreshCw,
            size: 16,
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ),
      data: (signedUrl) => GestureDetector(
        onTap: () => showFDialog<void>(
          context: context,
          builder: (dialogContext, style, animation) => _SelfieReviewDialog(
            record: record,
            signedUrl: signedUrl,
            path: path,
            onReviewed: onReviewed,
          ),
        ),
        child: FAvatar(
          size: _size,
          image: ResizeImage(
            NetworkImage(signedUrl),
            width: (_size * 3).round(),
            height: (_size * 3).round(),
          ),
          semanticsLabel: 'View clock-in photo',
        ),
      ),
    );
  }
}

/// The photo at full size, and the only place a clock-in gets a verdict.
///
/// Nothing checks the face automatically, so this is the check: an
/// administrator looks, and either marks the record off or flags it for
/// follow-up.
class _SelfieReviewDialog extends ConsumerStatefulWidget {
  const _SelfieReviewDialog({
    required this.record,
    required this.signedUrl,
    required this.path,
    this.onReviewed,
  });

  final AttendanceRecord record;
  final String signedUrl;
  final String path;
  final VoidCallback? onReviewed;

  @override
  ConsumerState<_SelfieReviewDialog> createState() =>
      _SelfieReviewDialogState();
}

class _SelfieReviewDialogState extends ConsumerState<_SelfieReviewDialog> {
  late ReviewStatus _status = widget.record.reviewStatus;
  bool _busy = false;

  Future<void> _setStatus(ReviewStatus status) async {
    setState(() => _busy = true);
    try {
      final updated = await ref
          .read(attendanceRepositoryProvider)
          .review(widget.record.id, status);
      ref.invalidate(todaySnapshotProvider);
      widget.onReviewed?.call();

      if (!mounted) return;
      setState(() => _status = updated.reviewStatus);
      showSnack(context, switch (status) {
        ReviewStatus.flagged => 'Clock-in flagged.',
        ReviewStatus.reviewed => 'Marked as reviewed.',
        ReviewStatus.unreviewed => 'Review cleared.',
      });
    } catch (error) {
      if (mounted) showSnack(context, errorMessage(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final timezone = ref.watch(orgSettingsProvider).value?.timezone;

    return AppDialog(
      title: record.staff?.displayName ?? 'Clock-in photo',
      message:
          '${formatShortDay(record.workDate)} at '
          '${formatTime(record.clockInAt, timezone: timezone)}',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              widget.signedUrl,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Text(
                      'This photo link expired. Tap below to load a fresh one.',
                    ),
                    const SizedBox(height: 12),
                    FButton(
                      onPress: () {
                        ref.invalidate(selfieUrlProvider(widget.path));
                        Navigator.of(context).pop();
                      },
                      child: const ButtonLabel('Reload photo'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_status != ReviewStatus.unreviewed) ...[
            const SizedBox(height: 12),
            Align(
              child: StatusChip(
                label: _status == ReviewStatus.flagged
                    ? 'Flagged'
                    : 'Reviewed',
                icon: _status == ReviewStatus.flagged
                    ? FLucideIcons.flag
                    : FLucideIcons.check,
                tone: _status == ReviewStatus.flagged
                    ? ChipTone.negative
                    : ChipTone.warning,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (_status != ReviewStatus.flagged)
          FButton(
            variant: FButtonVariant.destructive,
            onPress: _busy ? null : () => _setStatus(ReviewStatus.flagged),
            prefix: const Icon(FLucideIcons.flag),
            child: const ButtonLabel('Flag this clock-in'),
          ),
        if (_status != ReviewStatus.reviewed)
          FButton(
            onPress: _busy ? null : () => _setStatus(ReviewStatus.reviewed),
            prefix: const Icon(FLucideIcons.check),
            child: const ButtonLabel('Mark as reviewed'),
          ),
        if (_status != ReviewStatus.unreviewed)
          FButton(
            variant: FButtonVariant.outline,
            onPress: _busy ? null : () => _setStatus(ReviewStatus.unreviewed),
            child: const ButtonLabel('Clear review'),
          ),
        FButton(
          variant: FButtonVariant.ghost,
          onPress: () => Navigator.of(context).pop(),
          child: const ButtonLabel('Close'),
        ),
      ],
    );
  }
}
