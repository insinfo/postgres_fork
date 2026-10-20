import 'package:postgres_fork/src/utils/nfkc.dart';
import 'package:postgres_fork/src/utils/saslprep.dart';
import 'package:test/test.dart';

String _s(List<int> codePoints) => String.fromCharCodes(codePoints);

Matcher _throwsSaslprep(String messageStart) => throwsA(isA<Exception>()
    .having((e) => e.toString(), 'toString', startsWith(messageStart)));

void main() {
  group('saslprep (exemplos do RFC 4013, seção 3)', () {
    test('mapeia SOFT HYPHEN para nada', () {
      expect(saslprep(_s([0x49, 0x00AD, 0x58])), 'IX');
    });
    test('sem transformação', () {
      expect(saslprep('user'), 'user');
      expect(saslprep('USER'), 'USER');
    });
    test('NFKC', () {
      expect(saslprep(_s([0x00AA])), 'a');
      expect(saslprep(_s([0x2168])), 'IX');
    });
    test('caractere proibido', () {
      expect(() => saslprep(_s([0x0007])),
          _throwsSaslprep('Exception: Prohibited character'));
    });
    test('regra bidirecional', () {
      expect(() => saslprep(_s([0x0627, 0x0031])),
          _throwsSaslprep('Exception: Bidirectional RandALCat'));
    });
  });

  group('saslprep (outros casos)', () {
    test('string vazia', () {
      expect(saslprep(''), '');
    });
    test('espaços não-ASCII viram espaço comum', () {
      expect(saslprep(_s([0x61, 0x00A0, 0x62, 0x2003, 0x63])), 'a b c');
    });
    test('senhas não-ASCII comuns ficam inalteradas', () {
      expect(saslprep('pöstgrēs_üšęr_pæsswœêrd'), 'pöstgrēs_üšęr_pæsswœêrd');
    });
    test('ligaduras e sobrescritos são normalizados', () {
      expect(saslprep('ﬁle-senha²'), 'file-senha2');
    });
    test('code point não atribuído no Unicode 3.2', () {
      expect(() => saslprep(_s([0x0221])),
          _throwsSaslprep('Exception: Unassigned code point'));
    });
    test('RandALCat e LCat juntos', () {
      expect(() => saslprep(_s([0x0627, 0x61, 0x0628])),
          _throwsSaslprep('Exception: String must not contain RandALCat'));
    });
    test('RandALCat no início e no fim é aceito', () {
      expect(saslprep(_s([0x0627, 0x0031, 0x0628])), _s([0x0627, 0x0031, 0x0628]));
    });
    test('resultado vazio lança RangeError (como o pacote original)', () {
      expect(() => saslprep(_s([0x00AD])), throwsRangeError);
    });
  });

  group('nfkc', () {
    test('composição canônica', () {
      expect(nfkc(_s([0x65, 0x0301])), _s([0x00E9]));
      expect(nfkc(_s([0x212B])), _s([0x00C5]));
      expect(nfkc(_s([0x2126])), _s([0x03A9]));
    });
    test('decomposição de compatibilidade', () {
      expect(nfkc(_s([0xFB01])), 'fi');
      expect(nfkc(_s([0xFF50, 0xFF41, 0xFF53, 0xFF53])), 'pass');
      expect(nfkc(_s([0x1D400])), 'A');
    });
    test('reordenação canônica', () {
      // e + acento agudo (230) + ponto abaixo (220) -> ponto antes do acento,
      // e então a composição com o acento agudo.
      expect(nfkc(_s([0x65, 0x0301, 0x0323])), _s([0x1EB9, 0x0301]));
    });
    test('Hangul', () {
      expect(nfkc(_s([0x1100, 0x1161, 0x11A8])), _s([0xAC01]));
      expect(nfkc(_s([0xAC01])), _s([0xAC01]));
    });
    test('surrogates isolados são preservados', () {
      expect(nfkc(_s([0x61, 0xD800, 0x62])), _s([0x61, 0xD800, 0x62]));
    });
  });
}
