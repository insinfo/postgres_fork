// Benchmark do driver (API v2) contra um PostgreSQL local.
// Uso: dart run benchmark/driver_benchmark.dart [cenário ...|all]
// Imprime "cenário<TAB>ms". Veja benchmark/README.md.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
// ignore_for_file: implementation_imports
import 'package:postgres_fork/src/binary_codec.dart';
import 'package:postgres_fork/src/client_messages.dart';
import 'package:postgres_fork/src/message_window.dart';
import 'package:postgres_fork/src/query.dart';

PostgreSQLConnection conn({Object timeZone = 'UTC', String user = 'dart',
        String password = 'dart'}) =>
    PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: user, password: password, timeZone: timeZone);

Future<int> time(Future<void> Function() body) async {
  final sw = Stopwatch()..start();
  await body();
  return sw.elapsedMicroseconds;
}

const bigSelect = '''
SELECT g::int4 AS i, (g * 1000)::int8 AS b, 'texto ' || g AS t,
  (g / 7.0)::numeric(18,4) AS n,
  timestamptz '2024-01-01 00:00:00+00' + g * interval '1 minute' AS tz,
  timestamp '2020-01-01' + g * interval '1 second' AS ts,
  date '2020-01-01' + (g % 1000) AS d, (g % 2 = 0) AS bo, g::float8 / 3 AS f,
  md5(g::text)::uuid AS u, jsonb_build_object('id', g, 'nome', 'x' || g) AS j
FROM generate_series(1, 100000) g''';

