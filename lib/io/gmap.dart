import 'dart:convert';
import 'dart:typed_data';

/// `.gmap`：单文件容器，原样装一组文件，不压缩。
///
/// 布局（小端）：
/// ```
/// 4  字节  魔数 "GMAP"
/// 2  字节  版本号
/// 2  字节  条目数
/// 每条目：
///   2 字节  名字长度
///   n 字节  名字（UTF-8）
///   4 字节  数据长度
///   m 字节  数据
/// ```
class GmapFile {
  GmapFile._();

  static const List<int> magic = [0x47, 0x4D, 0x41, 0x50]; // GMAP
  static const int version = 1;

  static Uint8List encode(Map<String, Uint8List> files) {
    if (files.length > 0xFFFF) {
      throw ArgumentError('条目太多');
    }

    final builder = BytesBuilder(copy: false);
    builder.add(magic);

    final header = ByteData(4);
    header.setUint16(0, version, Endian.little);
    header.setUint16(2, files.length, Endian.little);
    builder.add(header.buffer.asUint8List());

    for (final entry in files.entries) {
      final name = utf8.encode(entry.key);
      if (name.length > 0xFFFF) throw ArgumentError('文件名太长');

      final nameLen = ByteData(2)..setUint16(0, name.length, Endian.little);
      builder.add(nameLen.buffer.asUint8List());
      builder.add(name);

      final data = entry.value;
      final dataLen = ByteData(4)..setUint32(0, data.length, Endian.little);
      builder.add(dataLen.buffer.asUint8List());
      builder.add(data);
    }

    return builder.takeBytes();
  }

  static Map<String, Uint8List> decode(Uint8List bytes) {
    if (bytes.length < 8) throw const FormatException('文件太小');
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) throw const FormatException('不是 .gmap 文件');
    }

    final data = ByteData.sublistView(bytes);
    final ver = data.getUint16(4, Endian.little);
    if (ver != version) throw FormatException('不支持的版本：$ver');

    final count = data.getUint16(6, Endian.little);
    final out = <String, Uint8List>{};
    var pos = 8;

    for (var i = 0; i < count; i++) {
      if (pos + 2 > bytes.length) throw const FormatException('数据被截断');
      final nameLen = data.getUint16(pos, Endian.little);
      pos += 2;

      if (pos + nameLen > bytes.length) throw const FormatException('数据被截断');
      final name = utf8.decode(bytes.sublist(pos, pos + nameLen));
      pos += nameLen;

      if (pos + 4 > bytes.length) throw const FormatException('数据被截断');
      final size = data.getUint32(pos, Endian.little);
      pos += 4;

      if (pos + size > bytes.length) throw const FormatException('数据被截断');
      out[name] = Uint8List.fromList(bytes.sublist(pos, pos + size));
      pos += size;
    }

    return out;
  }
}
