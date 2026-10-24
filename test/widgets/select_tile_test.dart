import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/select_tile.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);
  testWidgets('open menu updates labels, selection and capsule width', (
    tester,
  ) async {
    late StateSetter rebuild;
    var rate = 60;
    var selected = 0;
    await tester.pumpWidget(
      wrapWithApp(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Center(
              child: SelectTile<int>(
                value: selected,
                items: [
                  SelectItem(0, '自动', compactLabel: '自动 · ${rate}Hz'),
                  SelectItem(120, rate == 120 ? '120Hz（当前）' : '120 Hz'),
                ],
                onChanged: (value) => setState(() => selected = value),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(SelectTile<int>));
    await tester.pumpAndSettle();
    expect(find.text('120 Hz'), findsOneWidget);
    final oldWidth = tester.getSize(find.byType(SelectTile<int>)).width;

    rebuild(() => rate = 120);
    await tester.pump();
    await tester.pump();
    expect(find.text('自动 · 120Hz'), findsOneWidget);
    expect(find.text('120Hz（当前）'), findsOneWidget);
    expect(find.text('120 Hz'), findsNothing);
    final width = tester.getSize(find.byType(SelectTile<int>)).width;
    expect(width, greaterThan(oldWidth));
    final menuItem = find.ancestor(
      of: find.text('120Hz（当前）'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(menuItem).width, width);

    rebuild(() => selected = 120);
    await tester.pump();
    await tester.pump();
    final menuLabel = tester.widget<Text>(find.text('120Hz（当前）').last);
    expect(menuLabel.style?.fontWeight, FontWeight.w600);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance overrides tint the pill and icon without a border '
      'by default', (tester) async {
    const fg = Color(0xFFFF6F00);
    const bg = Color(0x24FFC107);
    const accent = Color(0xFFFFC107);
    await tester.pumpWidget(
      wrapWithApp(
        Center(
          child: SelectTile<String>(
            value: 'beta',
            foregroundColor: fg,
            backgroundColor: bg,
            borderSide: const BorderSide(color: accent),
            leadingIcon: Icons.science_outlined,
            items: const [SelectItem('beta', 'beta')],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SelectTile<String>),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, bg);
    final shape = material.shape as RoundedRectangleBorder;
    expect(shape.side.color, accent);

    expect(find.byIcon(Icons.science_outlined), findsOneWidget);
    final label = tester.widget<Text>(find.text('beta'));
    expect(label.style?.color, fg);
    final arrow = tester.widget<Icon>(find.byIcon(Icons.keyboard_arrow_down));
    expect(arrow.color, fg);
  });

  testWidgets('without overrides the pill keeps its pre-existing colouring', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapWithApp(
        Center(
          child: SelectTile<int>(
            value: 0,
            items: const [SelectItem(0, '自动')],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final cs = Theme.of(
      tester.element(find.byType(SelectTile<int>)),
    ).colorScheme;
    expect(
      tester.widget<Icon>(find.byIcon(Icons.keyboard_arrow_down)).color,
      cs.onSurfaceVariant,
    );
    expect(find.byIcon(Icons.science_outlined), findsNothing);
  });

  testWidgets('menuMaxCharacters caps the menu width to that many characters', (
    tester,
  ) async {
    const long = '一二三四五六七八九十一二三四五六七八九十';
    await tester.pumpWidget(
      wrapWithApp(
        Center(
          child: SelectTile<String>(
            value: 'short',
            menuMaxCharacters: 15,
            items: const [SelectItem('long', long), SelectItem('short', '短名字')],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    // 胶囊仍然贴合当前选中项（这里是很短的「短名字」），不被上限撑开。
    final pillWidth = tester.getSize(find.byType(SelectTile<String>)).width;

    await tester.tap(find.byType(SelectTile<String>));
    await tester.pumpAndSettle();
    final menuItem = find.ancestor(
      of: find.text(long).last,
      matching: find.byType(InkWell),
    );
    final menuWidth = tester.getSize(menuItem).width;

    // 菜单正好按「15 个字符」定宽（左右各 16 内边距）。
    final style = Theme.of(
      tester.element(find.byType(SelectTile<String>)),
    ).textTheme.bodyMedium;
    final painter = TextPainter(
      text: TextSpan(text: '0' * 15, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    expect(menuWidth, closeTo(painter.size.width + 32, 0.5));
    expect(menuWidth, greaterThan(pillWidth));
  });

  testWidgets('wide menus stay inside safe edges and follow screen resizing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(369, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    late StateSetter rebuild;
    var scale = 1.0;
    var alignment = Alignment.centerRight;
    const long = 'a_very_long_account_name_123456789';
    await tester.pumpWidget(
      wrapWithApp(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(left: 24, right: 32),
                textScaler: TextScaler.linear(scale),
              ),
              child: Align(
                alignment: alignment,
                child: SelectTile<String>(
                  value: 'short',
                  menuMaxCharacters: 15,
                  items: const [
                    SelectItem('short', '短'),
                    SelectItem('long', long),
                  ],
                  onChanged: (_) {},
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(SelectTile<String>));
    await tester.pumpAndSettle();
    final menuItem = find.ancestor(
      of: find.text(long),
      matching: find.byType(InkWell),
    );
    var rect = tester.getRect(menuItem);
    expect(rect.left, greaterThanOrEqualTo(32));
    expect(rect.right, lessThanOrEqualTo(337));
    final originalWidth = rect.width;

    rebuild(() => scale = 2);
    await tester.pumpAndSettle();
    rect = tester.getRect(menuItem);
    expect(rect.width, greaterThan(originalWidth));
    expect(rect.left, greaterThanOrEqualTo(32));
    expect(rect.right, lessThanOrEqualTo(337));

    tester.view.physicalSize = const Size(320, 900);
    await tester.pumpAndSettle();
    rect = tester.getRect(menuItem);
    expect(rect.left, greaterThanOrEqualTo(32));
    expect(rect.right, lessThanOrEqualTo(288));

    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    rebuild(() => alignment = Alignment.centerLeft);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SelectTile<String>));
    await tester.pumpAndSettle();
    rect = tester.getRect(menuItem);
    expect(rect.left, greaterThanOrEqualTo(32));
    expect(rect.right, lessThanOrEqualTo(288));
    expect(tester.takeException(), isNull);
  });

  testWidgets('menuMaxCharacters also caps the pill label width', (
    tester,
  ) async {
    const long = '一二三四五六七八九十一二三四五六七八九十';
    await tester.pumpWidget(
      wrapWithApp(
        Center(
          child: SelectTile<String>(
            value: 'long',
            menuMaxCharacters: 8,
            items: const [SelectItem('long', long)],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    // 胶囊标签被压到 cap 内，胶囊不再被超长账号名撑满 168 的通用上限。
    // （真机上数字 ≈0.55em 远窄于全角汉字，此前只按数字量 cap 时胶囊宽度
    // 会反过来顶破菜单上限，限制形同虚设。）
    final style = Theme.of(
      tester.element(find.byType(SelectTile<String>)),
    ).textTheme.bodyMedium;
    final digits = TextPainter(
      text: TextSpan(text: '0' * 8, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final cjk = TextPainter(
      text: TextSpan(text: '字' * 8, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final cap = math.max(digits.size.width, cjk.size.width);

    final pillWidth = tester.getSize(find.byType(SelectTile<String>)).width;
    // 胶囊 = 标签(cap) + 水平内边距 32 + 间隙 6 + 箭头 18。
    expect(pillWidth, closeTo(cap + 56, 0.5));
    expect(pillWidth, lessThan(224.0));
  });
  testWidgets('reduced motion settles the arrow and preserves menu selection', (
    tester,
  ) async {
    var selected = 0;
    var reduced = false;
    late StateSetter rebuild;
    await tester.pumpWidget(
      wrapWithApp(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: Center(
                child: SelectTile<int>(
                  value: selected,
                  items: const [SelectItem(0, '自动'), SelectItem(1, '手动')],
                  onChanged: (value) => setState(() => selected = value),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(SelectTile<int>));
    await tester.pump(const Duration(milliseconds: 30));
    rebuild(() => reduced = true);
    await tester.pump();
    final rotation = tester.widget<AnimatedRotation>(
      find.byType(AnimatedRotation),
    );
    expect(rotation.duration, Duration.zero);
    expect(rotation.turns, 0.5);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    await tester.tap(find.text('手动'));
    await tester.pump();
    expect(selected, 1);
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0,
    );
    expect(tester.takeException(), isNull);
  });
}