final Map<String, Future<int> Function()> scenarios = {
  'connect_md5_x30': () async {
    return time(() async {
      for (var i = 0; i < 30; i++) {
        final c = conn();
        await c.open();
        await c.close();
      }
    });
  },
  'connect_scram_x30': () async {
    return time(() async {
      for (var i = 0; i < 30; i++) {
        final c = conn(user: 'dart_bench_scram', password: 'S3nh@-bench');
        await c.open();
        await c.close();
      }
    });
  },
  'select_100k_rows_11_cols': () async {
    final c = conn();
    await c.open();
    try {
      await c.query('SELECT 1');
      return await time(() async {
        final rows = await c.query(bigSelect);
        if (rows.length != 100000) throw StateError('rows');
      });
    } finally {
      await c.close();
    }
  },
  'select_50k_arrays': () async {
    final c = conn();
    await c.open();
    try {
      return await time(() async {
        final rows = await c.query(
            "SELECT ARRAY[g, g + 1, g + 2]::int4[], ARRAY['a' || g, 'b']::text[], "
            'ARRAY[g::int8, 1]::int8[] FROM generate_series(1, 50000) g');
        if (rows.length != 50000) throw StateError('rows');
      });
    } finally {
      await c.close();
    }
  },
  'small_queries_x3000': () async {
    final c = conn();
    await c.open();
    try {
      return await time(() async {
        for (var i = 0; i < 3000; i++) {
          await c.query('SELECT CAST(@id:int4 AS int4), CAST(@t:text AS text)',
              substitutionValues: {'id': i, 't': 'abc'});
        }
      });
    } finally {
      await c.close();
    }
  },
  'inserts_x3000': () async {
    final c = conn();
    await c.open();
    try {
      await c.execute('CREATE TEMP TABLE bench_ins (i int4, t text, '
          'ts timestamptz, n numeric, j jsonb)');
      final ts = DateTime.utc(2024, 1, 1);
      return await time(() async {
        for (var i = 0; i < 3000; i++) {
          await c.query(
              'INSERT INTO bench_ins VALUES (@i:int4, @t:text, @ts:timestamptz, '
              '@n:numeric, @j:jsonb)',
              substitutionValues: {
                'i': i,
                't': 'texto $i',
                'ts': ts,
                'n': 1.5,
                'j': {'id': i, 'nome': 'x'}
              });
        }
      });
    } finally {
      await c.close();
    }
  },
  'transactions_x500': () async {
    final c = conn();
    await c.open();
    try {
      await c.execute('CREATE TEMP TABLE bench_tx (i int4)');
      return await time(() async {
        for (var i = 0; i < 500; i++) {
          await c.transaction((ctx) async {
            await ctx.query('INSERT INTO bench_tx VALUES (@i:int4)',
                substitutionValues: {'i': i});
            await ctx.query('SELECT count(*) FROM bench_tx');
          });
        }
      });
    } finally {
      await c.close();
    }
  },
  'mapped_results_50k': () async {
    final c = conn();
    await c.open();
    try {
      await c.execute('CREATE TEMP TABLE bench_map AS $bigSelect LIMIT 50000');
      await c.mappedResultsQuery('SELECT * FROM bench_map LIMIT 1');
      return await time(() async {
        final rows = await c.mappedResultsQuery('SELECT * FROM bench_map');
        if (rows.length != 50000) throw StateError('rows');
      });
    } finally {
      await c.close();
    }
  },
  'timestamptz_sao_paulo_50k': () async {
    final c = conn(
        timeZone: TimeZoneSettings('America/Sao_Paulo',
            forceDecodeTimestamptzAsUTC: false));
    await c.open();
    try {
      return await time(() async {
        final rows = await c.query(
            "SELECT timestamptz '2024-01-01 00:00:00+00' + g * interval '1 hour' "
            'FROM generate_series(1, 50000) g');
        if (rows.length != 50000) throw StateError('rows');
      });
    } finally {
      await c.close();
    }
  },
  'eloquent_scalar_select_x3000': () async {
    // Como o eloquent: placeholders "?" sem tipo e toColumnMap().
    final c = conn();
    await c.open();
    try {
      return await time(() async {
        for (var i = 0; i < 3000; i++) {
          final rs = await c.query('SELECT ?::int AS value',
              substitutionValues: [i],
              placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark);
          rs.first.toColumnMap();
        }
      });
    } finally {
      await c.close();
    }
  },
  'eloquent_insert_select_x2000': () async {
    final c = conn();
    await c.open();
    try {
      await c.execute('CREATE TEMP TABLE bench_elo (id serial primary key, '
          'name text, created_at timestamp, value numeric, active boolean)');
      return await time(() async {
        for (var i = 0; i < 2000; i++) {
          final rs = await c.query(
              'INSERT INTO bench_elo (name, created_at, value, active) '
              'VALUES (?, ?, ?, ?) RETURNING id',
              substitutionValues: ['nome $i', '2024-01-02 03:04:05', 1.5, true],
              placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark);
          final id = rs.first.toColumnMap()['id'];
          final row = await c.query('SELECT * FROM bench_elo WHERE id = ?',
              substitutionValues: [id],
              placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark);
          row.first.toColumnMap();
        }
      });
    } finally {
      await c.close();
    }
  },
  'eloquent_result_set_200_x500': () async {
    final c = conn();
    await c.open();
    try {
      await c.execute('CREATE TEMP TABLE bench_rs AS $bigSelect LIMIT 1000');
      return await time(() async {
        for (var i = 0; i < 500; i++) {
          final rs = await c.query(
              'SELECT * FROM bench_rs ORDER BY i LIMIT ?',
              substitutionValues: [200],
              placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark);
          for (final r in rs) {
            r.toColumnMap();
          }
        }
      });
    } finally {
      await c.close();
    }
  },
  'decode_values_cpu': () async {
    // 13 tipos x 100 mil valores, sem servidor.
    final utc = TimeZoneSettings('UTC');
    Uint8List b(void Function(ByteData d) f, int n) {
      final d = ByteData(n);
      f(d);
      return d.buffer.asUint8List();
    }
    Uint8List arr(int elemOid, List<List<int>> elems) {
      final bb = BytesBuilder();
      void i32(int v) => bb.add(b((d) => d.setInt32(0, v), 4));
      i32(1); i32(0); i32(elemOid); i32(elems.length); i32(1);
      for (final e in elems) { i32(e.length); bb.add(e); }
      return bb.toBytes();
    }
    final numeric = b((d) {
      d.setInt16(0, 2); d.setInt16(2, 0); d.setUint16(4, 0); d.setInt16(6, 4);
      d.setInt16(8, 1234); d.setInt16(10, 5678);
    }, 12);
    final cases = <int, Uint8List>{
      23: b((d) => d.setInt32(0, 42), 4),
      20: b((d) => d.setInt64(0, 1 << 40), 8),
      25: Uint8List.fromList(utf8.encode('um texto de tamanho medio')),
      1700: numeric,
      1184: b((d) => d.setInt64(0, 789000000000000), 8),
      1114: b((d) => d.setInt64(0, 789000000000000), 8),
      1082: b((d) => d.setInt32(0, 9000), 4),
      16: Uint8List.fromList([1]),
      701: b((d) => d.setFloat64(0, 3.25), 8),
      2950: Uint8List.fromList(List.generate(16, (i) => i)),
      3802: Uint8List.fromList([1, ...utf8.encode('{"a":1,"b":"x"}')]),
      1007: arr(23, [for (var i = 0; i < 5; i++) b((d) => d.setInt32(0, i), 4)]),
      1009: arr(25, [for (var i = 0; i < 5; i++) utf8.encode('t$i')]),
    };
    final decoders = {
      for (final oid in cases.keys) oid: PostgresBinaryDecoder(oid, utf8, utc)
    };
    return time(() async {
      for (var i = 0; i < 100000; i++) {
        for (final e in cases.entries) {
          decoders[e.key]!.convert(e.value);
        }
      }
    });
  },
  'encode_bind_cpu': () async {
    // Parâmetros (texto e binários) e mensagens Bind, sem servidor.
    final utc = TimeZoneSettings('UTC');
    final ts = DateTime.utc(2024, 1, 2, 3, 4, 5);
    return time(() async {
      for (var i = 0; i < 100000; i++) {
        final params = [
          ParameterValue.text(i, utf8),
          ParameterValue.text('texto $i', utf8),
          ParameterValue.text(1.5, utf8),
          ParameterValue.binary(i, PostgreSQLDataType.integer, utf8, utc),
          ParameterValue.binary('abc', PostgreSQLDataType.text, utf8, utc),
          ParameterValue.binary(ts, PostgreSQLDataType.timestampWithTimezone,
              utf8, utc),
        ];
        BindMessage(params, statementName: 's1', encoding: utf8).asBytes();
      }
    });
  },
  'framer_parse_200k_rows': () async {
    // Mensagens DataRow (5 colunas) em pedaços de 64 KB, sem servidor.
    final row = BytesBuilder();
    final cols = [
      Uint8List.fromList([0, 0, 0, 42]),
      utf8.encode('um texto qualquer de tamanho médio'),
      Uint8List(8),
      Uint8List.fromList(List.filled(16, 7)),
      utf8.encode('{"a":1}'),
    ];
    final body = BytesBuilder()..add([0, cols.length]);
    for (final c in cols) {
      body.add((ByteData(4)..setInt32(0, c.length)).buffer.asUint8List());
      body.add(c);
    }
    final b = body.toBytes();
    row.addByte(0x44);
    row.add((ByteData(4)..setInt32(0, b.length + 4)).buffer.asUint8List());
    row.add(b);
    final one = row.toBytes();
    final all = BytesBuilder();
    for (var i = 0; i < 200000; i++) {
      all.add(one);
    }
    final data = all.toBytes();
    // Pedaços independentes de 64 KB, como os entregues pelo socket.
    final chunks = <Uint8List>[
      for (var off = 0; off < data.length; off += 65536)
        Uint8List.fromList(data.sublist(
            off, off + 65536 < data.length ? off + 65536 : data.length))
    ];
    return time(() async {
      final framer = MessageFramer(utf8, TimeZoneSettings('UTC'));
      var count = 0;
      for (final chunk in chunks) {
        framer.addBytes(chunk);
        while (framer.hasMessage) {
          framer.popMessage();
          count++;
        }
      }
      if (count != 200000) throw StateError('count $count');
    });
  },
};

Future<void> main(List<String> args) async {
  final which = args.isEmpty || args.first == 'all'
      ? scenarios.keys.toList()
      : args;
  for (final name in which) {
    final us = await scenarios[name]!();
    stdout.writeln('$name\t${(us / 1000).toStringAsFixed(1)}');
  }
}
