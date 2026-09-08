import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../shared/widgets.dart';

/// The step a clock-in or clock-out is on, or null when nothing is running.
///
/// This sits above the clock-in screen rather than in its own state because
/// go_router disposes that screen the moment a tab changes, and a disposed
/// screen drops its progress, its error and its success toast. The staff shell
/// watches this and covers itself, which keeps the screen mounted until the
/// flow finishes one way or the other.
class ClockBusyController extends Notifier<String?> {
  @override
  String? build() => null;

  void update(String step) => state = step;

  void clear() => state = null;
}

final clockBusyProvider = NotifierProvider<ClockBusyController, String?>(
  ClockBusyController.new,
);

/// Covers the whole staff shell while a clock-in or clock-out runs.
///
/// The barrier swallows every pointer event, so the tab bar, the header and
/// the page behind stay out of reach. Tapping it plays the system alert sound,
/// which says "not now" more clearly than doing nothing at all.
class ClockBusyOverlay extends StatelessWidget {
  const ClockBusyOverlay({required this.progress, super.key});

  final String progress;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: theme.colors.barrier),
        const FModalBarrier(filter: null, onDismiss: null),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(gutter),
            child: ContentCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const FCircularProgress(),
                  const SizedBox(height: 16),
                  Text(
                    progress,
                    textAlign: TextAlign.center,
                    style: theme.titleStyle,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Stay on this screen until it finishes.',
                    textAlign: TextAlign.center,
                    style: theme.mutedStyle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
