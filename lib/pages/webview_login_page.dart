import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../models/copy_account_store.dart';
import '../models/user_manager.dart';
import '../providers/app_providers.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../utils/app_logger.dart';
import '../utils/copy_web_login.dart';
import '../utils/toast.dart';

/// 官网登录凭据抓取脚本。
///
/// 密码由网页直接 POST 给服务器，客户端拿不到表单体，所以在页面里挂钩网络
/// 层，从真实的登录请求里解出账号密码，通过 `copyLoginForm` 桥回 Flutter。
///
/// 依据（取自官网静态资源，非猜测）：
/// - 页面是 Vue + Element UI，使用 **axios** 且通过 `XMLHttpRequest` 发包；
/// - 登录接口 `POST /api/kb/web/login`，表单体为
///   `username=<账号>&password=<base64(密码-salt)>&salt=<6位随机>&platform=2…`；
/// - 密码框默认明文（源码 `visiablePassword: true`），DOM 上没有 type=password，
///   所以不靠 DOM 结构识别。
///
/// 只有从真实网络请求里解出的凭据才会回报，因此不存在「把没提交的输入框内容
/// 当登录」的问题。官网改版导致钩子失效时脚本静默退出（只是不再保存密码），
/// 不影响登录本身。
const _loginFormScript = r'''
(function () {
  if (window.__copyLoginProbe) return;
  window.__copyLoginProbe = true;

  function report(username, password) {
    if (!username || !password) return;
    if (window.__copyLoginReported === username + '\n' + password) return;
    window.__copyLoginReported = username + '\n' + password;
    try {
      window.flutter_inappwebview.callHandler(
        'copyLoginForm', username, password, true
      );
    } catch (e) {}
  }

  // 只认登录接口，避免把注册/找回密码的请求当成登录。
  function isLoginUrl(url) {
    if (!url) return false;
    var s = String(url);
    return s.indexOf('/api/kb/web/login') >= 0 || s.indexOf('/api/v1/login') >= 0;
  }

  function decodeBody(body) {
    if (!body || typeof body !== 'string') return null;
    var username = '';
    var password = '';
    var salt = '';
    var pairs = body.split('&');
    for (var i = 0; i < pairs.length; i++) {
      var idx = pairs[i].indexOf('=');
      if (idx < 0) continue;
      var key = pairs[i].slice(0, idx);
      var value = pairs[i].slice(idx + 1);
      try { value = decodeURIComponent(value.replace(/\+/g, ' ')); } catch (e) {}
      if (key === 'username') username = value;
      else if (key === 'password') password = value;
      else if (key === 'salt') salt = value;
    }
    if (!username || !password) return null;
    var decoded = '';
    try {
      // 官网把密码编码成 base64(密码 + '-' + salt)，解回来才是明文。
      decoded = atob(password);
      if (salt) {
        var suffix = '-' + salt;
        if (decoded.slice(-suffix.length) === suffix) {
          decoded = decoded.slice(0, decoded.length - suffix.length);
        }
      }
    } catch (e) {
      return null;
    }
    if (!decoded) return null;
    return { username: username.trim(), password: decoded };
  }

  function inspect(method, url, body) {
    try {
      if (!isLoginUrl(url)) return;
      if (method && String(method).toUpperCase() !== 'POST') return;
      var parsed = decodeBody(body);
      if (parsed) report(parsed.username, parsed.password);
    } catch (e) {}
  }

  // axios 在浏览器里走 XMLHttpRequest；钩住 send/open 就能拿到登录表单体。
  var send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (body) {
    inspect(this.__copyLoginMethod, this.__copyLoginUrl, body);
    return send.apply(this, arguments);
  };
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__copyLoginMethod = method;
    this.__copyLoginUrl = url;
    return open.apply(this, arguments);
  };

  // 少数情况下页面可能改用 fetch，一并兜底。
  if (typeof window.fetch === 'function') {
    var rawFetch = window.fetch;
    window.fetch = function (input, init) {
      try {
        var url = input && input.url ? input.url : input;
        inspect(init && init.method ? init.method : 'GET', url, init && init.body);
      } catch (e) {}
      return rawFetch.apply(this, arguments);
    };
  }
})();
''';

