/// 从应用内置资源加载默认定义包。
library;

import 'package:flutter/services.dart';

import '../world/definitions.dart';

/// 编辑器内置的 `default` v1 定义包。
///
/// V1 预览只支持这个定义包；以后接入版本化定义库时再替换这里。
Future<DefinitionPackage> loadBundledDefaultDefinitions() async {
  const base = 'assets/default/versions/1';
  final files = <String, List<int>>{};
  for (final name in <String>[
    'manifest.json',
    'terrain.json',
    'props.json',
    'objects.json',
  ]) {
    final data = await rootBundle.load('$base/$name');
    files[name] = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
  }
  return DefinitionPackage.fromFiles(files);
}
