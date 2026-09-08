import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import 'features/shared/boot_gate.dart';
import 'routing/router.dart';

/// The app is mobile-first, so it always uses Forui's touch variant: larger
/// hit targets and tile-style rows, even when a desktop browser opens it.
final _light = _withHeaderSpacing(
  _withSwitchTrack(FTheme.neutral.light.touch, _switchOnLight),
);
final _dark = _withHeaderSpacing(
  _withSwitchTrack(FTheme.neutral.dark.touch, _switchOnDark),
);

/// Forui packs header actions flush against each other, which reads as one
/// wide control once the actions are filled buttons rather than bare glyphs.
FThemeData _withHeaderSpacing(FThemeData theme) => theme.copyWith(
  headerStyles: FVariantsDelta.delta([
    FVariantOperation.all(const FHeaderStyleDelta.delta(actionSpacing: 8)),
  ]),
);

/// Cupertino system green, in the two shades iOS itself uses. The dark one is
/// lighter so it keeps its punch against a near-black background.
const _switchOnLight = Color(0xFF34C759);
const _switchOnDark = Color(0xFF30D158);

/// Forui draws a switch's "on" track in [FColors.primary], which the zinc
/// palette makes near-black in light mode and near-white in dark. Against a
/// grey "off" track that reads as two shades of the same nothing, and in dark
/// mode the white thumb all but disappears into the track. Green says "on".
///
/// Only the two selected entries are replaced, so the off and disabled tracks
/// stay whatever Forui decides they should be. The thumb is left alone too: it
/// is white in light mode and near-white in dark, and both sit well on green.
FThemeData _withSwitchTrack(FThemeData theme, Color on) => theme.copyWith(
  switchStyle: FSwitchStyleDelta.delta(
    trackColor: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.exact({FSwitchVariant.selected}, on),
      FVariantValueDeltaOperation.exact({
        FSwitchVariant.selected.and(FSwitchVariant.disabled),
      }, theme.colors.disable(on)),
    ]),
  ),
);

class ClockInApp extends ConsumerWidget {
  const ClockInApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Clock-In',
      debugShowCheckedModeBanner: false,
      supportedLocales: FLocalizations.supportedLocales,
      localizationsDelegates: const [...FLocalizations.localizationsDelegates],
      // The Material themes are only an approximation for the handful of
      // Material widgets kept underneath Forui, such as the map and camera
      // preview. Forui's own theme below is what styles the app.
      theme: _light.toApproximateMaterialTheme(),
      darkTheme: _dark.toApproximateMaterialTheme(),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => FTheme(
        data: Theme.brightnessOf(context) == Brightness.light ? _light : _dark,
        child: FToaster(child: BootGate(child: child)),
      ),
    );
  }
}
