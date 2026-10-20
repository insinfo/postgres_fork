// PgDecimal e a decodificação de numeric.

import 'dart:math';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:postgres_fork/src/binary_codec.dart';
import 'package:test/test.dart';

import 'docker.dart';

PgDecimal d(String s) => PgDecimal.parse(s);

/// Números aleatórios variados (inteiros grandes, frações longas, zeros à
/// direita, valores minúsculos e especiais).
List<String> randomNumerics(Random random, int count) {
  String digits(int n) {
    final b = StringBuffer();
    for (var i = 0; i < n; i++) {
      b.write(random.nextInt(10));
    }
    return b.toString();
  }

  final values = <String>[];
  for (var i = 0; i < count; i++) {
    final kind = random.nextInt(20);
    if (kind == 0) {
      values.add(['NaN', 'Infinity', '-Infinity', '0', '0.000', '-0.00']
          [random.nextInt(6)]);
      continue;
    }
    final sign = random.nextBool() ? '-' : '';
    final intDigits = [0, 1, 2, 4, 5, 8, 12, 20, 30][random.nextInt(9)];
    final fracDigits = [0, 0, 1, 2, 3, 4, 5, 8, 12, 20][random.nextInt(10)];
    var intPart = intDigits == 0 ? '0' : digits(intDigits);
    if (random.nextInt(4) == 0 && intDigits > 0) {
      intPart = '${random.nextInt(9) + 1}${'0' * intDigits}';
    }
    var frac = digits(fracDigits);
    if (random.nextInt(5) == 0 && fracDigits > 2) {
      frac = '${'0' * (fracDigits - 1)}${random.nextInt(9) + 1}';
    }
    if (random.nextInt(6) == 0 && fracDigits > 0) {
      frac = '${frac.substring(0, frac.length - 1)}0';
    }
    values.add(fracDigits == 0 ? '$sign$intPart' : '$sign$intPart.$frac');
  }
  return values;
}

