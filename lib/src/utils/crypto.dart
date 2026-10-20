// Implementação interna de MD5 (RFC 1321), SHA-256 (FIPS 180-4) e
// HMAC (RFC 2104) que substitui o pacote `crypto` nos pontos usados pelo
// driver (autenticação MD5 e SCRAM-SHA-256).
//
// Assim como no pacote `crypto`, cada elemento da entrada é truncado para os
// 8 bits menos significativos (`value & 0xFF`) antes de ser processado. Isso é
// relevante porque a autenticação MD5 passa `String.codeUnits` (que podem ser
// maiores que 255) diretamente para o hash.

import 'dart:typed_data';

const _mask32 = 0xFFFFFFFF;

int _rotl32(int x, int n) => ((x << n) | (x >> (32 - n))) & _mask32;

int _rotr32(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask32;

/// Monta a mensagem com o padding de Merkle–Damgård (0x80, zeros e o tamanho
/// em bits com 64 bits), usado tanto pelo MD5 quanto pelo SHA-256.
Uint8List _pad(List<int> data, Endian lengthEndian) {
  final length = data.length;
  var paddedLength = length + 1 + 8;
  paddedLength = (paddedLength + 63) & ~63;
  final out = Uint8List(paddedLength);
  // Uint8List.setRange trunca cada valor para 8 bits, assim como o `crypto`.
  out.setRange(0, length, data);
  out[length] = 0x80;
  final bitLength = length * 8;
  final view = ByteData.sublistView(out);
  if (lengthEndian == Endian.little) {
    view.setUint32(paddedLength - 8, bitLength & _mask32, Endian.little);
    view.setUint32(
        paddedLength - 4, (bitLength ~/ 0x100000000) & _mask32, Endian.little);
  } else {
    view.setUint32(
        paddedLength - 8, (bitLength ~/ 0x100000000) & _mask32, Endian.big);
    view.setUint32(paddedLength - 4, bitLength & _mask32, Endian.big);
  }
  return out;
}

const _md5Shifts = <int>[
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, //
];

const _md5K = <int>[
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, //
  0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, //
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, //
  0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8, //
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, //
  0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, //
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa, //
  0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, //
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, //
  0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, //
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391, //
];

/// Calcula o MD5 de [data] e retorna os 16 bytes do digest.
Uint8List md5Bytes(List<int> data) {
  final message = _pad(data, Endian.little);
  final view = ByteData.sublistView(message);
  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;
  final m = Uint32List(16);

  for (var chunk = 0; chunk < message.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      m[i] = view.getUint32(chunk + i * 4, Endian.little);
    }
    var a = a0;
    var b = b0;
    var c = c0;
    var d = d0;
    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d & _mask32));
        g = (7 * i) % 16;
      }
      f = (f + a + _md5K[i] + m[g]) & _mask32;
      a = d;
      d = c;
      c = b;
      b = (b + _rotl32(f, _md5Shifts[i])) & _mask32;
    }
    a0 = (a0 + a) & _mask32;
    b0 = (b0 + b) & _mask32;
    c0 = (c0 + c) & _mask32;
    d0 = (d0 + d) & _mask32;
  }

  final out = ByteData(16);
  out.setUint32(0, a0, Endian.little);
  out.setUint32(4, b0, Endian.little);
  out.setUint32(8, c0, Endian.little);
  out.setUint32(12, d0, Endian.little);
  return out.buffer.asUint8List();
}

/// Calcula o MD5 de [data] e retorna o digest em hexadecimal minúsculo, como
/// `md5.convert(data).toString()` do pacote `crypto`.
String md5Hex(List<int> data) => hexEncode(md5Bytes(data));

const _sha256K = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, //
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, //
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, //
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, //
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, //
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, //
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, //
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, //
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, //
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2, //
];

/// Tamanho do bloco do SHA-256 em bytes (usado pelo HMAC).
const sha256BlockSize = 64;

/// Calcula o SHA-256 de [data] e retorna os 32 bytes do digest.
Uint8List sha256Bytes(List<int> data) {
  final message = _pad(data, Endian.big);
  final view = ByteData.sublistView(message);
  final h = Uint32List.fromList(const [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19, //
  ]);
  final w = Uint32List(64);

  for (var chunk = 0; chunk < message.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(chunk + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr32(x, 7) ^ _rotr32(x, 18) ^ (x >> 3);
      final s1 = _rotr32(y, 17) ^ _rotr32(y, 19) ^ (y >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask32;
    }

    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    var f = h[5];
    var g = h[6];
    var hh = h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ (~e & _mask32 & g);
      final t1 = (hh + s1 + ch + _sha256K[i] + w[i]) & _mask32;
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask32;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask32;
    }

    h[0] = (h[0] + a) & _mask32;
    h[1] = (h[1] + b) & _mask32;
    h[2] = (h[2] + c) & _mask32;
    h[3] = (h[3] + d) & _mask32;
    h[4] = (h[4] + e) & _mask32;
    h[5] = (h[5] + f) & _mask32;
    h[6] = (h[6] + g) & _mask32;
    h[7] = (h[7] + hh) & _mask32;
  }

  final out = ByteData(32);
  for (var i = 0; i < 8; i++) {
    out.setUint32(i * 4, h[i], Endian.big);
  }
  return out.buffer.asUint8List();
}

/// Calcula o HMAC-SHA256 (RFC 2104) de [data] usando a chave [key].
Uint8List hmacSha256(List<int> key, List<int> data) {
  var keyBytes = Uint8List.fromList(key);
  if (keyBytes.length > sha256BlockSize) {
    keyBytes = sha256Bytes(keyBytes);
  }
  final paddedKey = Uint8List(sha256BlockSize)
    ..setRange(0, keyBytes.length, keyBytes);

  final inner = Uint8List(sha256BlockSize + data.length);
  for (var i = 0; i < sha256BlockSize; i++) {
    inner[i] = paddedKey[i] ^ 0x36;
  }
  inner.setRange(sha256BlockSize, inner.length, data);
  final innerHash = sha256Bytes(inner);

  final outer = Uint8List(sha256BlockSize + innerHash.length);
  for (var i = 0; i < sha256BlockSize; i++) {
    outer[i] = paddedKey[i] ^ 0x5c;
  }
  outer.setRange(sha256BlockSize, outer.length, innerHash);
  return sha256Bytes(outer);
}

/// Codifica [bytes] em hexadecimal minúsculo.
String hexEncode(List<int> bytes) {
  const hexDigits = '0123456789abcdef';
  final charCodes = Uint8List(bytes.length * 2);
  for (var i = 0, j = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    charCodes[j++] = hexDigits.codeUnitAt((byte >> 4) & 0xF);
    charCodes[j++] = hexDigits.codeUnitAt(byte & 0xF);
  }
  return String.fromCharCodes(charCodes);
}
