import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/reader_settings_fold.dart';

import '../test_helpers.dart';

Widget _subject({
  required bool reduceMotion,
  required ValueChanged<bool> changed,
}) {
  return wrapWithApp(
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: ReaderSettingsFold(
          title: '翻页',
          icon: Icons.auto_stories_outlined,
          child: _Toggle(changed),
        ),
      ),
    ),
  );
}

class _Toggle extends StatefulWidget {
  const _Toggle(this.changed);

  final ValueChanged<bool> changed;

  @override
  State<_Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<_Toggle> {
  bool _value = false;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    title: const Text('无动画翻页'),
    value: _value,
    onChanged: (value) {
      setState(() => _value = value);
      widget.changed(value);
    },
  );
}

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  testWidgets(
    'fold stays interactive and retains child state across motion changes',
    (tester) async {
      final changes = <bool>[];
      await tester.pumpWidget(
        _subject(reduceMotion: false, changed: changes.add),
      );
      expect(find.byType(SwitchListTile).hitTestable(), findsNothing);
      await tester.tap(find.text('翻页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(changes, [true]);
      await tester.tap(find.text('翻页'));
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile).hitTestable(), findsNothing);
      await tester.pumpWidget(
        _subject(reduceMotion: true, changed: changes.add),
      );
      await tester.pump();
      await tester.tap(find.text('翻页'));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      expect(find.byType(SwitchListTile).hitTestable(), findsOneWidget);
      expect(changes, [true]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fold has a full-height header on narrow large-text layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrapWithApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: const ReaderSettingsFold(
              title: '图片加载',
              icon: Icons.image_outlined,
              child: Text('超时时间'),
            ),
          ),
        ),
      ),
    );
    final header = find.byType(InkWell).first;
    expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
    await tester.tap(header);
    await tester.pump();
    expect(find.text('超时时间').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
