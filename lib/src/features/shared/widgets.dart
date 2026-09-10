import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/app_error.dart';

/// Vertical rhythm between stacked sections. Every screen uses this so the
/// spacing stays consistent without each one inventing its own numbers.
const double gutter = 16;

/// The app's type scale, named by role rather than by size.
///
/// Forui exposes raw tokens (`typography.body.sm` and friends); naming the
/// handful of combinations actually used keeps the screens legible and stops
/// each one picking a slightly different weight or colour.
extension AppTypography on FThemeData {
  /// Screen and section headings.
  TextStyle get headingStyle => typography.display.xl2.copyWith(
    fontWeight: FontWeight.w700,
    color: colors.foreground,
  );

  /// The large figure on a statistic or the clock-in time.
  TextStyle get figureStyle => typography.display.xl.copyWith(
    fontWeight: FontWeight.w700,
    color: colors.foreground,
  );

  /// A card or row title.
  TextStyle get titleStyle => typography.body.md.copyWith(
    fontWeight: FontWeight.w600,
    color: colors.foreground,
  );

  /// Ordinary body copy.
  TextStyle get bodyStyle =>
      typography.body.sm.copyWith(color: colors.foreground);

  /// Supporting copy: subtitles, hints, descriptions.
  TextStyle get mutedStyle =>
      typography.body.sm.copyWith(color: colors.mutedForeground);

  /// The smallest supporting text, for captions and group labels.
  TextStyle get captionStyle =>
      typography.body.xs.copyWith(color: colors.mutedForeground);
}

/// Phone-first page body.
///
/// On a phone the content runs edge to edge with a comfortable gutter. On a
/// wide browser window it stays in a narrow column rather than stretching,
/// so the app keeps reading like a mobile app on a desktop screen.
class PagePadding extends StatelessWidget {
  const PagePadding({required this.child, this.maxWidth = 560, super.key});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(gutter, gutter, gutter, gutter * 2),
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    ),
  );
}

/// An icon action in a screen's [FHeader].
///
/// A bare glyph reads as decoration, so this is a filled button: it carries the
/// primary surface, which makes it the one obviously tappable thing in a header
/// that is otherwise just a title.
class HeaderAction extends StatelessWidget {
  const HeaderAction({
    required this.icon,
    required this.semanticsLabel,
    required this.onPress,
    super.key,
  });

  final IconData icon;
  final String semanticsLabel;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => FButton.icon(
    variant: FButtonVariant.primary,
    size: FButtonSizeVariant.sm,
    semanticsLabel: semanticsLabel,
    onPress: onPress,
    child: Icon(icon),
  );
}

/// The leading icon of an [FTile].
///
/// Forui sizes a tile's prefix icon to the body type scale. Lucide glyphs carry
/// their own margin inside that box, so the drawn icon lands noticeably smaller
/// than the two lines of text it sits beside.
class TileIcon extends StatelessWidget {
  const TileIcon(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Icon(icon, size: 22);
}

/// The subtitle of an [FTile], for prose that runs longer than the row.
///
/// Forui asks for an ellipsis on a tile's subtitle through the ambient
/// [DefaultTextStyle] but sets no line limit alongside it, and an ellipsis
/// without a limit makes the engine drop every line after the first. Clearing
/// the ellipsis lets the text wrap over as many lines as it needs.
///
/// A subtitle that is meant to stay on one line (a summary carrying a name of
/// unknown length, say) should pass a plain `Text` and keep the truncation.
class TileSubtitle extends StatelessWidget {
  const TileSubtitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, overflow: TextOverflow.visible);
}

/// A bordered surface holding arbitrary content.
///
/// [FCard] declares a content padding in its style but leaves applying it to
/// whoever builds the content, so a plain `FCard(child: ...)` sits flush
/// against its own border. This applies it.
class ContentCard extends StatelessWidget {
  const ContentCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => FCard(
    builder: (context, style, child) =>
        Padding(padding: style.padding, child: child!),
    child: child,
  );
}

