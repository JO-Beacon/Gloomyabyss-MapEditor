/// GMAP 容器 v2（读取时兼容 v1，用于旧 `.gmap` 迁移）。
library;

import 'dart:convert';
import 'dart:typed_data';

class GmapException implements Exception {
  const GmapException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GmapContainer {
  GmapContainer({required this.version, required this.entries});

  static const List<int> magic = <int>[0x47, 0x4D, 0x41, 0x50];
  static const int currentVersion = 2;

  final int version;
  final Map<String, Uint8List> entries;

  /// 读取 v1 或 v2；v1 只用于迁移输入。
  static GmapContainer decode(List<int> bytes, {bool allowVersion1 = false}) {
    if (bytes.length < 8) throw const GmapException('文件太小');
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) throw const GmapException('不是 .gmap 文件');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final version = data.getUint16(4, Endian.little);
    if (version != currentVersion && !(allowVersion1 && version == 1)) {
      throw GmapException('不支持的容器版本：$version');
    }
    final count = data.getUint16(6, Endian.little);
    final entries = <String, Uint8List>{};
    var pos = 8;
    for (var i = 0; i < count; i++) {
      if (pos + 2 > bytes.length) throw const GmapException('数据被截断');
      final nameLength = data.getUint16(pos, Endian.little);
      pos += 2;
      if (pos + nameLength > bytes.length) {
        throw const GmapException('数据被截断');
      }
      final name = utf8.decode(bytes.sublist(pos, pos + nameLength));
      pos += nameLength;
      if (!_isSafeName(name)) {
        throw GmapException('非法条目名：$name');
      }
      if (entries.containsKey(name)) {
        throw GmapException('重复条目：$name');
      }
      if (pos + 4 > bytes.length) throw const GmapException('数据被截断');
      final size = data.getUint32(pos, Endian.little);
      pos += 4;
      if (pos + size > bytes.length) throw const GmapException('数据被截断');
      entries[name] = Uint8List.fromList(bytes.sublist(pos, pos + size));
      pos += size;
    }
    if (pos != bytes.length) throw const GmapException('容器末尾有多余数据');
    return GmapContainer(version: version, entries: entries);
  }

  /// 写出当前版本；正常保存使用 v2，v1 仅用于迁移测试夹具。
  /// 条目按名字升序。
  Uint8List encode() {
    if (version != 1 && version != 2) {
      throw GmapException('不支持的容器版本：$version');
    }
    if (entries.length > 0xFFFF) {
      throw const GmapException('条目数超过 65535');
    }
    final names = entries.keys.toList()..sort();
    final builder = BytesBuilder(copy: false);
    builder.add(magic);
    final header = ByteData(4)
      ..setUint16(0, version, Endian.little)
      ..setUint16(2, names.length, Endian.little);
    builder.add(header.buffer.asUint8List());
    for (final name in names) {
      if (!_isSafeName(name)) throw GmapException('非法条目名：$name');
      final nameBytes = utf8.encode(name);
      if (nameBytes.length > 0xFFFF) {
        throw GmapException('条目名太长：$name');
      }
      final data = entries[name]!;
      if (data.length > 0xFFFFFFFF) {
        throw GmapException('条目太大：$name');
      }
      final nameHeader = ByteData(2)
        ..setUint16(0, nameBytes.length, Endian.little);
      builder.add(nameHeader.buffer.asUint8List());
      builder.add(nameBytes);
      final sizeHeader = ByteData(4)..setUint32(0, data.length, Endian.little);
      builder.add(sizeHeader.buffer.asUint8List());
      builder.add(data);
    }
    return builder.takeBytes();
  }
}

bool _isSafeName(String name) {
  if (name.isEmpty) return false;
  if (name.startsWith('/') || name.endsWith('/')) return false;
  if (name.contains('\\') || name.contains('..')) return false;
  if (name.contains('//')) return false;
  return true;
}
