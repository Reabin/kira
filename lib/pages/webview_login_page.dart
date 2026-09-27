import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/user/user_api.dart';
import '../l10n/app_localizations.dart';
import '../models/copy_account_store.dart';
import '../providers/app_providers.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/app_logger.dart';
import '../utils/copy_web_login.dart';
import '../utils/toast.dart';

/// 通过应用内 WebView 登录拷贝官网：用户在网页中完成登录后，
/// 从 cookie 中提取 token 并走令牌登录流程。
class WebViewLoginPage extends ConsumerStatefulWidget {
  const WebViewLoginPage({super.key});

  @override
  ConsumerState<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends ConsumerState<WebViewLoginPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _completing = false;
  bool _readingCredentials = false;
  String? _error;

  String get _host => ref.read(userManagerProvider).copyLoginHost;

  WebUri get _baseUri => WebUri('https://$_host');

  WebUri get _loginUri => WebUri('https://$_host/web/login/loginByAccount');

  /// 读取多个候选域名下的 cookie（官网可能跳转到 www 子域，
  /// token 可能写在父域或当前实际页面域上）。
  Future<Map<String, String>> _readCookieMap() async {
    final manager = CookieManager.instance();
    final result = <String, String>{};
    final candidates = <WebUri>{_baseUri, WebUri('https://www.$_host')};
    final currentUrl = await _controller?.getUrl();
    if (currentUrl != null && _isLoginHost(currentUrl.host)) {
      candidates.add(currentUrl);
    }

    for (final uri in candidates) {
      try {
        final cookies = await manager.getCookies(url: uri);
        for (final c in cookies) {
          if (c.name.isNotEmpty && !result.containsKey(c.name)) {
            result[c.name] = c.value?.toString() ?? '';
          }
        }
      } catch (_, st) {
        unawaited(
          AppLogger.instance.recordWarning(
            'Unable to read COPY WebView cookies',
            stackTrace: st,
            source: 'webview_login.read_cookies',
          ),
        );
      }
    }
    return result;
  }

  bool _isLoginHost(String host) {
    final base = _host.startsWith('www.') ? _host.substring(4) : _host;
    return host == base || host == 'www.$base';
  }

  /// Read the official page's candidate token and profile together. Storage
  /// from a navigation to another website must never be submitted as COPY.
  Future<CopyWebCredentials?> _extractCredentialsFromWebStorage() async {
    final currentUrl = await _controller?.getUrl();
    if (currentUrl == null || !_isLoginHost(currentUrl.host)) return null;
    const source = '''
(function(){
  try {
    var ls = {};
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      ls[k] = localStorage.getItem(k);
    }
    var ss = {};
    for (var j = 0; j < sessionStorage.length; j++) {
      var k2 = sessionStorage.key(j);
      ss[k2] = sessionStorage.getItem(k2);
    }
    return JSON.stringify({cookie: document.cookie, ls: ls, ss: ss});
  } catch (e) { return 'error: ' + e; }
})()
''';
    try {
      final raw = await _controller?.evaluateJavascript(source: source);
      final json = raw?.toString();
      if (json == null || json.isEmpty) return null;
      return parseCopyWebStorage(jsonDecode(json));
    } catch (_, st) {
      unawaited(
        AppLogger.instance.recordWarning(
          'Unable to read COPY WebView storage',
          stackTrace: st,
          source: 'webview_login.web_storage',
        ),
      );
      return null;
    }
  }

  Future<void> _tryExtractAndFinish({bool manual = false}) async {
    if (_completing || _readingCredentials) return;
    final l10n = AppLocalizations.of(context)!;

    _readingCredentials = true;
    CopyWebCredentials? credentials;
    try {
      credentials = parseCopyWebCookies(await _readCookieMap());
      if (credentials == null ||
          (credentials.userId.isEmpty && credentials.username.isEmpty)) {
        final stored = await _extractCredentialsFromWebStorage();
        if (credentials == null) {
          credentials = stored;
        } else if (stored?.token == credentials.token) {
          credentials = stored;
        }
      }
    } catch (_, st) {
      unawaited(
        AppLogger.instance.recordWarning(
          'Unable to read COPY WebView credentials',
          stackTrace: st,
          source: 'webview_login.read_credentials',
        ),
      );
    } finally {
      _readingCredentials = false;
    }
    if (!mounted) return;
    if (credentials == null) {
      if (manual) showToast(context, l10n.profileWebLoginNotDetected);
      return;
    }

    setState(() {
      _completing = true;
      _error = null;
    });

    final user = ref.read(userManagerProvider);
    final api = ref.read(userApiProvider);
    try {
      final saved = await completeCopyWebLogin(
        user: user,
        api: api,
        credentials: credentials,
      );
      if (!mounted) return;
      if (saved) {
        context.pop(true);
      } else {
        setState(() {
          _completing = false;
          _error = l10n.copyAccountLoginSuperseded;
        });
      }
    } catch (error) {
      unawaited(
        AppLogger.instance.recordWarning(
          'COPY WebView login failed',
          source: 'webview_login.validate',
        ),
      );
      if (mounted) {
        setState(() {
          _completing = false;
          _error = error is CopyProfileUnavailableException
              ? l10n.copyProfileRefreshUnavailable
              : error is CopyAccountStorageException
              ? l10n.copyAccountStorageFailed
              : l10n.profileWebLoginFailed;
        });
      }
    }
  }

  Future<void> _resetWebSession() async {
    final manager = CookieManager.instance();
    await manager.deleteCookies(url: _baseUri, domain: '.$_host');
    await manager.deleteCookies(url: _baseUri, domain: _host);
    await _controller?.loadUrl(urlRequest: URLRequest(url: _loginUri));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.profileWebLoginPageTitle),
        actions: [
          IconButton(
            tooltip: l10n.profileWebLoginResetTooltip,
            onPressed: _completing ? null : _resetWebSession,
            icon: const Icon(Icons.restart_alt),
          ),
          TextButton(
            onPressed: _completing
                ? null
                : () => _tryExtractAndFinish(manual: true),
            child: Text(l10n.profileWebLoginManualButton),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_progress < 1)
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                ),
              Container(
                width: double.infinity,
                color: cs.surfaceBright,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Text(
                  l10n.profileWebLoginHint,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              if (_error != null)
                Container(
                  width: double.infinity,
                  color: cs.errorContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
                  child: Text(
                    _error!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.onErrorContainer),
                  ),
                ),
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: _loginUri),
                  onWebViewCreated: (controller) => _controller = controller,
                  onProgressChanged: (controller, progress) {
                    setState(() => _progress = progress / 100);
                  },
                  onLoadStop: (controller, url) => _tryExtractAndFinish(),
                  onUpdateVisitedHistory: (controller, url, isReload) =>
                      _tryExtractAndFinish(),
                ),
              ),
            ],
          ),
          if (_completing)
            Positioned.fill(
              child: ColoredBox(
                color: cs.scrim.withValues(alpha: 0.4),
                child: Center(
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: AppRadius.lgR),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: AppSpacing.lg),
                          Text(l10n.profileWebLoginCompleting),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