/// 官网登录页自动填表脚本（桌面版 Element UI 与移动版 Vant 双结构兼容）。
///
/// 把传入的账号密码填进登录表单并触发登录按钮，账号密码以 JSON 对象字面量
/// 内嵌，不存在字符串转义/注入问题。结构依据（均取自官网真实页面）：
/// - 桌面版 `/web/login/loginByAccount`：`form.el-form`（登录 tab 默认激活）
///   内 `.el-input__inner` 依次是账号与密码，登录按钮是可见 pane 里唯一的
///   `button.el-button--primary`（注册 pane 里也有 display:none 的 primary，
///   用 offsetParent 过滤）；
/// - 移动版 `/h5/login`：`form.van-form` 内 `.van-field__control` 依次是
///   账号与密码，登录按钮是 `button.van-button-login`（注册按钮带
///   `--plain`，不会混淆）。
///
/// 两者都是 Vue（Element UI / Vant）+ v-model，需要 native setter + input
/// 事件才能让框架感知输入。脚本自身用 `__copyAutoLoginInjected` 防重入，
/// 重复注入无效。登录被拒时通过 `copyAutoLogin` 桥回报错误文案（Element 的
/// `.el-message--error` 与 Vant 的 `.van-toast`，后者无法从 class 区分类型，
/// 靠「成功」字样过滤）。
String buildCopyLoginFillScript({
  required String username,
  required String password,
}) {
  final payload = jsonEncode({'username': username, 'password': password});
  return '''
(function () {
  if (window.__copyAutoLoginInjected) return;
  window.__copyAutoLoginInjected = true;
  var params = $payload;

  function report(event, detail) {
    try {
      window.flutter_inappwebview.callHandler('copyAutoLogin', event, detail || '');
    } catch (e) {}
  }

  var reported = false;
  function finish(event, detail) {
    if (reported) return;
    reported = true;
    report(event, detail);
  }

  function setValue(input, value) {
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
  }

  function findTargets() {
    // 桌面版（Element UI）。
    var form = document.querySelector('form.el-form');
    if (form) {
      var inputs = form.querySelectorAll('.el-input__inner');
      var buttons = document.querySelectorAll('button.el-button--primary');
      var button = null;
      for (var i = 0; i < buttons.length; i++) {
        if (buttons[i].offsetParent !== null) { button = buttons[i]; break; }
      }
      if (inputs.length >= 2 && button) {
        return { username: inputs[0], password: inputs[1], button: button };
      }
    }
    // 移动版（Vant UI h5）。
    var vform = document.querySelector('form.van-form');
    if (vform) {
      var vinputs = vform.querySelectorAll('.van-field__control');
      var vbutton =
        vform.querySelector('.van-button-login') ||
        document.querySelector('button.van-button--danger:not(.van-button--plain)');
      if (vinputs.length >= 2 && vbutton) {
        return { username: vinputs[0], password: vinputs[1], button: vbutton };
      }
    }
    return null;
  }

  function watchErrors() {
    if (!window.MutationObserver || !document.body) return;
    var observer = new MutationObserver(function () {
      var messages = document.querySelectorAll('.el-message--error, .van-toast');
      for (var i = 0; i < messages.length; i++) {
        var el = messages[i];
        var cls = el.className || '';
        if (cls.indexOf('--success') >= 0) continue;
        var body = el.querySelector('.van-toast__text') || el;
        var text = body.textContent.trim();
        if (!text) continue;
        // 加载中 toast 与成功 toast 都不是登录结果，只报真正的失败提示。
        if (/加[载載]|載入|loading|稍[後后]/i.test(text)) continue;
        if (/成功|success/i.test(text)) continue;
        finish('error', text);
        observer.disconnect();
        return;
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
    // 登录结果只会出现在提交后的短时间内，之后停止观察。
    setTimeout(function () { observer.disconnect(); }, 15000);
  }

  function checkFieldErrors() {
    var errors = document.querySelectorAll('.el-form-item__error, .van-field__error-message');
    if (errors.length > 0) {
      finish('error', errors[0].textContent.trim());
    }
  }

  var attempts = 0;
  var timer = setInterval(function () {
    attempts++;
    var targets = findTargets();
    if (targets) {
      clearInterval(timer);
      setValue(targets.username, params.username);
      setValue(targets.password, params.password);
      targets.button.click();
      watchErrors();
      setTimeout(function () { checkFieldErrors(); }, 2000);
    } else if (attempts * 300 >= 8000) {
      clearInterval(timer);
      finish('form_not_found', '');
    }
  }, 300);
})();
''';
}

