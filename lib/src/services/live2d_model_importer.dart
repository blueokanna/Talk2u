import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class Live2dModelImporter {
  Live2dModelImporter._();

  static const _channel = MethodChannel('talk2u/live2d_models');
  static const _maximumArchiveBytes = 512 * 1024 * 1024;
  static const _maximumEntries = 8192;

  static Future<String> importArchive(String archivePath) async {
    final models = await importArchiveModels(archivePath);
    return models.first;
  }

  static Future<List<String>> importArchiveModels(String archivePath) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final modelPaths = await _channel.invokeListMethod<String>(
        'importArchiveModels',
        {'path': archivePath},
      );
      final paths = modelPaths
          ?.where((path) => path.trim().isNotEmpty)
          .toList(growable: false);
      if (paths == null || paths.isEmpty) {
        throw const FormatException('原生端没有返回 Live2D 模型列表');
      }
      return paths;
    }
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return _importArchiveModelsOnDesktop(archivePath);
    }
    throw UnsupportedError('当前平台暂不支持导入 Live2D ZIP');
  }

  static Future<String> installBundledMao() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final modelPath = await _channel.invokeMethod<String>(
        'installBundledMao',
      );
      if (modelPath == null || modelPath.isEmpty) {
        throw const FormatException('原生端没有返回内置 Live2D 模型路径');
      }
      return modelPath;
    }
    return 'asset:///model/Live2d/mao/runtime/mao_pro.model3.json';
  }

  @visibleForTesting
  static Future<String> importArchiveOnDesktopForTesting(
    String archivePath,
    Directory supportDirectory,
  ) async => (await _importArchiveModelsOnDesktop(
    archivePath,
    supportDirectory: supportDirectory,
  )).first;

  @visibleForTesting
  static Future<List<String>> importArchiveModelsOnDesktopForTesting(
    String archivePath,
    Directory supportDirectory,
  ) => _importArchiveModelsOnDesktop(
    archivePath,
    supportDirectory: supportDirectory,
  );

  static Future<List<String>> _importArchiveModelsOnDesktop(
    String archivePath, {
    Directory? supportDirectory,
  }) async {
    final source = File(archivePath);
    if (!source.existsSync()) throw const FileSystemException('找不到 ZIP 文件');
    if (source.lengthSync() > _maximumArchiveBytes) {
      throw const FormatException('Live2D ZIP 超过 512 MB 导入限制');
    }

    final support = supportDirectory ?? await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'live2d_models'))
      ..createSync(recursive: true);
    final destination = Directory(
      p.join(
        root.path,
        'model-${DateTime.now().microsecondsSinceEpoch}-${source.lengthSync().toRadixString(16)}',
      ),
    )..createSync();

    InputFileStream? input;
    try {
      input = InputFileStream(source.path);
      final archive = ZipDecoder().decodeStream(input);
      if (archive.isEmpty) throw const FormatException('ZIP 文件为空或格式无效');
      if (archive.length > _maximumEntries) {
        throw const FormatException('ZIP 文件条目过多');
      }

      var extractedBytes = 0;
      for (final entry in archive) {
        final relative = _safeArchivePath(entry.name);
        if (relative == null) continue;
        extractedBytes += entry.size;
        if (extractedBytes > _maximumArchiveBytes) {
          throw const FormatException('解压后模型超过 512 MB 限制');
        }
        final outputPath = p.joinAll([
          destination.path,
          ...p.posix.split(relative),
        ]);
        if (!_isWithin(destination.path, outputPath)) {
          throw FormatException('ZIP 包含越界路径: ${entry.name}');
        }
        if (entry.isDirectory) {
          Directory(outputPath).createSync(recursive: true);
        } else if (entry.isFile) {
          Directory(p.dirname(outputPath)).createSync(recursive: true);
          final output = OutputFileStream(outputPath);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
        } else {
          throw FormatException('ZIP 包含不支持的链接条目: ${entry.name}');
        }
      }

      final modelFiles =
          destination
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.model3.json'))
              .toList()
            ..sort((left, right) => left.path.compareTo(right.path));
      if (modelFiles.isEmpty) {
        throw const FormatException('ZIP 中没有 .model3.json');
      }
      for (final modelFile in modelFiles) {
        _validateAndNormalizeModel(modelFile, destination);
      }
      return List.unmodifiable(
        modelFiles.map((modelFile) => modelFile.absolute.path),
      );
    } catch (_) {
      if (destination.existsSync()) destination.deleteSync(recursive: true);
      rethrow;
    } finally {
      input?.closeSync();
    }
  }

  static String? _safeArchivePath(String rawName) {
    final source = rawName.replaceAll('\\', '/');
    if (source.isEmpty) return null;
    if (source.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(source)) {
      throw FormatException('ZIP 包含绝对路径: $rawName');
    }
    final segments = p.posix.split(source);
    if (segments.contains('..')) {
      throw FormatException('ZIP 包含不安全路径: $rawName');
    }
    final normalized = p.posix.normalize(source);
    return normalized == '.' ? null : normalized;
  }

  static bool _isWithin(String root, String candidate) {
    final normalizedRoot = p.canonicalize(p.absolute(root));
    final normalizedCandidate = p.canonicalize(p.absolute(candidate));
    return p.equals(normalizedRoot, normalizedCandidate) ||
        p.isWithin(normalizedRoot, normalizedCandidate);
  }

  static void _validateAndNormalizeModel(File modelFile, Directory root) {
    final decoded = jsonDecode(modelFile.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('model3.json 不是 JSON 对象');
    }
    if (decoded['Version'] != 3) {
      throw const FormatException('只支持 Cubism .model3.json Version 3');
    }
    final rawReferences = decoded['FileReferences'];
    if (rawReferences is! Map) {
      throw const FormatException('model3.json 缺少 FileReferences');
    }
    final references = Map<String, dynamic>.from(rawReferences);
    decoded['FileReferences'] = references;
    final modelDirectory = modelFile.parent;
    _includeUnreferencedVtuberAssets(references, modelDirectory, root);

    String normalizeReference(String value) {
      final file = _resolveReference(modelDirectory, root, value);
      return p
          .relative(file.path, from: modelDirectory.path)
          .replaceAll('\\', '/');
    }

    final moc = references['Moc'];
    if (moc is! String || moc.trim().isEmpty) {
      throw const FormatException('model3.json 缺少 Moc 文件引用');
    }
    references['Moc'] = normalizeReference(moc);
    final textures = references['Textures'];
    if (textures is! List || textures.isEmpty) {
      throw const FormatException('model3.json 没有纹理引用');
    }
    for (var index = 0; index < textures.length; index++) {
      final value = textures[index];
      if (value is! String) throw const FormatException('纹理引用格式无效');
      textures[index] = normalizeReference(value);
    }

    for (final key in ['Physics', 'Pose', 'UserData', 'DisplayInfo']) {
      final value = references[key];
      if (value is String && value.isNotEmpty) {
        references[key] = normalizeReference(value);
      }
    }
    final expressions = references['Expressions'];
    if (expressions is List) {
      for (final expression in expressions.whereType<Map>()) {
        final value = expression['File'];
        if (value is String && value.isNotEmpty) {
          expression['File'] = normalizeReference(value);
        }
      }
    }
    final motions = references['Motions'];
    if (motions is Map) {
      for (final group in motions.values.whereType<List>()) {
        for (final motion in group.whereType<Map>()) {
          final value = motion['File'];
          if (value is String && value.isNotEmpty) {
            motion['File'] = normalizeReference(value);
          }
        }
      }
    }

    final mocFile = File(
      p.join(modelDirectory.path, references['Moc'] as String),
    );
    final handle = mocFile.openSync();
    try {
      final header = handle.readSync(8);
      if (header.length != 8 ||
          ascii.decode(header.take(4).toList()) != 'MOC3') {
        throw FormatException('${p.basename(mocFile.path)} 不是有效的 moc3 文件');
      }
      final version = header[4];
      if (version < 1 || version > 5) {
        throw FormatException('当前 Cubism Core 不支持 moc3 版本 $version');
      }
    } finally {
      handle.closeSync();
    }

    Map<String, dynamic>? displayInfoJson;
    final displayInfo = references['DisplayInfo'];
    if (displayInfo is String && displayInfo.isNotEmpty) {
      final value = jsonDecode(
        File(p.join(modelDirectory.path, displayInfo)).readAsStringSync(),
      );
      if (value is! Map || value['Version'] != 3) {
        throw const FormatException('cdi3.json 的 Version 必须为 3');
      }
      displayInfoJson = Map<String, dynamic>.from(value);
    }
    _writeAvatarConfig(modelDirectory, decoded, references, displayInfoJson);
    modelFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(decoded),
    );
  }

  static void _writeAvatarConfig(
    Directory modelDirectory,
    Map<String, dynamic> model,
    Map<String, dynamic> references,
    Map<String, dynamic>? displayInfo,
  ) {
    final configFile = File(p.join(modelDirectory.path, 'talk2u.avatar.json'));
    final config = configFile.existsSync()
        ? Map<String, dynamic>.from(jsonDecode(configFile.readAsStringSync()))
        : <String, dynamic>{};
    Map<String, dynamic> object(Map<String, dynamic> parent, String key) {
      final value = parent[key];
      if (value is Map) return parent[key] = Map<String, dynamic>.from(value);
      return parent[key] = <String, dynamic>{};
    }

    config['version'] = 1;
    final parameterIds = (displayInfo?['Parameters'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item['Id'])
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    final groupedLipSyncIds = (model['Groups'] as List? ?? const [])
        .whereType<Map>()
        .where((group) => '${group['Name']}'.toLowerCase() == 'lipsync')
        .expand(
          (group) => (group['Ids'] as List? ?? const []).whereType<String>(),
        )
        .toSet();
    final vowelIds = [
      'ParamA',
      'ParamI',
      'ParamU',
      'ParamE',
      'ParamO',
    ].where(parameterIds.contains).toList(growable: false);
    final openIds = parameterIds
        .where((id) => id == 'ParamMouthOpenY')
        .followedBy(groupedLipSyncIds)
        .toSet()
        .toList(growable: false);
    final lipSync = object(config, 'lipSync');
    if (vowelIds.length >= 3) {
      lipSync.putIfAbsent('mode', () => 'viseme');
      lipSync.putIfAbsent('parameterIds', () => vowelIds);
      lipSync.putIfAbsent('visemeParameterIds', () => vowelIds);
    } else {
      lipSync.putIfAbsent('mode', () => 'open');
      lipSync.putIfAbsent('parameterIds', () => openIds);
    }
    lipSync.putIfAbsent('gain', () => 1.8);
    lipSync.putIfAbsent('smoothing', () => 0.45);
    lipSync.putIfAbsent('attack', () => 0.58);
    lipSync.putIfAbsent('release', () => 0.28);
    lipSync.putIfAbsent('staleAfterMs', () => 240);

    final naturalBehavior = object(config, 'naturalBehavior');
    naturalBehavior.putIfAbsent('expressionDurationMs', () => 4200);
    final speechBody = object(naturalBehavior, 'speechBody');
    speechBody.putIfAbsent('enabled', () => true);
    speechBody.putIfAbsent('gain', () => 1.15);
    speechBody.putIfAbsent('smoothing', () => 0.12);
    final gaze = object(naturalBehavior, 'gaze');
    gaze.putIfAbsent('enabled', () => true);
    gaze.putIfAbsent('intervalMinMs', () => 2600);
    gaze.putIfAbsent('intervalMaxMs', () => 5600);
    gaze.putIfAbsent('rangeX', () => 0.22);
    gaze.putIfAbsent('rangeY', () => 0.12);
    naturalBehavior.putIfAbsent('microExpressions', () => <dynamic>[]);

    final aliases = object(config, 'parameterAliases');
    const candidates = <String, List<String>>{
      'angleX': ['ParamAngleX', 'AngleX'],
      'angleY': ['ParamAngleY', 'AngleY'],
      'angleZ': ['ParamAngleZ', 'AngleZ'],
      'bodyX': ['ParamBodyAngleX', 'ParamBodyAngleX3', 'Param92'],
      'bodyY': ['ParamBodyAngleY', 'ParamBodyAngleY2', 'Param93'],
      'bodyZ': ['ParamBodyAngleZ', 'ParamBodyAngleZ2', 'Param94'],
      'shoulder': ['ParamShoulderY', 'ParamBodyAngleZ3'],
      'armL': ['ParamArmLA01', 'ParamArmLA', 'Param104'],
      'armR': ['ParamArmRA01', 'ParamArmRA', 'Param431'],
      'forearmL': ['ParamArmLA02', 'ParamArmLB01', 'Param105'],
      'forearmR': ['ParamArmRA02', 'ParamArmRB01', 'Param432'],
      'handL': ['ParamHandL', 'Param106'],
      'handR': ['ParamHandR', 'Param433'],
    };
    for (final entry in candidates.entries) {
      final values = entry.value
          .where(parameterIds.contains)
          .toList(growable: false);
      if (values.isNotEmpty) aliases.putIfAbsent(entry.key, () => values);
    }

    final capabilities = object(config, 'modelCapabilities');
    capabilities['expressions'] =
        (references['Expressions'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => item['Name'])
            .whereType<String>()
            .toList(growable: false);
    final motions = <String, int>{};
    final motionGroups = references['Motions'];
    if (motionGroups is Map) {
      for (final entry in motionGroups.entries) {
        if (entry.value is List) {
          motions['${entry.key}'] = (entry.value as List).length;
        }
      }
    }
    capabilities['motions'] = motions;
    config.putIfAbsent('cues', () => <String, dynamic>{});
    configFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  static void _includeUnreferencedVtuberAssets(
    Map<String, dynamic> references,
    Directory modelDirectory,
    Directory root,
  ) {
    final expressions = switch (references['Expressions']) {
      final List<dynamic> value => value,
      _ => <dynamic>[],
    };
    references['Expressions'] = expressions;
    final referencedExpressions = expressions
        .whereType<Map>()
        .map((item) => item['File'])
        .whereType<String>()
        .map((value) => value.replaceAll('\\', '/').toLowerCase())
        .toSet();
    final expressionNames = expressions
        .whereType<Map>()
        .map((item) => item['Name'])
        .whereType<String>()
        .toSet();

    final motions = switch (references['Motions']) {
      final Map<dynamic, dynamic> value => Map<String, dynamic>.from(value),
      _ => <String, dynamic>{},
    };
    references['Motions'] = motions;
    final referencedMotions = motions.values
        .whereType<List>()
        .expand((items) => items.whereType<Map>())
        .map((item) => item['File'])
        .whereType<String>()
        .map((value) => value.replaceAll('\\', '/').toLowerCase())
        .toSet();

    final files = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>();
    for (final file in files) {
      final relative = p
          .relative(file.path, from: modelDirectory.path)
          .replaceAll('\\', '/');
      final normalized = relative.toLowerCase();
      if (normalized.endsWith('.exp3.json') &&
          !referencedExpressions.contains(normalized)) {
        final baseName = p
            .basename(file.path)
            .replaceFirst(RegExp(r'\.exp3\.json$', caseSensitive: false), '');
        var name = baseName;
        var suffix = 2;
        while (expressionNames.contains(name)) {
          name = '$baseName $suffix';
          suffix++;
        }
        expressions.add({'Name': name, 'File': relative});
        expressionNames.add(name);
        referencedExpressions.add(normalized);
      } else if (normalized.endsWith('.motion3.json') &&
          !referencedMotions.contains(normalized)) {
        final baseName = p
            .basename(file.path)
            .replaceFirst(
              RegExp(r'\.motion3\.json$', caseSensitive: false),
              '',
            );
        final group = baseName.toLowerCase() == 'idle' ? 'Idle' : baseName;
        final items = switch (motions[group]) {
          final List<dynamic> value => value,
          _ => <dynamic>[],
        };
        motions[group] = items;
        items.add({'File': relative});
        referencedMotions.add(normalized);
      }
    }

    if (expressions.isEmpty) references.remove('Expressions');
    if (motions.isEmpty) references.remove('Motions');
  }

  static File _resolveReference(
    Directory modelDirectory,
    Directory root,
    String rawReference,
  ) {
    final reference = rawReference.replaceAll('\\', '/');
    if (reference.contains('://') ||
        reference.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(reference)) {
      throw FormatException('模型引用了非本地资源: $rawReference');
    }

    var current = modelDirectory.absolute;
    for (final segment in p.posix.split(reference)) {
      if (segment == '.' || segment.isEmpty) continue;
      if (segment == '..') {
        current = current.parent;
        if (!_isWithin(root.path, current.path)) {
          throw FormatException('模型引用路径越界: $rawReference');
        }
        continue;
      }
      final matches = current
          .listSync(followLinks: false)
          .where(
            (entry) =>
                p.basename(entry.path).toLowerCase() == segment.toLowerCase(),
          )
          .toList();
      if (matches.length != 1) {
        throw FormatException('模型资源缺失或大小写冲突: $rawReference');
      }
      final match = matches.single;
      if (match is Directory) {
        current = match;
      } else if (match is File && segment == p.posix.basename(reference)) {
        if (!_isWithin(root.path, match.path)) {
          throw FormatException('模型引用路径越界: $rawReference');
        }
        return match;
      } else {
        throw FormatException('模型资源路径无效: $rawReference');
      }
    }
    throw FormatException('模型资源缺失: $rawReference');
  }
}
