@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/supabase_flutter.dart';

// Test-only fixtures. None of these is a real project credential.
const _key = 'sb_publishable_TESTONLY_tool_check_00000';

class _Sandbox {
  _Sandbox() : dir = Directory.systemTemp.createTempSync('legal-app-tool-') {
    File(
      '${dir.path}/pubspec.yaml',
    ).writeAsStringSync('name: legalserviceapp\n');
    // Records argv and whether server-only variables leaked into flutter.
    stub = File('${dir.path}/flutter-stub.sh')..writeAsStringSync(
      '#!/bin/sh\n'
      'printf "%s\\n" "\$@" > "${dir.path}/argv.txt"\n'
      'if [ -n "\$SUPABASE_SERVICE_ROLE_KEY\$SUPABASE_SECRET_KEY" ]; then echo leaked > "${dir.path}/leak.txt"; fi\n'
      'exit 0\n',
    );
    Process.runSync('chmod', ['+x', stub.path]);
  }

  final Directory dir;
  late final File stub;
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();

  List<String>? get argv {
    final file = File('${dir.path}/argv.txt');
    return file.existsSync()
        ? file.readAsLinesSync().where((l) => l.isNotEmpty).toList()
        : null;
  }

  bool get leaked => File('${dir.path}/leak.txt').existsSync();

  Future<int> run(List<String> args, {Map<String, String> env = const {}}) =>
      runTool(
        args,
        environment: {'PATH': Platform.environment['PATH'] ?? '', ...env},
        packageDir: dir,
        flutterExecutable: stub.path,
        out: out,
        err: err,
      );

  void dispose() => dir.deleteSync(recursive: true);
}