/// 通过应用内 WebView 登录拷贝官网：用户在网页中完成登录后，
/// 从 cookie 中提取 token 并走令牌登录流程。
class WebViewLoginPage extends ConsumerStatefulWidget {
  const WebViewLoginPage({super.key, this.autoFill});

  /// 非空时页面加载完成后自动填表并触发登录；失败时用户仍可在网页里
  /// 手动改密码重试。
  final ({String username, String password})? autoFill;

  @override
  ConsumerState<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends ConsumerState<WebViewLoginPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _completing = false;
  bool _readingCredentials = false;
  String? _error;

  /// 本次会话里钩到过真实的官网登录提交（见 [_loginFormScript]）。只有它
  /// 能证明提取到的登录态是用户刚刚登录的结果，而不是进入页面前残留的
  /// 旧会话。
  bool _submittedLogin = false;

  /// 页面上自动识别出的、本机已保存过的账号；非 null 时展示选择栏而不是
  /// 直接完成登录。
  CopyWebCredentials? _knownAccount;

  /// 表单抓取到的密码，按用户名暂存，登录完成时一并落到对应账号上。
  final _loginFormPasswords = <String, String>{};

  /// 自动填表提交后的 cookie 轮询：登录是 axios 请求、不一定触发页面导航，
  /// 靠轮询保证拿到新 token。
  Timer? _autoFillPoll;

  @override
  void dispose() {
    _autoFillPoll?.cancel();
    super.dispose();
  }

  String get _host => ref.read(userManagerProvider).copyLoginHost;

  WebUri get _baseUri => WebUri('https://$_host');

  /// 官网按 UA 分流：移动 WebView（Android/iOS）会被重定向到 Vant 版 h5
  /// 站点，登录页是 `/h5/login`；桌面 WebView2 的登录页才是
  /// `/web/login/loginByAccount`。
  bool get _isMobileSite => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  WebUri get _loginUri => WebUri(
    'https://$_host${_isMobileSite ? '/h5/login' : '/web/login/loginByAccount'}',
  );

  /// 脚本只在拷贝官网自己的页面上执行，避免把凭证交给其它站点。
  Set<String> get _scriptOriginRules {
    final base = _host.startsWith('www.') ? _host.substring(4) : _host;
    return {'https://$base', 'https://www.$base'};
  }

  /// 脚本只在用户真正提交表单后上报，因此这里可以放心暂存密码；用户名与
  /// 已保存账号对不上时不写入。
  void _onLoginFormReported(List<dynamic> arguments) {
    if (arguments.length < 3) return;
    final username = arguments[0]?.toString().trim() ?? '';
    final password = arguments[1]?.toString() ?? '';
    if (arguments[2] != true) return;
    if (username.isEmpty || password.isEmpty) return;
    _loginFormPasswords[username] = password;
    _submittedLogin = true;
  }