void main() {
  group('PgDecimal (sem banco)', () {
    test('parse e toString no formato do PostgreSQL', () {
      final cases = {
        '0': '0',
        '-0': '0',
        '-0.00': '0.00',
        '1.50': '1.50',
        '+.5': '0.5',
        '5.': '5',
        '007.10': '7.10',
        '1.5e3': '1500',
        '1.5E-3': '0.0015',
        '12.345e1': '123.45',
        '-1e-10': '-0.0000000001',
        '  42  ': '42',
        'nan': 'NaN',
        'Infinity': 'Infinity',
        '-inf': '-Infinity',
        '123456789012345678901234567890.0987654321':
            '123456789012345678901234567890.0987654321',
      };
      cases.forEach((input, output) {
        expect(d(input).toString(), output, reason: input);
      });
      for (final bad in ['', '.', '-', '1e', '1.2.3', '1 000', 'abc', '0x10']) {
        expect(PgDecimal.tryParse(bad), isNull, reason: bad);
        expect(() => PgDecimal.parse(bad), throwsFormatException);
      }
    });

    test('construtores e conversões', () {
      expect(PgDecimal.fromInt(-42).toString(), '-42');
      expect(PgDecimal.fromBigInt(BigInt.from(12345), scale: 3).toString(),
          '12.345');
      expect(PgDecimal.fromDouble(0.1).toString(), '0.1');
      expect(PgDecimal.fromDouble(1e21).toString(), '1000000000000000000000');
      expect(PgDecimal.fromDouble(double.nan).isNaN, isTrue);
      expect(d('-12.99').toInt(), -12);
      expect(d('12.5').toDouble(), 12.5);
      expect(d('NaN').toDouble().isNaN, isTrue);
      expect(d('99999999999999999999').toBigInt(),
          BigInt.parse('99999999999999999999'));
      expect(() => d('99999999999999999999').toInt(), throwsUnsupportedError);
      expect(PgDecimal.infinity.toInt, throwsUnsupportedError);
      expect(d('-1.50').scale, 2);
      expect(d('-1.50').unscaledValue, BigInt.from(-150));
      expect(d('0.00120').precision, 3);
    });

    test('igualdade, hashCode e ordenação', () {
      expect(d('1.5'), d('1.500'));
      expect(d('1.5').hashCode, d('1.500').hashCode);
      expect(d('0').hashCode, d('-0.000').hashCode);
      expect(d('NaN'), d('NaN'));
      expect(d('2') > d('1.99999'), isTrue);
      final sorted = [d('NaN'), d('1'), d('Infinity'), d('-Infinity'), d('-5')]
        ..sort();
      expect(sorted.map((e) => '$e'),
          ['-Infinity', '-5', '1', 'Infinity', 'NaN']);
      expect({d('1.0'), d('1'), d('1.00')}.length, 1);
    });

    test('aritmética e escala', () {
      expect('${d('1.5') + d('2.25')}', '3.75');
      expect('${d('1.50') - d('0.5')}', '1.00');
      expect('${d('1.5') * d('2.25')}', '3.375');
      expect('${d('1') / d('3')}', '0.33333333333333333333');
      expect('${d('4') / d('3')}', '1.3333333333333333');
      expect('${d('10') ~/ d('3')}', '3');
      expect('${d('-10') ~/ d('3')}', '-3');
      expect('${d('-10.5') % d('3')}', '-1.5');
      expect('${d('2').divide(d('3'), scale: 2)}', '0.67');
      expect(
          '${d('2').divide(d('3'), scale: 2, mode: PgRoundingMode.towardZero)}',
          '0.66');
      expect('${d('249.6').divide(d('1'), scale: -2)}', '200');
      expect('${d('250').divide(d('1'), scale: -2)}', '300');
      expect(() => d('1') / d('0'), throwsUnsupportedError);
      expect(() => d('1') % d('0.00'), throwsUnsupportedError);
      expect(() => d('Infinity') / d('0'), throwsUnsupportedError);
      expect('${d('Infinity') - d('Infinity')}', 'NaN');
      expect('${d('0') * d('-Infinity')}', 'NaN');
      expect('${d('-2') * d('Infinity')}', '-Infinity');
      expect('${d('5') / d('Infinity')}', '0');
      expect('${-d('0.0')}', '0.0');
      expect('${d('-3.2').abs()}', '3.2');
    });

    test('arredondamento', () {
      expect('${d('2.5').round()}', '3');
      expect('${d('-2.5').round()}', '-3');
      expect('${d('2.5').round(0, PgRoundingMode.halfEven)}', '2');
      expect('${d('3.5').round(0, PgRoundingMode.halfEven)}', '4');
      expect('${d('1.5').round(3)}', '1.500');
      expect('${d('1234.5').round(-2)}', '1200');
      expect('${d('1250').round(-2)}', '1300');
      expect('${d('-1.29').truncate(1)}', '-1.2');
      expect('${d('-1.2').floor()}', '-2');
      expect('${d('-1.2').ceil()}', '-1');
      expect('${d('1.21').ceil()}', '2');
      expect('${d('1.2').rescale(1, PgRoundingMode.awayFromZero)}', '1.2');
      expect('${d('1.21').rescale(1, PgRoundingMode.awayFromZero)}', '1.3');
      expect('${d('NaN').round(2)}', 'NaN');
    });

    test('codificação binária ida e volta', () {
      final random = Random(3);
      for (final s in [
        ...randomNumerics(random, 3000),
        '0.0001',
        '10000',
        '100000000',
        '0.00000001',
        '9999.9999',
      ]) {
        final value = d(s);
        final back = decodePgDecimal(encodePgDecimal(value));
        expect(back.toString(), value.toString(), reason: s);
      }
    });
  });

  group('PgDecimal contra o servidor', () {
    usePostgresDocker();

    late PostgreSQLConnection conn;
    setUpAll(() async {
      conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
          username: 'dart',
          password: 'dart',
          decodingSettings:
              const DecodingSettings(numeric: NumericDecoding.decimal));
      await conn.open();
    });
    tearDownAll(() => conn.close());

    test('operações iguais às do PostgreSQL (valores aleatórios)', () async {
      final random = Random(42);
      var checked = 0;
      for (var round = 0; round < 6; round++) {
        final a = randomNumerics(random, 400);
        final b = randomNumerics(random, 400);
        final ks = List.generate(400, (_) => random.nextInt(12) - 3);
        final values = [
          for (var i = 0; i < a.length; i++)
            "('${a[i]}'::numeric, '${b[i]}'::numeric, ${ks[i]})"
        ].join(', ');
        final rows = await conn.query('''
          SELECT a::text, b::text, (a + b)::text, (a - b)::text, (a * b)::text,
            CASE WHEN b = 0 THEN NULL ELSE (a / b)::text END,
            CASE WHEN b = 0 THEN NULL ELSE (a % b)::text END,
            CASE WHEN b = 0 THEN NULL ELSE div(a, b)::text END,
            round(a, k)::text, trunc(a, k)::text, floor(a)::text,
            ceil(a)::text, abs(a)::text, (-a)::text,
            a < b, a = b, a > b, a, b
          FROM (VALUES $values) t(a, b, k)''', allowReuse: false);
        expect(rows.length, a.length);
        for (var i = 0; i < rows.length; i++) {
          final r = rows[i];
          final x = d(a[i]);
          final y = d(b[i]);
          final k = ks[i];
          final reason = 'a=${a[i]} b=${b[i]} k=$k';
          expect(x.toString(), r[0], reason: reason);
          expect(y.toString(), r[1], reason: reason);
          expect('${x + y}', r[2], reason: '+ $reason');
          expect('${x - y}', r[3], reason: '- $reason');
          expect('${x * y}', r[4], reason: '* $reason');
          if (r[5] != null) {
            expect('${x / y}', r[5], reason: '/ $reason');
            expect('${x % y}', r[6], reason: '% $reason');
            expect('${x ~/ y}', r[7], reason: 'div $reason');
          }
          expect('${x.round(k)}', r[8], reason: 'round $reason');
          expect('${x.truncate(k)}', r[9], reason: 'trunc $reason');
          expect('${x.floor()}', r[10], reason: 'floor $reason');
          expect('${x.ceil()}', r[11], reason: 'ceil $reason');
          expect('${x.abs()}', r[12], reason: 'abs $reason');
          expect('${-x}', r[13], reason: 'neg $reason');
          expect(x < y, r[14], reason: '< $reason');
          expect(x == y, r[15], reason: '= $reason');
          expect(x > y, r[16], reason: '> $reason');
          // Decodificação binária (modo decimal).
          expect(r[17], isA<PgDecimal>());
          expect('${r[17]}', a[i] == '-0.00' ? '0.00' : x.toString(),
              reason: 'decode $reason');
          expect('${r[18]}', y.toString(), reason: 'decode $reason');
          checked++;
        }
      }
      expect(checked, 2400);
    });

    test('valores extremos', () async {
      for (final s in [
        '1${'0' * 1000}',
        '0.${'0' * 900}1',
        '-${'9' * 500}.${'9' * 500}',
        '0.${'0' * 16382}1',
      ]) {
        final row = (await conn.query(
                'SELECT CAST(@v AS numeric), CAST(CAST(@v AS numeric) AS text)',
                substitutionValues: {'v': s}, allowReuse: false))
            .first;
        expect('${row[0]}', row[1]);
        expect(row[0], d(s));
      }
    });

    test('parâmetros PgDecimal (tipado, não tipado e array)', () async {
      final values = [
        d('1.50'),
        d('-123456789012345678901234567890.123456789'),
        d('0.000'),
        PgDecimal.nan,
        PgDecimal.infinity,
        PgDecimal.negativeInfinity,
      ];
      await conn.execute('CREATE TEMP TABLE dec_param (v numeric)');
      for (final v in values) {
        final typed = await conn.query(
            'INSERT INTO dec_param VALUES (@v:numeric) RETURNING v',
            substitutionValues: {'v': v});
        expect(typed.first.first.toString(), v.toString());
        final untyped = await conn.query('SELECT (@v)::text, pg_typeof(@v)::text',
            substitutionValues: {'v': v}, useSimpleQueryProtocol: true);
        expect(untyped.first, [v.toString(), 'numeric']);
        final q = await conn.query('SELECT ?::numeric::text',
            substitutionValues: [v],
            placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark);
        expect(q.first.first, v.toString());
      }
      final array = await conn.query(
          "SELECT ARRAY[1.5, NULL, 'NaN', 2.250]::numeric[], "
          "ARRAY[[1, 2], [3, 4]]::numeric[], '{}'::numeric[]");
      expect(array.first[0], [d('1.5'), null, PgDecimal.nan, d('2.250')]);
      expect(array.first[0][3].toString(), '2.250');
      expect(array.first[1], [
        [d('1'), d('2')],
        [d('3'), d('4')]
      ]);
      expect(array.first[2], isEmpty);
    });

    test('COPY com PgDecimal', () async {
      await conn.execute('CREATE TEMP TABLE dec_copy (v numeric)');
      await conn.copyRows('dec_copy', [
        'v'
      ], [
        [d('1.250')],
        [PgDecimal.nan],
        [null]
      ]);
      final rows = await conn.query('SELECT v::text FROM dec_copy');
      expect(rows.map((r) => r.first), ['1.250', 'NaN', null]);
    });

    test('modo string (padrão): Infinity não vira mais 0', () async {
      final c = PostgreSQLConnection('localhost', 5432, 'dart_test',
          username: 'dart', password: 'dart');
      await c.open();
      addTearDown(c.close);
      final row = (await c.query("SELECT 'Infinity'::numeric, "
              "'-Infinity'::numeric, 'NaN'::numeric, 1.50::numeric, "
              'ARRAY[1.5, NULL]::numeric[]'))
          .first;
      expect(row, [
        'Infinity',
        '-Infinity',
        'NaN',
        '1.50',
        ['1.5', null]
      ]);
      // Strings 'Infinity' como parâmetro tipado.
      await c.execute('CREATE TEMP TABLE dec_str (v numeric)');
      expect(
          (await c.query('INSERT INTO dec_str VALUES (@v:numeric) RETURNING v',
                  substitutionValues: {'v': '-Infinity'}))
              .first
              .first,
          '-Infinity');
    });

    test('API v3 com NumericDecoding.decimal', () async {
      final v3 = await PgConnection.open(
          PgEndpoint(
              host: 'localhost',
              database: 'dart_test',
              username: 'dart',
              password: 'dart'),
          sessionSettings: PgSessionSettings(
              onBadSslCertificate: (_) => true,
              decodingSettings:
                  const DecodingSettings(numeric: NumericDecoding.decimal)));
      addTearDown(v3.close);
      final result = await v3.execute(
          PgSql(r'SELECT $1::numeric * 2, ARRAY[0.10, NULL]::numeric[]',
              types: [PgDataType.numeric]),
          parameters: [d('1.25')]);
      expect(result.first[0], d('2.50'));
      expect('${result.first[0]}', '2.50');
      expect(result.first[1], [d('0.10'), null]);
    });
  });

  test('decodificação de bytes vindos de um buffer maior (views)', () {
    final encoded = encodePgDecimal(d('-1234567.8901'));
    final big = Uint8List(encoded.length + 10)..setAll(5, encoded);
    final view = Uint8List.view(big.buffer, 5, encoded.length);
    expect(decodePgDecimal(view).toString(), '-1234567.8901');
  });
}
