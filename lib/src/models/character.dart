import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';

/// 性别枚举
enum CharacterGender { male, female, other }

/// AI 角色模型
class Character {
  final String id;
  final String name;
  final CharacterGender gender;
  final String description; // 角色简介
  final String setting; // 角色设定（系统提示词）
  final String greeting; // 角色开场白
  final String dialogueExample; // 对话风格示例
  final String userName; // 用户名称（AI 对你的称呼）
  final String userSetting; // 用户聊天人设
  final List<String> tags;
  final int createdAt;
  final int updatedAt;

  const Character({
    required this.id,
    required this.name,
    required this.gender,
    this.description = '',
    this.setting = '',
    this.greeting = '',
    this.dialogueExample = '',
    this.userName = '',
    this.userSetting = '',
    this.tags = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  /// 构建发送给 API 的系统提示词
  String buildSystemPrompt() {
    final parts = <String>[];

    parts.add('你是"$name"，一个AI角色。请始终以该角色的身份进行对话，不要跳出角色。');

    if (gender != CharacterGender.other) {
      parts.add('你的性别是${gender == CharacterGender.male ? "男" : "女"}。');
    }

    if (setting.isNotEmpty) {
      parts.add('角色设定：$setting');
    }

    if (description.isNotEmpty) {
      parts.add('角色简介：$description');
    }

    if (dialogueExample.isNotEmpty) {
      parts.add('对话风格示例：$dialogueExample');
    }

    if (userName.isNotEmpty) {
      parts.add('请称呼用户为"$userName"。');
    }

    if (userSetting.isNotEmpty) {
      parts.add('用户的人设信息：$userSetting');
    }

    return parts.join('\n');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'gender': gender.index,
    'description': description,
    'setting': setting,
    'greeting': greeting,
    'dialogueExample': dialogueExample,
    'userName': userName,
    'userSetting': userSetting,
    'tags': tags,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  factory Character.fromJson(Map<String, dynamic> json) => Character(
    id: json['id'] as String,
    name: json['name'] as String,
    gender: CharacterGender.values[json['gender'] as int? ?? 2],
    description: json['description'] as String? ?? '',
    setting: json['setting'] as String? ?? '',
    greeting: json['greeting'] as String? ?? '',
    dialogueExample: json['dialogueExample'] as String? ?? '',
    userName: json['userName'] as String? ?? '',
    userSetting: json['userSetting'] as String? ?? '',
    tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
    createdAt: json['createdAt'] as int? ?? 0,
    updatedAt: json['updatedAt'] as int? ?? 0,
  );

  Character copyWith({
    String? id,
    String? name,
    CharacterGender? gender,
    String? description,
    String? setting,
    String? greeting,
    String? dialogueExample,
    String? userName,
    String? userSetting,
    List<String>? tags,
    int? createdAt,
    int? updatedAt,
  }) => Character(
    id: id ?? this.id,
    name: name ?? this.name,
    gender: gender ?? this.gender,
    description: description ?? this.description,
    setting: setting ?? this.setting,
    greeting: greeting ?? this.greeting,
    dialogueExample: dialogueExample ?? this.dialogueExample,
    userName: userName ?? this.userName,
    userSetting: userSetting ?? this.userSetting,
    tags: tags ?? this.tags,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// 角色本地存储管理
class CharacterStore {
  static CharacterStore? _instance;
  static CharacterStore get instance => _instance ??= CharacterStore._();
  CharacterStore._();

  List<Character> _characters = [];
  bool _loaded = false;

  List<Character> get characters => List.unmodifiable(_characters);

  Future<String> get _dirPath async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/characters');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> load() async {
    if (_loaded) return;
    final dir = await _dirPath;
    final directory = Directory(dir);
    if (!await directory.exists()) {
      _loaded = true;
      return;
    }

    final files = await directory
        .list()
        .where((e) => e.path.endsWith('.json'))
        .toList();

    _characters = [];
    for (final file in files) {
      try {
        final content = await File(file.path).readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _characters.add(Character.fromJson(json));
      } catch (_) {
        // 跳过损坏的文件
      }
    }
    _characters.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _loaded = true;
  }

  Future<void> save(Character character) async {
    final dir = await _dirPath;
    final file = File('$dir/${character.id}.json');
    await file.writeAsString(jsonEncode(character.toJson()));

    final index = _characters.indexWhere((c) => c.id == character.id);
    if (index >= 0) {
      _characters[index] = character;
    } else {
      _characters.insert(0, character);
    }
    _characters.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> delete(String id) async {
    final dir = await _dirPath;
    final file = File('$dir/$id.json');
    if (await file.exists()) {
      await file.delete();
    }
    _characters.removeWhere((c) => c.id == id);
  }

  Character? getById(String id) {
    try {
      return _characters.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 导出单个角色为 JSON 文件，返回文件路径
  Future<String> exportCharacter(Character character) async {
    final dir = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${dir.path}/character_exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    final safeName = character.name.replaceAll(
      RegExp(r'[^\w\u4e00-\u9fff]'),
      '_',
    );
    final filePath =
        '${exportDir.path}/${safeName}_${character.id.substring(0, 8)}.json';
    final json = jsonEncode(character.toJson());
    await File(filePath).writeAsString(json);
    return filePath;
  }

  /// 批量导出所有角色为单个 JSON 文件，返回文件路径
  Future<String> exportAllCharacters() async {
    final dir = await getApplicationDocumentsDirectory();
    final exportDir = Directory('${dir.path}/character_exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    final filePath =
        '${exportDir.path}/all_characters_${DateTime.now().millisecondsSinceEpoch}.json';
    final jsonList = _characters.map((c) => c.toJson()).toList();
    final json = jsonEncode({
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'characters': jsonList,
    });
    await File(filePath).writeAsString(json);
    return filePath;
  }

  /// 从文件路径导入角色（支持单个和批量）
  /// 返回成功导入的角色数量
  Future<int> importFromFile(String filePath) async {
    try {
      final content = await File(filePath).readAsString();
      final decoded = jsonDecode(content);

      if (decoded is Map<String, dynamic>) {
        // 检查是否是批量导出格式
        if (decoded.containsKey('characters') &&
            decoded['characters'] is List) {
          final list = decoded['characters'] as List;
          int count = 0;
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              final character = _importSingleCharacter(item);
              if (character != null) {
                await save(character);
                count++;
              }
            }
          }
          return count;
        } else {
          // 单个角色格式
          final character = _importSingleCharacter(decoded);
          if (character != null) {
            await save(character);
            return 1;
          }
        }
      }
      return 0;
    } catch (e) {
      debugPrint('Failed to import character: $e');
      return 0;
    }
  }

  /// 通过 file_picker 选择文件并导入
  Future<int> importFromPicker() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return 0;
      final path = result.files.single.path;
      if (path == null) return 0;
      return importFromFile(path);
    } catch (e) {
      debugPrint('Failed to pick file for import: $e');
      return 0;
    }
  }

  /// 解析单个角色 JSON，生成新 ID 避免冲突
  Character? _importSingleCharacter(Map<String, dynamic> json) {
    try {
      final original = Character.fromJson(json);
      // 检查是否已存在相同 ID
      final existing = getById(original.id);
      if (existing != null) {
        // ID 冲突，生成新 ID
        final now = DateTime.now().millisecondsSinceEpoch;
        return original.copyWith(
          id: '${now}_${original.id.hashCode.abs()}',
          createdAt: now,
          updatedAt: now,
        );
      }
      return original;
    } catch (e) {
      debugPrint('Failed to parse character JSON: $e');
      return null;
    }
  }
}
