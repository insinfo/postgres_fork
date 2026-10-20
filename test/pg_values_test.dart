import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/src/binary_codec.dart';
import 'package:test/test.dart';

PgInet _inet(String address, int prefix, {bool cidr = false}) =>
    PgInet(InternetAddress(address), prefix, isCidr: cidr);

/// Monta um array binário de int4 (formato `array_send`).
Uint8List _int4Array(List<int> dims, List<int?> values) {
  final b = BytesBuilder();
  void i32(int v) => b.add((ByteData(4)..setInt32(0, v)).buffer.asUint8List());
  i32(dims.length);
  i32(values.contains(null) ? 1 : 0);
  i32(23);
  for (final d in dims) {
    i32(d);
    i32(1);
  }
  for (final v in values) {
    if (v == null) {
      i32(-1);
    } else {
      i32(4);
      i32(v);
    }
  }
  return b.toBytes();
}

void main() {
  group('PgInterval', () {
    test('toString no estilo "postgres"', () {
      expect(const PgInterval().toString(), '00:00:00');
      expect(const PgInterval(microseconds: 3 * 3600000000).toString(),
          '03:00:00');
      expect(
          const PgInterval(months: 14, days: 3, microseconds: 14706789000)
              .toString(),
          '1 year 2 mons 3 days 04:05:06.789');
      expect(
          const PgInterval(months: -14, days: 3, microseconds: -14706000000)
              .toString(),
          '-1 years -2 mons +3 days -04:05:06');
      expect(const PgInterval(days: 1, microseconds: -3600000000).toString(),
          '1 day -01:00:00');
      expect(const PgInterval(microseconds: -500000).toString(), '-00:00:00.5');
    });

    test('igualdade, comparação e Duration', () {
      expect(const PgInterval(days: 1), const PgInterval(days: 1));
      expect(
          const PgInterval(days: 1) ==
              const PgInterval(microseconds: 86400000000),
          isFalse);
      expect(
          const PgInterval(months: 1).compareTo(const PgInterval(days: 30)), 0);
      expect(const PgInterval(days: 2).toDuration(), const Duration(days: 2));
      expect(() => const PgInterval(months: 1).toDuration(), throwsStateError);
      expect(PgInterval.fromDuration(const Duration(minutes: 5)).microseconds,
          300000000);
    });
  });

  group('PgTime e PgTimeTz', () {
    test('campos e texto', () {
      final t = PgTime(13, 45, 10, 123456);
      expect([t.hour, t.minute, t.second, t.microsecond], [13, 45, 10, 123456]);
      expect(t.toString(), '13:45:10.123456');
      expect(PgTime(24).toString(), '24:00:00');
      expect(PgTime(0, 0, 0, 500000).toString(), '00:00:00.5');
      expect(PgTime(1).toDuration(), const Duration(hours: 1));
      expect(PgTimeTz(PgTime(12), 5 * 3600 + 30 * 60).toString(),
          '12:00:00+05:30');
      expect(PgTimeTz(PgTime(12), -(9 * 3600 + 30 * 60 + 15)).toString(),
          '12:00:00-09:30:15');
      expect(PgTimeTz(PgTime(0), 0).toString(), '00:00:00+00');
    });
  });

  group('PgInet', () {
    test('formato do PostgreSQL', () {
      expect(_inet('192.168.1.10', 24).toString(), '192.168.1.10/24');
      expect(_inet('192.168.1.10', 32).toString(), '192.168.1.10');
      expect(_inet('10.0.0.0', 8, cidr: true).toString(), '10.0.0.0/8');
      expect(_inet('10.1.2.3', 32, cidr: true).toString(), '10.1.2.3/32');
      expect(_inet('::1', 128).toString(), '::1');
      expect(_inet('::', 128).toString(), '::');
      expect(_inet('1::', 128).toString(), '1::');
      expect(_inet('2001:db8::', 32).toString(), '2001:db8::/32');
      expect(
          _inet('2001:db8:0:0:1:0:0:1', 128).toString(), '2001:db8::1:0:0:1');
      expect(_inet('::ffff:1.2.3.4', 128).toString(), '::ffff:1.2.3.4');
      expect(_inet('::1.2.3.4', 128).toString(), '::1.2.3.4');
      expect(_inet('::2', 128).toString(), '::2');
    });
  });

  group('decodificação binária', () {
    final settings = TimeZoneSettings('UTC');

    test('arrays: NULL, várias dimensões e vazio', () {
      final decoder = PostgresBinaryDecoder(1007, utf8, settings);
      final withNull = decoder.convert(_int4Array([3], [1, null, 3]));
      expect(withNull, [1, null, 3]);
      expect(withNull, isA<List<int?>>());
      final noNull = decoder.convert(_int4Array([2], [1, 2]));
      expect(noNull, isA<List<int>>());
      expect(decoder.convert(_int4Array([2, 2], [1, 2, 3, 4])), [
        [1, 2],
        [3, 4]
      ]);
      expect(decoder.convert(_int4Array([], [])), isEmpty);
    });

    Uint8List interval(int micros, int days, int months) => (ByteData(16)
          ..setInt64(0, micros)
          ..setInt32(8, days)
          ..setInt32(12, months))
        .buffer
        .asUint8List();

    test('interval: Duration por padrão e PgInterval opcional', () {
      final byDefault = PostgresBinaryDecoder(1186, utf8, settings);
      expect(byDefault.convert(interval(3600000000, 0, 0)),
          const Duration(hours: 1));
      expect(() => byDefault.convert(interval(0, 1, 0)),
          throwsA(isA<UnimplementedError>()));
      final asInterval = PostgresBinaryDecoder(1186, utf8, settings,
          decoding:
              const DecodingSettings(interval: IntervalDecoding.pgInterval));
      expect(asInterval.convert(interval(5, 2, 1)),
          const PgInterval(months: 1, days: 2, microseconds: 5));
    });

    test('time nos três modos', () {
      final bytes =
          (ByteData(8)..setInt64(0, 49510500000)).buffer.asUint8List();
      for (final entry in {
        ExtendedTypeDecoding.objects: PgTime(13, 45, 10, 500000),
        ExtendedTypeDecoding.text: '13:45:10.5',
        ExtendedTypeDecoding.bytes: bytes,
      }.entries) {
        expect(
            PostgresBinaryDecoder(1083, utf8, settings,
                    decoding: DecodingSettings(extendedTypes: entry.key))
                .convert(bytes),
            entry.value);
      }
    });
  });
}
