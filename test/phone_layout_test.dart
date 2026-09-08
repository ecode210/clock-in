import 'package:clock_in/src/features/shared/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

/// The app is used on a phone, so the shared building blocks are rendered at
/// a narrow width here. Any overflow is reported as a Flutter error, which
/// [WidgetTester] surfaces as a test failure — so these guard the layouts
/// without asserting on pixel positions.
const _phone = Size(360, 780);

Future<void> _pumpPhone(WidgetTester tester, Widget child) async {
  tester.view
    ..physicalSize = _phone
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    FTheme(
      data: FTheme.neutral.light.touch,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: _phone),
          child: FToaster(child: FScaffold(childPad: false, child: child)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a three-figure summary row fits a phone', (tester) async {
    // The dashboard and history screens both put three of these side by
    // side, and the values can be long ("12/120", "1,024 h").
    await _pumpPhone(
      tester,
      const PagePadding(
        child: ContentCard(
          child: MetricRow(
            figures: [
              MetricFigure(label: 'Clocked in', value: '128/1280'),
              MetricFigure(label: 'On shift', value: '1024'),
              MetricFigure(label: 'Finished', value: '256'),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a section card with a trailing action fits a phone', (
    tester,
  ) async {
    await _pumpPhone(
      tester,
      PagePadding(
        child: SectionCard(
          title: 'Where staff may clock in',
          subtitle:
              'Tap the map to drop the pin on your site, then set how far '
              'from it staff may clock in.',
          trailing: FButton(
            variant: FButtonVariant.ghost,
            size: FButtonSizeVariant.sm,
            onPress: () {},
            child: const Text('Change'),
          ),
          children: const [Text('body')],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a tile with wrapped status chips fits a phone', (tester) async {
    await _pumpPhone(
      tester,
      PagePadding(
        child: FTileGroup(
          children: [
            FTile(
              prefix: FAvatar.raw(child: const Text('AB')),
              title: const Text('Abednego Oluwaseun-Fagbemi'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('abednego.oluwaseun@organisation.example'),
                  SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      StatusChip(label: 'You', icon: FLucideIcons.user),
                      StatusChip(
                        label: 'Administrator',
                        icon: FLucideIcons.shieldCheck,
                        tone: ChipTone.positive,
                      ),
                      StatusChip(
                        label: 'Deactivated',
                        icon: FLucideIcons.userMinus,
                        tone: ChipTone.negative,
                      ),
                      StatusChip(label: 'ID 0001234'),
                    ],
                  ),
                ],
              ),
              suffix: FButton.icon(
                variant: FButtonVariant.ghost,
                onPress: () {},
                child: const Icon(FLucideIcons.ellipsisVertical),
              ),
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('an attendance row shows its whole status on a phone', (
    tester,
  ) async {
    // The chips in the subtitle claim most of the row, so the status has to
    // be laid out before them or it ends up ellipsized to "On …".
    await _pumpPhone(
      tester,
      PagePadding(
        maxWidth: 700,
        child: FTileGroup(
          children: [
            FTile(
              prefix: FAvatar.raw(size: 40, child: const Text('AO')),
              title: const Text('Administrator'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('9:28 AM → —'),
                  SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      StatusChip(label: '0 m out', icon: FLucideIcons.mapPin),
                      StatusChip(
                        label: 'Passkey',
                        icon: FLucideIcons.fingerprint,
                        tone: ChipTone.positive,
                      ),
                      StatusChip(
                        label: 'Photo',
                        icon: FLucideIcons.camera,
                        tone: ChipTone.positive,
                      ),
                    ],
                  ),
                ],
              ),
              suffix: const Text('On shift'),
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);

    final status = tester.renderObject<RenderParagraph>(find.text('On shift'));
    expect(
      status.size.width,
      moreOrLessEquals(status.getMaxIntrinsicWidth(double.infinity)),
    );
  });

  testWidgets('the auth page fits a phone', (tester) async {
    tester.view
      ..physicalSize = _phone
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      FTheme(
        data: FTheme.neutral.light.touch,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: _phone),
            child: AuthPage(
              icon: FLucideIcons.clock,
              title: 'Staff Clock-In',
              subtitle: 'Sign in to mark your attendance',
              children: [
                FButton(onPress: () {}, child: const ButtonLabel('Sign in')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a dialog with a long body fits a phone', (tester) async {
    await _pumpPhone(
      tester,
      Builder(
        builder: (context) => Center(
          child: AppDialog(
            title: 'Add a staff member',
            message: 'Share these sign-in details with the staff member.',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 6; i++) ...[
                  FTextField(label: Text('Field $i')),
                  const SizedBox(height: 12),
                ],
              ],
            ),
            actions: [
              FButton(
                onPress: () {},
                child: const ButtonLabel('Create account'),
              ),
              FButton(
                variant: FButtonVariant.outline,
                onPress: () {},
                child: const ButtonLabel('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
