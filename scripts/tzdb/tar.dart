// Leitor mínimo de arquivos .tar e .tar.gz (formatos ustar/GNU), suficiente
// para os pacotes tzdata da IANA.

import 'dart:convert' show latin1;
import 'dart:io' show gzip;
import 'dart:typed_data';

/// Extrai os arquivos regulares de um .tar (ou .tar.gz, detectado pelo
/// cabeçalho gzip) e devolve um mapa do caminho para o conteúdo.
Map<String, Uint8List> readTarArchive(Uint8List bytes) {
  final data = bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B
      ? Uint8List.fromList(gzip.decode(bytes))
      : bytes;
  final files = <String, Uint8List>{};
  String? longName;
  var offset = 0;
  while (offset + 512 <= data.length) {
    final header = data.sublist(offset, offset + 512);
    if (header.every((b) => b == 0)) break;
    var name = _cString(header, 0, 100);
    final size = _octal(header, 124, 12);
    final type = header[156];
    final prefix = _cString(header, 345, 155);
    if (prefix.isNotEmpty) name = '$prefix/$name';
    final contentStart = offset + 512;
    final content = data.sublist(contentStart, contentStart + size);
    offset = contentStart + ((size + 511) ~/ 512) * 512;

    if (type == 0x4C /* L: nome longo GNU */) {
      longName = _cString(content, 0, content.length);
      continue;
    }
    if (type == 0x78 /* x */ || type == 0x67 /* g */) {
      // Cabeçalho pax: usa o "path", se houver.
      final text = latin1.decode(content);
      for (final record in text.split('\n')) {
        final eq = record.indexOf(' path=');
        if (eq >= 0) longName = record.substring(eq + 6);
      }
      continue;
    }
    if (longName != null) {
      name = longName;
      longName = null;
    }
    if (type == 0x30 /* '0' */ || type == 0 /* NUL: arquivo antigo */) {
      if (name.startsWith('./')) name = name.substring(2);
      files[name] = content;
    }
  }
  return files;
}

String _cString(Uint8List bytes, int start, int length) {
  var end = start;
  while (end < start + length && end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return latin1.decode(bytes.sublist(start, end));
}

int _octal(Uint8List bytes, int start, int length) {
  final s = _cString(bytes, start, length).trim();
  return s.isEmpty ? 0 : int.parse(s, radix: 8);
}