/// A titled group of content.
///
/// Wraps [ContentCard], which supplies the border and padding, and adds an
/// optional trailing action beside the title.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.children,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return ContentCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.titleStyle),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: theme.mutedStyle),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

/// A borderless section heading, for grouping tile groups on a screen.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: theme.captionStyle.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// Standard rendering for an async provider: spinner, retryable error, or data.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    required this.value,
    required this.builder,
    this.onRetry,
    super.key,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
    skipLoadingOnRefresh: true,
    loading: () => const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Center(child: FCircularProgress()),
    ),
    error: (error, _) => Padding(
      padding: const EdgeInsets.all(gutter),
      child: ErrorNotice(error: error, onRetry: onRetry),
    ),
    data: builder,
  );
}

/// Shows a failure the user can act on. The message always comes from
/// [errorMessage], which keeps technical detail out of the UI.
class ErrorNotice extends StatelessWidget {
  const ErrorNotice({required this.error, this.onRetry, super.key});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FAlert(
        variant: FAlertVariant.destructive,
        title: Text(errorMessage(error)),
      ),
      if (onRetry != null) ...[
        const SizedBox(height: 10),
        FButton(
          variant: FButtonVariant.outline,
          onPress: onRetry,
          child: const ButtonLabel('Try again'),
        ),
      ],
    ],
  );
}

/// Placeholder for a list or section with nothing in it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    this.message,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      child: Column(
        children: [
          Icon(icon, size: 32, color: theme.colors.mutedForeground),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: theme.titleStyle),
          if (message != null) ...[
            const SizedBox(height: 4),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: theme.mutedStyle,
            ),
          ],
        ],
      ),
    );
  }
}

enum ChipTone { neutral, positive, warning, negative }

