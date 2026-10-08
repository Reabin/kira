import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/ios_reader_volume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.caolib.kira/ios_reader_volume');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> commands;
  late List<String> buttons;
  late IOSReaderVolume reader;

  Future<void> press(String method) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  setUp(() {
    commands = [];
    buttons = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call.method);
      return null;
    });
    reader = IOSReaderVolume(onButton: (call) => buttons.add(call.method));
    reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
    reader.didPush();
  });
  tearDown(() async {
    reader.dispose();
    await reader.pending;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'background disables and resume re-arms; hidden reader ignores buttons',
    () async {
      reader.setEnabled(true);
      await reader.pending;
      await press('volumeDown');
      reader.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await reader.pending;
      await press('volumeUp');
      reader.didChangeAppLifecycleState(AppLifecycleState.paused);
      await reader.pending;
      reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await reader.pending;
      await press('volumeUp');
      expect(commands, ['enable', 'disable', 'disable', 'enable']);
      expect(buttons, ['volumeDown', 'volumeUp']);
    },
  );

  test(
    'covered route pauses and return re-arms; switch stays disabled on resume',
    () async {
      reader.setEnabled(true);
      await reader.pending;
      reader.didPushNext();
      await reader.pending;
      await press('volumeDown');
      reader.didPopNext();
      await reader.pending;
      await press('volumeDown');
      reader.setEnabled(false);
      await reader.pending;
      reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await reader.pending;
      await press('volumeDown');
      expect(commands, ['enable', 'disable', 'enable', 'disable', 'disable']);
      expect(buttons, ['volumeDown']);
    },
  );

  test(
    'old reader disposal cannot disable or clear replacement handler',
    () async {
      reader.setEnabled(true);
      await reader.pending;
      final replacement = IOSReaderVolume(
        onButton: (call) => buttons.add('new:${call.method}'),
      );
      replacement.didChangeAppLifecycleState(AppLifecycleState.resumed);
      replacement.didPush();
      replacement.setEnabled(true);
      reader.dispose();
      await replacement.pending;
      await press('volumeUp');
      expect(commands, ['enable', 'enable']);
      expect(buttons, ['new:volumeUp']);
      replacement.dispose();
      await replacement.pending;
      expect(commands.last, 'disable');
    },
  );

  test('failed activation retries after foreground recovery', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call.method);
      if (commands.length == 1) throw PlatformException(code: 'interrupted');
      return null;
    });
    reader.setEnabled(true);
    await reader.pending;
    reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await reader.pending;
    expect(commands, ['enable', 'enable']);
  });
}