void main() {
  test(
    'environment wins over supabase.local.json; URL defaults to the project',
    () {
      final dir = Directory.systemTemp.createTempSync('legal-app-defines-');
      final file = File('${dir.path}/supabase.local.json');
      expect(
        resolveDefines({}, file).values['SUPABASE_URL'],
        defaultSupabaseUrl,
      );

      file.writeAsStringSync(jsonEncode({'SUPABASE_ANON_KEY': _key}));
      final fromFile = resolveDefines({}, file);
      expect(fromFile.values['SUPABASE_ANON_KEY'], _key);
      expect(fromFile.sources['SUPABASE_ANON_KEY'], 'supabase.local.json');

      final fromEnv = resolveDefines({
        'SUPABASE_ANON_KEY': '${_key}_env',
      }, file);
      expect(fromEnv.values['SUPABASE_ANON_KEY'], '${_key}_env');
      expect(fromEnv.sources['SUPABASE_ANON_KEY'], 'environment');
      dir.deleteSync(recursive: true);
    },
  );

  test('defines are placed on the exact run/build command', () {
    final values = {
      'SUPABASE_URL': defaultSupabaseUrl,
      'SUPABASE_ANON_KEY': _key,
      'SUPABASE_AUTH_REDIRECT_URL': '',
    };
    expect(flutterArguments(['run', '-d', 'emulator-5554'], values), [
      'run',
      '--dart-define=SUPABASE_URL=$defaultSupabaseUrl',
      '--dart-define=SUPABASE_ANON_KEY=$_key',
      '-d',
      'emulator-5554',
    ]);
    expect(flutterArguments(['build', 'apk', '--release'], values).take(4), [
      'build',
      'apk',
      '--dart-define=SUPABASE_URL=$defaultSupabaseUrl',
      '--dart-define=SUPABASE_ANON_KEY=$_key',
    ]);
  });

  test(
    'a valid key reaches flutter; output is redacted; server-only env stripped',
    () async {
      final box = _Sandbox();
      final code = await box.run(
        ['build', 'apk', '--release'],
        env: {
          'SUPABASE_ANON_KEY': _key,
          'SUPABASE_SERVICE_ROLE_KEY': 'sb_secret_should_not_leak',
        },
      );
      expect(code, 0, reason: box.err.toString());
      expect(box.argv, contains('--dart-define=SUPABASE_ANON_KEY=$_key'));
      expect(box.argv, contains('--release'));
      expect(box.leaked, isFalse);
      expect(box.out.toString().contains(_key), isFalse);
      expect(
        box.out.toString(),
        contains('sb_publishable_… (${_key.length} chars)'),
      );
      box.dispose();
    },
  );

  test(
    'missing, placeholder and secret keys stop before flutter runs',
    () async {
      for (final env in <Map<String, String>>[
        {},
        {'SUPABASE_ANON_KEY': '<PUBLIC_PUBLISHABLE_KEY>'},
        {'SUPABASE_ANON_KEY': 'sb_secret_TESTONLY_0000000000'},
        {
          'SUPABASE_ANON_KEY': _key,
          'SUPABASE_URL': 'https://x.supabase.co/rest/v1',
        },
      ]) {
        final box = _Sandbox();
        expect(await box.run(['run'], env: env), 1);
        expect(box.argv, isNull, reason: 'flutter must not be invoked');
        expect(
          box.err.toString(),
          contains('Supabase configuration is invalid'),
        );
        box.dispose();
      }
    },
  );

  test('rejects competing Supabase defines and unknown subcommands', () async {
    final box = _Sandbox();
    expect(
      await box.run(
        ['run', '--dart-define=SUPABASE_ANON_KEY=x'],
        env: {'SUPABASE_ANON_KEY': _key},
      ),
      64,
    );
    expect(await box.run(['test'], env: {'SUPABASE_ANON_KEY': _key}), 64);
    expect(box.argv, isNull);
    box.dispose();
  });

  test('validate --file-only matches IDE injection and never launches Flutter', () async {
    final box = _Sandbox();
    final localKey = '${_key}_local';
    File('${box.dir.path}/supabase.local.json').writeAsStringSync(
      jsonEncode({
        'SUPABASE_URL': defaultSupabaseUrl,
        'SUPABASE_ANON_KEY': localKey,
      }),
    );
    final code = await box.run(
      ['validate', '--file-only'],
      env: {
        'SUPABASE_ANON_KEY': 'sb_secret_ENVTEST_0000000000',
        'SUPABASE_SERVICE_ROLE_KEY': 'sb_secret_should_not_leak',
      },
    );
    expect(code, 0, reason: box.err.toString());
    expect(box.argv, isNull, reason: 'preflight must not start Flutter');
    expect(box.out.toString(), contains('SUPABASE_ANON_KEY sb_publishable_…'));
    expect(box.out.toString().contains(localKey), isFalse);
    expect(box.out.toString().contains('sb_secret_ENVTEST'), isFalse);
    box.dispose();
  });

  test('server-only fields in local config are rejected without exposing values', () async {
    final box = _Sandbox();
    const marker = 'sb_secret_PRIVATE_TESTONLY_0000';
    File('${box.dir.path}/supabase.local.json').writeAsStringSync(
      jsonEncode({
        'SUPABASE_URL': defaultSupabaseUrl,
        'SUPABASE_ANON_KEY': _key,
        'SUPABASE_SERVICE_ROLE_KEY': marker,
      }),
    );
    final code = await box.run(['validate', '--file-only']);
    expect(code, 1);
    expect(box.argv, isNull);
    expect(box.err.toString(), contains('server-only Supabase key fields'));
    expect(box.err.toString().contains(marker), isFalse);
    box.dispose();
  });

  test('server-only Supabase defines are rejected before Flutter starts', () async {
    for (final args in <List<String>>[
      ['run', '--dart-define=SUPABASE_SERVICE_ROLE_KEY=sb_secret_PRIVATE_TESTONLY_0000'],
      ['run', '--dart-define', 'SUPABASE_SECRET_KEY=sb_secret_PRIVATE_TESTONLY_0000'],
      ['run', '--dart-define-from-file=other.json'],
    ]) {
      final box = _Sandbox();
      expect(await box.run(args, env: {'SUPABASE_ANON_KEY': _key}), 64);
      expect(box.argv, isNull);
      expect(box.err.toString().contains('sb_secret_PRIVATE_TESTONLY_0000'), isFalse);
      box.dispose();
    }
  });

  test('validate --file-only rejects missing, placeholder and secret local keys', () async {
    for (final local in <Map<String, String>>[
      {'SUPABASE_URL': defaultSupabaseUrl},
      {
        'SUPABASE_URL': defaultSupabaseUrl,
        'SUPABASE_ANON_KEY': '<public anon key>',
      },
      {
        'SUPABASE_URL': defaultSupabaseUrl,
        'SUPABASE_ANON_KEY': 'sb_secret_TESTONLY_0000000000',
      },
    ]) {
      final box = _Sandbox();
      File('${box.dir.path}/supabase.local.json').writeAsStringSync(jsonEncode(local));
      final code = await box.run(
        ['validate', '--file-only'],
        env: {'SUPABASE_ANON_KEY': _key},
      );
      expect(code, 1);
      expect(box.argv, isNull, reason: 'invalid config must not launch Flutter');
      expect(box.err.toString(), contains('Supabase configuration is invalid'));
      expect(box.err.toString().contains(_key), isFalse);
      box.dispose();
    }
  });
}
