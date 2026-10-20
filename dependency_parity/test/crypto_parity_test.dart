// Compara lib/src/utils/crypto.dart com o pacote `crypto` 3.0.6.
//
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as orig;
import 'package:postgres_fork/src/utils/crypto.dart' as mine;
import 'package:test/test.dart';

/// Gera entradas com tamanhos ao redor das fronteiras de bloco (55/56/64...)
/// e valores fora do intervalo 0..255 (como `String.codeUnits`).
Iterable<List<int>> _inputs(Random random) sync* {
  for (var length = 0; length <= 300; length++) {
    yield List.generate(length, (_) => random.nextInt(256));
  }
  for (var i = 0; i < 300; i++) {
    yield List.generate(random.nextInt(2000), (_) => random.nextInt(256));
  }
  for (var i = 0; i < 300; i++) {
    // Valores > 255 e negativos: ambos devem truncar para 8 bits.
    yield List.generate(
        random.nextInt(200), (_) => random.nextInt(0x20000) - 0x100);
  }
  yield utf8.encode('The quick brown fox jumps over the lazy dog');
  yield 'pöstgrēs_üšęr_pæsswœêrdabc@def'.codeUnits;
  yield List.filled(1000000, 0x61);
}

void main() {
  test('md5', () {
    for (final input in _inputs(Random(10))) {
      expect(mine.md5Hex(input), orig.md5.convert(input).toString());
      expect(mine.md5Bytes(input), orig.md5.convert(input).bytes);
    }
  });

  test('sha256', () {
    for (final input in _inputs(Random(11))) {
      expect(mine.sha256Bytes(input), orig.sha256.convert(input).bytes);
    }
  });

  test('hmac-sha256', () {
    final random = Random(12);
    final inputs = _inputs(Random(13)).take(900).toList();
    for (final input in inputs) {
      // Chaves de 0 a 200 bytes (maiores que o bloco de 64 são "hasheadas").
      final key = List.generate(
          random.nextInt(201), (_) => random.nextInt(0x400) - 0x10);
      expect(mine.hmacSha256(key, input),
          orig.Hmac(orig.sha256, key).convert(input).bytes);
    }
  });

  test('hexEncode', () {
    final random = Random(14);
    for (var i = 0; i < 200; i++) {
      final bytes = List.generate(random.nextInt(64), (_) => random.nextInt(256));
      expect(mine.hexEncode(bytes), orig.Digest(bytes).toString());
    }
  });
}