  /// 自动填表提交后轮询 cookie；页面跳转（onUpdateVisitedHistory/onLoadStop）
  /// 会先一步完成登录，轮询只是兜底，最多跑 10 秒。提示条出现时轮询继续：
  /// 自动填表可能随后把会话换成另一个账号，后续提取会覆盖提示条。
  void _startAutoFillPoll() {
    _autoFillPoll?.cancel();
    var tries = 0;
    _autoFillPoll = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted || _completing) {
        timer.cancel();
        return;
      }
      if (++tries > 20) {
        timer.cancel();
        return;
      }
      _tryExtractAndFinish();
    });
  }

  /// 自动填表脚本的桥回报：`error` 展示到顶部错误条，其余事件静默。
  void _onAutoLoginEvent(List<dynamic> arguments) {
    if (arguments.isEmpty || arguments.first is! String) return;
    if (arguments.first as String != 'error') return;
    final detail = arguments.length > 1 ? (arguments[1]?.toString() ?? '') : '';
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final trimmed = detail.trim();
    setState(() {
      _error = trimmed.isEmpty
          ? l10n.profileWebLoginFailed
          : l10n.profileCopyAutoLoginRejected(trimmed);
    });
  }

  /// 自动填表：页面加载到官网登录页时注入脚本，交由网页自己提交登录。
  Future<void> _injectAutoFill(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final fill = widget.autoFill;
    if (fill == null) return;
    final path = url?.toString() ?? '';
    final isLoginPage =
        path.contains('/web/login/loginByAccount') ||
        path.contains('/h5/login');
    if (!isLoginPage) return;
    try {
      await controller.evaluateJavascript(
        source: buildCopyLoginFillScript(
          username: fill.username,
          password: fill.password,
        ),
      );
      _startAutoFillPoll();
    } catch (_, st) {
      unawaited(
        AppLogger.instance.recordWarning(
          'Unable to inject COPY login autofill',
          stackTrace: st,
          source: 'webview_login.autofill',
        ),
      );
    }
  }

  /// 登录成功后把暂存的密码并回本机凭据，供令牌失效后的自动重登使用。
  Future<void> _persistLoginFormPasswords(UserManager user) async {
    if (_loginFormPasswords.isEmpty) return;
    final pending = Map<String, String>.from(_loginFormPasswords);
    _loginFormPasswords.clear();
    await user.saveLoginFormPasswords(pending);
  }

  /// Read each official host separately; cookie fields from different hosts
  /// must never be assembled into one account.
  Future<CopyWebCredentials?> _readCookieCredentials() async {
    final manager = CookieManager.instance();
    final currentUrl = await _controller?.getUrl();
    final base = _host.startsWith('www.') ? _host.substring(4) : _host;
    final candidates = <WebUri>{
      if (currentUrl != null && _isLoginHost(currentUrl.host)) currentUrl,
      _baseUri,
      WebUri('https://$base'),
      WebUri('https://www.$base'),
    };

    for (final uri in candidates) {
      try {
        final cookies = await manager.getCookies(url: uri);
        final values = <String, String>{};
        for (final cookie in cookies) {
          if (cookie.name.isNotEmpty) {
            values.putIfAbsent(
              cookie.name,
              () => cookie.value?.toString() ?? '',
            );
          }
        }
        final credentials = parseCopyWebCookies(values);
        if (credentials != null) return credentials;
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
    return null;
  }

  bool _isLoginHost(String host) {
    final base = _host.startsWith('www.') ? _host.substring(4) : _host;
    return host == base || host == 'www.$base';
  }

  /// Read the official page's candidate token and profile together. Storage
  /// from a navigation to another website must never be submitted as COPY.
  Future<CopyWebCredentials?> _extractCredentialsFromWebStorage({
    String? matchingToken,
  }) async {
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
    return JSON.stringify({ls: ls, ss: ss});
  } catch (e) { return 'error: ' + e; }
})()
''';
    try {
      final raw = await _controller?.evaluateJavascript(source: source);
      final json = raw?.toString();
      if (json == null || json.isEmpty) return null;
      final pageUrl = await _controller?.getUrl();
      if (pageUrl == null || !_isLoginHost(pageUrl.host)) return null;
      return parseCopyWebStorage(
        jsonDecode(json),
        matchingToken: matchingToken,
      );
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
      credentials = await _readCookieCredentials();
      final stored = await _extractCredentialsFromWebStorage(
        matchingToken: credentials?.token,
      );
      if (stored != null &&
          (credentials == null ||
              (stored.token == credentials.token &&
                  stored.profileBoundToToken))) {
        credentials = stored;
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

    // 残留的旧会话（打开页面时就带着的登录态）不是本次登录的结果，永不
    // 自动完成：否则刚被登出/删除的账号会在用户输入新账号前被抢登回来。
    // 只有钩到过真实登录提交、或用户手动点「我已完成登录」，才允许完成。
    switch (disposeWebLoginCredentials(
      credentials: credentials,
      user: ref.read(userManagerProvider),
      submittedLogin: _submittedLogin,
      manual: manual,
    )) {
      case WebLoginDisposition.complete:
        await _completeLogin(credentials);
      case WebLoginDisposition.knownAccount:
        setState(() => _knownAccount = credentials);
      case WebLoginDisposition.ignore:
        setState(() => _knownAccount = null);
    }
  }

  Future<void> _completeLogin(CopyWebCredentials credentials) async {
    if (_completing) return;
    final l10n = AppLocalizations.of(context)!;
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
        // 登录已经成功，保存密码只是附带收益：失败也不影响本次登录。
        await _persistLoginFormPasswords(user);
        // 自动填表时账号密码是用户在 kira 里输入的，登录请求（尤其移动版
        // h5）的表单体不一定解析得到，直接按本次登录的 token 锚定并回。
        final fill = widget.autoFill;
        if (fill != null) {
          await user.saveLoginFormPasswords({
            fill.username: fill.password,
          }, anchorToken: credentials.token);
        }
        if (!mounted) return;
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
          _error = error is CopyAccountStorageException
              ? l10n.copyAccountStorageFailed
              : l10n.profileWebLoginFailed;
        });
      }
    }
  }

  /// 重新识别当前网页里的登录态。走的是自动流程，所以若还是那个已保存的
  /// 账号，会重新停在提示条上；只有用户真的换成了另一个账号才自动完成。
  Future<void> _retryExtraction() async {
    setState(() {
      _error = null;
      _knownAccount = null;
    });
    await _tryExtractAndFinish();
  }

  /// Wipe every trace of the previous web session before loading the login
  /// page. Cookies alone are not enough: the official site also persists the
  /// token in localStorage/sessionStorage, and either one makes the next
  /// visit silently land on the previously logged-in account, which is why
  /// switching to another account looked impossible.
  Future<void> _resetWebSession() async {
    final l10n = AppLocalizations.of(context)!;
    final manager = CookieManager.instance();
    try {
      await manager.deleteAllCookies();
      // WebView storage is per-origin and is not covered by cookie deletion.
      await WebStorageManager.instance().deleteAllData();
    } catch (_, st) {
      unawaited(
        AppLogger.instance.recordWarning(
          'Unable to clear COPY WebView session',
          stackTrace: st,
          source: 'webview_login.reset_session',
        ),
      );
      if (mounted) showToast(context, l10n.profileWebLoginResetFailed);
    }
    if (!mounted) return;
    setState(() {
      _error = null;
      _knownAccount = null;
      // 会话已清空，重新开始观察本次的登录提交。
      _submittedLogin = false;
    });
    await _controller?.loadUrl(urlRequest: URLRequest(url: _loginUri));
    if (mounted) showToast(context, l10n.profileWebLoginResetDone);
  }

  /// 已保存账号的展示名：优先用户名，其次昵称，最后回落到通用文案，
  /// 避免在页面上暴露完整的账号标识。
  String _knownName(CopyWebCredentials credentials) {
    final l10n = AppLocalizations.of(context)!;
    for (final candidate in [credentials.username, credentials.nickname]) {
      if (candidate.trim().isNotEmpty) return candidate.trim();
    }
    return l10n.profileWebLoginKnownAccountFallback;
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
                : () => _knownAccount == null
                      ? _tryExtractAndFinish(manual: true)
                      : _retryExtraction(),
            child: Text(
              _knownAccount == null
                  ? l10n.profileWebLoginManualButton
                  : l10n.profileWebLoginRetryButton,
            ),
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
              if (_knownAccount case final known?)
                _KnownAccountBanner(
                  key: const ValueKey('web-login-known-account'),
                  accountName: _knownName(known),
                  onUse: () => _completeLogin(known),
                  onSwitch: _resetWebSession,
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
                  initialUserScripts: UnmodifiableListView([
                    UserScript(
                      source: _loginFormScript,
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      allowedOriginRules: _scriptOriginRules,
                    ),
                  ]),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'copyLoginForm',
                      callback: _onLoginFormReported,
                    );
                    controller.addJavaScriptHandler(
                      handlerName: 'copyAutoLogin',
                      callback: _onAutoLoginEvent,
                    );
                  },
                  onProgressChanged: (controller, progress) {
                    setState(() => _progress = progress / 100);
                  },
                  onLoadStop: (controller, url) {
                    _tryExtractAndFinish();
                    _injectAutoFill(controller, url);
                  },
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

/// 官网登录页检测到的「本机已保存账号」提示条。
///
/// 自动完成会让用户没有机会切换账号，所以这里停下来问一句：直接用这个账号，
/// 还是清掉登录态去登另一个。
class _KnownAccountBanner extends StatelessWidget {
  const _KnownAccountBanner({
    super.key,
    required this.accountName,
    required this.onUse,
    required this.onSwitch,
  });

  final String accountName;
  final VoidCallback onUse;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      color: cs.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.profileWebLoginKnownAccount(accountName),
            style: tt.bodySmall?.copyWith(color: cs.onSecondaryContainer),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('web-login-switch-account'),
                onPressed: onSwitch,
                child: Text(l10n.profileWebLoginSwitchAccount),
              ),
              TextButton(
                key: const ValueKey('web-login-use-account'),
                onPressed: onUse,
                child: Text(l10n.profileWebLoginUseAccount),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
