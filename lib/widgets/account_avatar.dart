import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Account avatars share the image loading and local fallback used by profiles.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, this.avatar, this.radius = 20});

  final String? avatar;
  final double radius;

  /// Login responses carry `user/cover/...`; member info and comments carry
  /// the same path on this CDN (see ref/用户/个人信息.http).
  static String? resolveUrl(String? avatar) {
    final value = avatar?.trim() ?? '';
    if (value.isEmpty) return null;
    final normalized = value.startsWith('//') ? 'https:$value' : value;
    final uri = Uri.tryParse(normalized);
    if (uri == null) return null;
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      return uri.toString();
    }
    final path = value.startsWith('/') ? value.substring(1) : value;
    if (!uri.hasScheme && path.startsWith('user/cover/')) {
      return Uri.https('s3.mangafunb.fun').resolveUri(uri).toString();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final url = resolveUrl(avatar);
    final fallback = ColoredBox(
      color: cs.primaryContainer,
      child: Center(
        child: Icon(Icons.person, size: radius, color: cs.onPrimaryContainer),
      ),
    );
    return CircleAvatar(
      radius: radius,
      backgroundColor: cs.primaryContainer,
      child: ClipOval(
        child: SizedBox.square(
          dimension: radius * 2,
          child: url == null
              ? fallback
              : CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
