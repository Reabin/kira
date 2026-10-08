import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final readerVolumeRouteObserver = RouteObserver<ModalRoute<dynamic>>();

/// Re-arms the native listener whenever the active reader regains foreground.
class IOSReaderVolume with WidgetsBindingObserver, RouteAware {
  IOSReaderVolume({required this.onButton, MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.volume_button_override/channel') {
    WidgetsBinding.instance.addObserver(this);
  }

  final void Function(MethodCall) onButton;
  final MethodChannel _channel;
  static IOSReaderVolume? _owner;
  static Future<void> _commands = Future<void>.value();
  ModalRoute<dynamic>? _route;
  bool _enabled = false;
  bool _visible = false;
  bool _foreground =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool _disposed = false;

  Future<void> get pending => _commands;
  bool get _active => !_disposed && _enabled && _visible && _foreground;

  void attach(ModalRoute<dynamic>? route) {
    if (_route == route) return;
    readerVolumeRouteObserver.unsubscribe(this);
    _route = route;
    if (route != null) readerVolumeRouteObserver.subscribe(this, route);
    _visible = route?.isCurrent ?? false;
    _sync();
  }

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _sync();
  }

  @override
  void didPush() {
    _visible = true;
    _sync();
  }

  @override
  void didPopNext() {
    _visible = true;
    _sync();
  }

  @override
  void didPushNext() {
    _visible = false;
    _sync();
  }

  @override
  void didPop() {
    _visible = false;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    if (_active) {
      _owner = this;
      _channel.setMethodCallHandler((call) async {
        if (_owner != this ||
            !_active ||
            call.method != 'onVolumeButtonPressed') {
          return;
        }
        final args = call.arguments;
        if (args is! Map) return;
        final action = args['action'];
        if (action == 'volumeUp' || action == 'volumeDown') {
          onButton(MethodCall(action as String));
        }
      });
    } else if (_owner != this) {
      return;
    }
    final enable = _active;
    _commands = _commands.then((_) async {
      // A covered/disposed reader must never disable its newer replacement.
      if (_owner != this || (enable && !_active)) return;
      try {
        // Match HaKa's controller: tear down before every fresh start.
        await _channel.invokeMethod<void>('stopListening');
        if (enable && _owner == this && _active) {
          await _channel.invokeMethod<Object?>('startListening', {
            'volumeUpAction': 'volumeUp',
            'volumeDownAction': 'volumeDown',
          });
        }
      } on PlatformException catch (error) {
        debugPrint('iOS volume listener: $error');
      } on MissingPluginException {
        // Touch navigation remains available on unsupported hosts.
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    readerVolumeRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _sync();
    if (_owner == this) {
      _channel.setMethodCallHandler(null);
      _commands = _commands.then((_) {
        if (_owner == this) _owner = null;
      });
    }
    _route = null;
  }
}
