import 'package:adi2_remote/easy/easy_layout.dart';
import 'package:adi2_remote/ui/easy_size_picker.dart';
import 'package:adi2_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final screen in [const Size(360, 740), const Size(411, 914)]) {
    for (final selection in EasyTileSize.values) {
      testWidgets('Responsive matrix at $screen opens on $selection', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = screen;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: EasySizePicker(
                type: EasyTileType.volumeDown,
                size: selection,
                height: 1,
                onChanged: (_, _) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final viewport = tester.getRect(
          find.byKey(const ValueKey('easy-size-scroll')),
        );
        final selected = find.byKey(
          ValueKey('easy-size-${selection.name}-1.0'),
        );
        final rect = tester.getRect(selected);
        expect(rect.width / viewport.width, closeTo(0.4, 0.05));
        expect(viewport.height, greaterThanOrEqualTo(screen.height * 0.8));
        final vertical = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byKey(const ValueKey('easy-size-vertical-scroll')),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
        expect(vertical.maxScrollExtent, 0);
        for (final h in [0.5, 1.0, 1.5, 2.0]) {
          final row = tester.getRect(find.byKey(ValueKey('easy-size-row-$h')));
          expect(row.top, greaterThanOrEqualTo(viewport.top));
          expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
        }
        expect(rect.left, greaterThanOrEqualTo(viewport.left));
        expect(rect.right, lessThanOrEqualTo(viewport.right));
        expect(selected.hitTestable(), findsOneWidget);
        final completeColumns = EasyTileSize.values.where((size) {
          final bounds = tester.getRect(
            find.byKey(ValueKey('easy-size-${size.name}-1.0')),
          );
          return bounds.left >= viewport.left && bounds.right <= viewport.right;
        });
        expect(completeColumns, hasLength(2));
        final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
        expect(scrollbar.thumbVisibility, isTrue);
        expect(scrollbar.scrollbarOrientation, ScrollbarOrientation.bottom);
        final controller = scrollbar.controller!;
        expect(controller.position.maxScrollExtent, greaterThan(0));

        controller.jumpTo(0);
        await tester.pumpAndSettle();
        // Two complete columns and part of the third invite sideways scrolling.
        final second = tester.getRect(
          find.byKey(const ValueKey('easy-size-single-1.0')),
        );
        final third = tester.getRect(
          find.byKey(const ValueKey('easy-size-third-1.0')),
        );
        expect(second.right, lessThan(viewport.right));
        expect(third.left, lessThan(viewport.right));
        expect(third.right, greaterThan(viewport.right));
        final before = [
          for (final h in [0.5, 1.0, 1.5, 2.0])
            tester.getTopLeft(find.byKey(ValueKey('easy-size-wide-$h'))),
        ];
        await tester.drag(
          find.byKey(const ValueKey('easy-size-scroll')),
          const Offset(-80, 0),
        );
        await tester.pumpAndSettle();
        expect(controller.offset, greaterThan(0));
        for (var i = 0; i < before.length; i++) {
          final after = tester.getTopLeft(
            find.byKey(ValueKey('easy-size-wide-${[0.5, 1.0, 1.5, 2.0][i]}')),
          );
          expect(after.dx, closeTo(before[i].dx - controller.offset, 0.01));
          expect(after.dy, before[i].dy);
        }
        final hint = find.byKey(const ValueKey('easy-size-scroll-hint'));
        expect(
          tester
              .widget<Opacity>(
                find.ancestor(of: hint, matching: find.byType(Opacity)).first,
              )
              .opacity,
          1,
        );
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Opacity>(
                find.ancestor(of: hint, matching: find.byType(Opacity)).first,
              )
              .opacity,
          0,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('Short matrix scrolls vertically to every height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 220,
            child: EasySizePicker(
              type: EasyTileType.volumeDown,
              size: EasyTileSize.single,
              height: 1,
              onChanged: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final vertical = find.byKey(const ValueKey('easy-size-vertical-scroll'));
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: vertical, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(
      find.byKey(const ValueKey('easy-size-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(position.extentAfter, 0);
    expect(
      find.byKey(const ValueKey('easy-size-single-2.0')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final type in [
    EasyTileType.mute,
    EasyTileType.volumeRing,
    EasyTileType.bass,
  ]) {
    testWidgets('Matrix orders widths and heights and disables invalid $type', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 740);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      (EasyTileSize, double)? chosen;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: EasySizePicker(
              type: type,
              size: EasyTileSize.wide,
              height: type == EasyTileType.volumeRing ? 2 : 1,
              onChanged: (s, h) => chosen = (s, h),
            ),
          ),
        ),
      );
      for (final label in ['1/5', '2/5', '3/5', '4/5']) {
        expect(find.text(label), findsOneWidget);
      }
      double lastY = -1;
      for (final h in [0.5, 1.0, 1.5, 2.0]) {
        // The selected width may scroll earlier columns left of the viewport.
        double lastX = double.negativeInfinity;
        double? rowY;
        for (final s in EasyTileSize.values) {
          final cell = find.byKey(ValueKey('easy-size-${s.name}-$h'));
          final rect = tester.getRect(cell);
          expect(rect.left, greaterThan(lastX));
          expect(rect.top, rowY ?? rect.top);
          rowY = rect.top;
          lastX = rect.left;
          final enabled =
              EasyTile.heightsFor(type).contains(h) &&
              EasyTile.supportsShape(type, s, h);
          expect(
            tester.widget<InkWell>(cell).onTap,
            enabled ? isNotNull : isNull,
          );
        }
        expect(rowY!, greaterThan(lastY));
        lastY = rowY;
      }
      final selected = find.byKey(
        ValueKey(
          'easy-size-wide-${type == EasyTileType.volumeRing ? 2.0 : 1.0}',
        ),
      );
      await tester.ensureVisible(selected);
      await tester.pumpAndSettle();
      final container = tester.widget<Container>(
        find.descendant(of: selected, matching: find.byType(Container)),
      );
      expect(
        ((container.decoration as BoxDecoration).border! as Border).top.color,
        Palette.amber,
      );
      await tester.tap(selected);
      expect(chosen, (
        EasyTileSize.wide,
        type == EasyTileType.volumeRing ? 2.0 : 1.0,
      ));
      if (type == EasyTileType.volumeRing) {
        final disabled = find.byKey(const ValueKey('easy-size-single-0.5'));
        await tester.ensureVisible(disabled);
        await tester.pumpAndSettle();
        final shape = find.byKey(const ValueKey('easy-size-shape-single-0.5'));
        final enabledShape = find.byKey(
          const ValueKey('easy-size-shape-wide-2.0'),
        );
        expect(
          (Canvas canvas) => tester
              .widget<CustomPaint>(shape)
              .painter!
              .paint(canvas, const Size(72, 36)),
          isNot(paints..rrect(color: Palette.amber.withValues(alpha: 0.8))),
        );
        expect(
          (Canvas canvas) => tester
              .widget<CustomPaint>(enabledShape)
              .painter!
              .paint(canvas, const Size(72, 36)),
          paints..rrect(color: Palette.amber.withValues(alpha: 0.8)),
        );
        await tester.tap(disabled);
        expect(chosen, (
          EasyTileSize.wide,
          type == EasyTileType.volumeRing ? 2.0 : 1.0,
        ));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
