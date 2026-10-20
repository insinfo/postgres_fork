import 'dart:convert';

import 'package:postgres_fork/src/utils/crypto.dart';
import 'package:test/test.dart';

List<int> _repeat(int byte, int count) => List.filled(count, byte);

void main() {
  group('md5 (RFC 1321)', () {
    final vectors = {
      '': 'd41d8cd98f00b204e9800998ecf8427e',
      'abc': '900150983cd24fb0d6963f7d28e17f72',
      'message digest': 'f96b697d7cb7938d525a2f31aaf161d0',
      '1234567890' * 8: '57edf4a22be3c955ac49da2e2107b67a',
    };
    vectors.forEach((input, digest) {
      test('"${input.length > 20 ? '${input.substring(0, 20)}...' : input}"',
          () {
        expect(md5Hex(utf8.encode(input)), digest);
        expect(hexEncode(md5Bytes(utf8.encode(input))), digest);
      });
    });

    test('trunca cada valor para 8 bits (como o pacote crypto)', () {
      // 'ö' tem code unit 0xF6; a autenticação MD5 passa codeUnits.
      expect(md5Hex('ö'.codeUnits), '44f2c50b838f92970d2c11e2fa98bc7d');
      expect(md5Hex([0x100 + 0x61, 0x62, -0x100 + 0x63]), md5Hex([0x61, 0x62, 0x63]));
    });

    test('hash de senha usado pela autenticação MD5 do PostgreSQL', () {
      final inner = md5Hex('dartdart'.codeUnits);
      final salt = String.fromCharCodes([1, 2, 3, 250]);
      expect('md5${md5Hex('$inner$salt'.codeUnits)}',
          'md5f93fbf36e14137769e1902896a231f18');
    });
  });

  group('sha256 (FIPS 180-4)', () {
    test('mensagem vazia', () {
      expect(hexEncode(sha256Bytes([])),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });
    test('"abc"', () {
      expect(hexEncode(sha256Bytes(utf8.encode('abc'))),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
    test('448 bits', () {
      expect(
          hexEncode(sha256Bytes(utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    });
    test('um milhão de "a"', () {
      expect(hexEncode(sha256Bytes(_repeat(0x61, 1000000))),
          'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    });
  });

  group('hmac-sha256 (RFC 4231)', () {
    test('caso 1', () {
      expect(hexEncode(hmacSha256(_repeat(0x0b, 20), utf8.encode('Hi There'))),
          'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');
    });
    test('caso 2', () {
      expect(
          hexEncode(hmacSha256(utf8.encode('Jefe'),
              utf8.encode('what do ya want for nothing?'))),
          '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
    });
    test('caso 3', () {
      expect(hexEncode(hmacSha256(_repeat(0xaa, 20), _repeat(0xdd, 50))),
          '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe');
    });
    test('caso 6 (chave maior que o bloco)', () {
      expect(
          hexEncode(hmacSha256(
              _repeat(0xaa, 131),
              utf8.encode(
                  'Test Using Larger Than Block-Size Key - Hash Key First'))),
          '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54');
    });
  });
}
