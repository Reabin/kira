import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/startup_failure_app.dart';

void main() {
  testWidgets('shows the failure summary and a retry button', (tester) async {
    await tester.pumpWidget(
      StartupFailureApp(
        error: StateError('PlatformException(PlatformException, boom)'),
        onRetry: () async {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('启动失败'), findsOneWidget);
    expect(
      find.textContaining('PlatformException(PlatformException, boom)'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('retry runs the callback and keeps the page when it fails', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      StartupFailureApp(
        error: Exception('boom'),
        onRetry: () async {
          attempts++;
          throw Exception('still failing');
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    // 重试失败时仍停留在失败页，用户可以继续重试。
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('summary is truncated to a single readable line', (tester) async {
    final longError = 'x' * 600;
    await tester.pumpWidget(
      StartupFailureApp(error: StateError(longError), onRetry: () async {}),
    );
    await tester.pumpAndSettle();

    final shown = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .single
        .data!;
    expect(shown.length, lessThanOrEqualTo(301));
    expect(shown.endsWith('…'), isTrue);
  });
}
