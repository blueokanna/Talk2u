import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'talk2u-moss-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('accepts a non-empty RIFF WAVE file', () async {
    final file = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}valid.wav',
    );
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      38,
      0,
      0,
      0,
      ...'WAVE'.codeUnits,
      ...List<int>.filled(34, 0),
    ];
    await file.writeAsBytes(bytes);

    expect(await isPlayableMossWav(file), isTrue);
  });

  test('rejects missing, empty, and invalid audio files', () async {
    final missing = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}missing.wav',
    );
    final empty = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}empty.wav',
    );
    final invalid = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}invalid.wav',
    );
    await empty.writeAsBytes(const []);
    await invalid.writeAsBytes(List<int>.filled(64, 1));

    expect(await isPlayableMossWav(missing), isFalse);
    expect(await isPlayableMossWav(empty), isFalse);
    expect(await isPlayableMossWav(invalid), isFalse);
  });
}