/// Small label used for verification badges and shift status.
class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.label,
    this.icon,
    this.tone = ChipTone.neutral,
    super.key,
  });

  final String label;
  final IconData? icon;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    // Forui's badge variants carry the meaning: primary reads as "on",
    // secondary as "off", destructive as a problem. Warning has no variant of
    // its own, so it borrows the outline treatment.
    final variant = switch (tone) {
      ChipTone.positive => FBadgeVariant.primary,
      ChipTone.neutral => FBadgeVariant.secondary,
      ChipTone.warning => FBadgeVariant.outline,
      ChipTone.negative => FBadgeVariant.destructive,
    };

    return FBadge.raw(
      variant: variant,
      builder: (context, style) => Padding(
        padding: style.padding,
        child: DefaultTextStyle.merge(
          style: style.labelTextStyle,
          // An icon reads IconTheme, not the badge's label style, so left
          // alone it keeps the ambient colour and disappears against a badge
          // whose background is the inverse of the surface behind it.
          child: IconTheme(
            data: IconThemeData(color: style.labelTextStyle.color, size: 12),
            child: icon == null
                ? Text(label)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon),
                      const SizedBox(width: 5),
                      // Flexible, because FBadge sizes itself to its intrinsic
                      // width but is still clamped by the row it wraps into. A
                      // long label in a narrow tile must ellipsize rather than
                      // overflow.
                      Flexible(
                        child: Text(label, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Text for an [FButton]'s label.
///
/// Forui lays a button's content out in a `Row`, so a label wider than the
/// button is a hard overflow rather than a truncation, which happens readily
/// in a dialog on a narrow phone, or whenever the reader has scaled their
/// system font up. Being flexible, this shrinks instead.
///
/// Only valid as the child of a full-width [FButton]: `Flexible` needs the
/// button's row as its nearest render ancestor, and that row must have a
/// bounded width. A button sized to its content (one used as a
/// [SectionCard.trailing] action, say) should pass a plain `Text` instead.
class ButtonLabel extends StatelessWidget {
  const ButtonLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Flexible(
    child: Text(
      text,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

/// A labelled figure, used in the summary rows on the history and dashboard
/// screens. The value scales down rather than overflowing, because three of
/// these sit side by side even on a narrow phone.
class MetricFigure extends StatelessWidget {
  const MetricFigure({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: theme.figureStyle),
        ),
        const SizedBox(height: 2),
        Text(label, style: theme.captionStyle, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

/// A row of [MetricFigure]s sharing the width evenly, with enough of a gap
/// between them that they read as separate figures rather than one run of
/// numbers.
class MetricRow extends StatelessWidget {
  const MetricRow({required this.figures, super.key});

  final List<MetricFigure> figures;

  @override
  Widget build(BuildContext context) => Row(
    spacing: gutter,
    children: [for (final figure in figures) Expanded(child: figure)],
  );
}

/// Drop-in for [FScaffold] that consumes keyboard view insets the way
/// Material's [Scaffold] does.
///
/// Forui applies `viewInsets.bottom` in layout but never calls
/// [MediaQuery.removeViewInsets], so a nav shell scaffold plus a page
/// scaffold each reserve the keyboard height. On a phone that stacks to
/// nearly the full screen and leaves only a thin strip of UI at the top.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.child,
    this.header,
    this.sidebar,
    this.footer,
    this.childPad = true,
    this.resizeToAvoidBottomInset = true,
    super.key,
  });

  final Widget child;
  final Widget? header;
  final Widget? sidebar;
  final Widget? footer;
  final bool childPad;
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    final bottomInset = resizeToAvoidBottomInset
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;

    final Widget? effectiveFooter;
    if (bottomInset > 0) {
      effectiveFooter = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?footer,
          SizedBox(height: bottomInset),
        ],
      );
    } else {
      effectiveFooter = footer;
    }

    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: resizeToAvoidBottomInset,
      child: FScaffold(
        childPad: childPad,
        header: header,
        sidebar: sidebar,
        footer: effectiveFooter,
        // Insets are applied above and stripped from [MediaQuery] so nested
        // scaffolds cannot reserve the keyboard height a second time.
        resizeToAvoidBottomInset: false,
        child: child,
      ),
    );
  }
}

/// The centred, single-column layout shared by the sign-in, first-admin and
/// awaiting-approval screens, which all sit outside the tab shells.
class AuthPage extends StatelessWidget {
  const AuthPage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
    this.maxWidth = 400,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return AppScaffold(
      childPad: false,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: theme.colors.primary,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        icon,
                        size: 28,
                        color: theme.colors.primaryForeground,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.headingStyle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.mutedStyle,
                  ),
                  const SizedBox(height: 28),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's dialog layout: title, optional prose, optional content, then
/// full-width actions stacked vertically.
///
/// Forui's [FDialog] only supplies the surface and the text styles, so the
/// layout lives here to keep every dialog in the app identical. Actions stack
/// rather than sitting in a row because these are read on a phone.
class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.title,
    required this.actions,
    this.message,
    this.content,
    super.key,
  });

  final String title;
  final String? message;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => FDialog(
    builder: (context, style) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: style.titleTextStyle),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!, style: style.bodyTextStyle),
          ],
          if (content != null)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(top: gutter),
                child: SingleChildScrollView(child: content),
              ),
            ),
          const SizedBox(height: 20),
          for (final action in actions) ...[
            if (action != actions.first) const SizedBox(height: 8),
            action,
          ],
        ],
      ),
    ),
  );
}

/// Asks the user to confirm something irreversible. Returns false if they
/// dismiss the dialog by any means.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showFDialog<bool>(
    context: context,
    builder: (dialogContext, style, animation) => AppDialog(
      title: title,
      message: message,
      actions: [
        FButton(
          variant: destructive
              ? FButtonVariant.destructive
              : FButtonVariant.primary,
          onPress: () => Navigator.of(dialogContext).pop(true),
          child: ButtonLabel(confirmLabel),
        ),
        FButton(
          variant: FButtonVariant.outline,
          onPress: () => Navigator.of(dialogContext).pop(false),
          child: const ButtonLabel('Cancel'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Transient confirmation or failure message.
void showSnack(BuildContext context, String message, {bool isError = false}) {
  showFToast(
    context: context,
    variant: isError ? FToastVariant.destructive : FToastVariant.primary,
    title: Text(message),
    duration: Duration(seconds: isError ? 6 : 3),
  );
}
