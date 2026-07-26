import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talk2u/src/services/live2d_model_importer.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'talk2u-live2d-import-',
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test(
    'desktop import extracts every file without requiring LipSync',
    () async {
      final model = jsonEncode({
        'Version': 3,
        'FileReferences': {
          'Moc': 'model.moc3',
          'Textures': ['textures/texture.png'],
        },
      });
      final archive = Archive()
        ..addFile(_file('avatar/character.model3.json', utf8.encode(model)))
        ..addFile(
          _file('avatar/MODEL.MOC3', const [77, 79, 67, 51, 3, 0, 0, 0]),
        )
        ..addFile(_file('avatar/Textures/TEXTURE.PNG', const [1, 2, 3, 4]))
        ..addFile(_file('avatar/motions/idle.motion3.json', utf8.encode('{}')))
        ..addFile(
          _file('avatar/expressions/smile.exp3.json', utf8.encode('{}')),
        )
        ..addFile(_file('licenses/NOTICE.txt', utf8.encode('license')));
      final zip = File(p.join(temporaryDirectory.path, 'character.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      final support = Directory(p.join(temporaryDirectory.path, 'support'));

      final importedPath =
          await Live2dModelImporter.importArchiveOnDesktopForTesting(
            zip.path,
            support,
          );

      final importedModel = File(importedPath);
      expect(importedModel.existsSync(), isTrue);
      final extractionRoot = importedModel.parent.parent;
      expect(
        File(
          p.join(extractionRoot.path, 'avatar', 'motions', 'idle.motion3.json'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(extractionRoot.path, 'licenses', 'NOTICE.txt'),
        ).readAsStringSync(),
        'license',
      );
      final normalized =
          jsonDecode(importedModel.readAsStringSync()) as Map<String, dynamic>;
      final references = normalized['FileReferences'] as Map<String, dynamic>;
      expect(references['Moc'], 'MODEL.MOC3');
      expect(references['Textures'], ['Textures/TEXTURE.PNG']);
      expect(references['Motions'], {
        'Idle': [
          {'File': 'motions/idle.motion3.json'},
        ],
      });
      expect(references['Expressions'], [
        {'Name': 'smile', 'File': 'expressions/smile.exp3.json'},
      ]);
      expect(normalized.containsKey('Groups'), isFalse);
      final avatar =
          jsonDecode(
                File(
                  p.join(importedModel.parent.path, 'talk2u.avatar.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        (avatar['naturalBehavior'] as Map)['speechBody'],
        containsPair('enabled', true),
      );
    },
  );

  test('desktop import maps VTube Studio mouth and body parameters', () async {
    final model = jsonEncode({
      'Version': 3,
      'FileReferences': {
        'Moc': 'model.moc3',
        'Textures': ['texture.png'],
        'DisplayInfo': 'model.cdi3.json',
      },
    });
    final cdi = jsonEncode({
      'Version': 3,
      'Parameters': [
        {'Id': 'ParamMouthOpenY', 'Name': 'Mouth Open'},
        {'Id': 'ParamMouthForm', 'Name': 'Mouth Form'},
        {'Id': 'AngleX', 'Name': 'Angle X'},
        {'Id': 'AngleY', 'Name': 'Angle Y'},
        {'Id': 'AngleZ', 'Name': 'Angle Z'},
        {'Id': 'ParamBodyAngleY2', 'Name': 'Body Y'},
        {'Id': 'ParamBodyAngleZ3', 'Name': 'Shoulders Sway'},
        {'Id': 'Param104', 'Name': 'Upper Arm L'},
        {'Id': 'Param431', 'Name': 'Upper Arm R'},
        {'Id': 'Param106', 'Name': 'Hand L'},
        {'Id': 'Param433', 'Name': 'Hand R'},
      ],
    });
    final archive = Archive()
      ..addFile(_file('avatar/model.model3.json', utf8.encode(model)))
      ..addFile(_file('avatar/model.moc3', const [77, 79, 67, 51, 3, 0, 0, 0]))
      ..addFile(_file('avatar/texture.png', const [1, 2, 3, 4]))
      ..addFile(_file('avatar/model.cdi3.json', utf8.encode(cdi)))
      ..addFile(_file('avatar/Wave Arm L.exp3.json', utf8.encode('{}')))
      ..addFile(
        _file('avatar/Animations/Idle.motion3.json', utf8.encode('{}')),
      );
    final zip = File(p.join(temporaryDirectory.path, 'vtuber.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final support = Directory(p.join(temporaryDirectory.path, 'support'));

    final importedPath =
        await Live2dModelImporter.importArchiveOnDesktopForTesting(
          zip.path,
          support,
        );
    final avatar =
        jsonDecode(
              File(
                p.join(File(importedPath).parent.path, 'talk2u.avatar.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final lipSync = avatar['lipSync'] as Map;
    final aliases = avatar['parameterAliases'] as Map;
    final capabilities = avatar['modelCapabilities'] as Map;

    expect(lipSync['mode'], 'open');
    expect(lipSync['parameterIds'], ['ParamMouthOpenY']);
    expect(aliases['angleX'], ['AngleX']);
    expect(aliases['bodyY'], ['ParamBodyAngleY2']);
    expect(aliases['shoulder'], ['ParamBodyAngleZ3']);
    expect(aliases['armL'], ['Param104']);
    expect(aliases['armR'], ['Param431']);
    expect(aliases['handL'], ['Param106']);
    expect(aliases['handR'], ['Param433']);
    expect(capabilities['expressions'], contains('Wave Arm L'));
    expect((capabilities['motions'] as Map)['Idle'], 1);
  });

  test('desktop import enables five-vowel lip sync when available', () async {
    final model = jsonEncode({
      'Version': 3,
      'FileReferences': {
        'Moc': 'model.moc3',
        'Textures': ['texture.png'],
        'DisplayInfo': 'model.cdi3.json',
      },
    });
    final cdi = jsonEncode({
      'Version': 3,
      'Parameters': [
        'ParamA',
        'ParamI',
        'ParamU',
        'ParamE',
        'ParamO',
      ].map((id) => {'Id': id, 'Name': id}).toList(),
    });
    final archive = Archive()
      ..addFile(_file('model.model3.json', utf8.encode(model)))
      ..addFile(_file('model.moc3', const [77, 79, 67, 51, 3, 0, 0, 0]))
      ..addFile(_file('texture.png', const [1, 2, 3, 4]))
      ..addFile(_file('model.cdi3.json', utf8.encode(cdi)));
    final zip = File(p.join(temporaryDirectory.path, 'viseme.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final support = Directory(p.join(temporaryDirectory.path, 'support'));

    final importedPath =
        await Live2dModelImporter.importArchiveOnDesktopForTesting(
          zip.path,
          support,
        );
    final avatar =
        jsonDecode(
              File(
                p.join(File(importedPath).parent.path, 'talk2u.avatar.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final lipSync = avatar['lipSync'] as Map;

    expect(lipSync['mode'], 'viseme');
    expect(lipSync['visemeParameterIds'], [
      'ParamA',
      'ParamI',
      'ParamU',
      'ParamE',
      'ParamO',
    ]);
  });

  test(
    'desktop import rejects ZIP path traversal and removes output',
    () async {
      final archive = Archive()
        ..addFile(_file('../escape.txt', utf8.encode('blocked')));
      final zip = File(p.join(temporaryDirectory.path, 'unsafe.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      final support = Directory(p.join(temporaryDirectory.path, 'support'));

      await expectLater(
        Live2dModelImporter.importArchiveOnDesktopForTesting(zip.path, support),
        throwsA(isA<FormatException>()),
      );

      final modelRoot = Directory(p.join(support.path, 'live2d_models'));
      expect(
        modelRoot.existsSync()
            ? modelRoot.listSync()
            : const <FileSystemEntity>[],
        isEmpty,
      );
      expect(File(p.join(support.path, 'escape.txt')).existsSync(), isFalse);
    },
  );

  test('desktop import returns every model found in one archive', () async {
    final model = jsonEncode({
      'Version': 3,
      'FileReferences': {
        'Moc': 'model.moc3',
        'Textures': ['texture.png'],
      },
    });
    final archive = Archive()
      ..addFile(_file('one.model3.json', utf8.encode(model)))
      ..addFile(_file('two.model3.json', utf8.encode(model)))
      ..addFile(_file('model.moc3', const [77, 79, 67, 51, 3, 0, 0, 0]))
      ..addFile(_file('texture.png', const [1, 2, 3, 4]));
    final zip = File(p.join(temporaryDirectory.path, 'multiple.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final support = Directory(p.join(temporaryDirectory.path, 'support'));

    final paths =
        await Live2dModelImporter.importArchiveModelsOnDesktopForTesting(
          zip.path,
          support,
        );

    expect(paths, hasLength(2));
    expect(
      paths.map(p.basename),
      orderedEquals(['one.model3.json', 'two.model3.json']),
    );
    expect(paths.every((path) => File(path).existsSync()), isTrue);
  });

  test('desktop import rejects invalid cdi3 version', () async {
    final model = jsonEncode({
      'Version': 3,
      'FileReferences': {
        'Moc': 'model.moc3',
        'Textures': ['texture.png'],
        'DisplayInfo': 'model.cdi3.json',
      },
    });
    final archive = Archive()
      ..addFile(_file('model.model3.json', utf8.encode(model)))
      ..addFile(_file('model.moc3', const [77, 79, 67, 51, 3, 0, 0, 0]))
      ..addFile(_file('texture.png', const [1, 2, 3, 4]))
      ..addFile(
        _file('model.cdi3.json', utf8.encode(jsonEncode({'Version': 2}))),
      );
    final zip = File(p.join(temporaryDirectory.path, 'invalid-cdi.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final support = Directory(p.join(temporaryDirectory.path, 'support'));

    await expectLater(
      Live2dModelImporter.importArchiveOnDesktopForTesting(zip.path, support),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Version 必须为 3'),
        ),
      ),
    );
    expect(
      Directory(p.join(support.path, 'live2d_models')).listSync(),
      isEmpty,
    );
  });
}

ArchiveFile _file(String name, List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes);
