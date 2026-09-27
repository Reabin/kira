import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/widgets/account_avatar.dart';

void main() {
  test('normalizes captured relative and protocol-relative avatar paths', () {
    expect(
      AccountAvatar.resolveUrl(' user/cover/copymanga.png '),
      'https://s3.mangafunb.fun/user/cover/copymanga.png',
    );
    expect(
      AccountAvatar.resolveUrl('/user/cover/custom.jpg'),
      'https://s3.mangafunb.fun/user/cover/custom.jpg',
    );
    expect(
      AccountAvatar.resolveUrl('//example.test/avatar.jpg'),
      'https://example.test/avatar.jpg',
    );
    expect(
      AccountAvatar.resolveUrl('https://example.test/avatar.jpg'),
      'https://example.test/avatar.jpg',
    );
    expect(AccountAvatar.resolveUrl('file:///private/avatar.jpg'), isNull);
    expect(AccountAvatar.resolveUrl('invalid'), isNull);
    expect(AccountAvatar.resolveUrl(''), isNull);
  });

  testWidgets('missing or invalid avatar uses a local person fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AccountAvatar(avatar: 'invalid')),
      ),
    );
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('network avatar wires both loading and error fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AccountAvatar(avatar: 'user/cover/avatar.jpg')),
      ),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, 'https://s3.mangafunb.fun/user/cover/avatar.jpg');
    expect(image.placeholder, isNotNull);
    expect(image.errorWidget, isNotNull);
    final context = tester.element(find.byType(AccountAvatar));
    final fallback = image.errorWidget!(
      context,
      image.imageUrl,
      StateError('offline'),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: fallback)));
    expect(find.byIcon(Icons.person), findsOneWidget);
  });
}
