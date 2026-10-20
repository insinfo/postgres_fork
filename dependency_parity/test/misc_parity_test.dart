// Paridade dos substitutos menores: `DelegatingList` e `ListEquality`
// (pacote `collection`), constantes do `charcode` e a detecção do codec
// Windows-1252 do `enough_convert` na mensagem de startup.
//
// ignore_for_file: implementation_imports, unnecessary_lambdas

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:charcode/ascii.dart' as charcode;
import 'package:collection/collection.dart' as collection;
import 'package:enough_convert/enough_convert.dart';
import 'package:postgres_fork/messages.dart';
import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/src/utils/ascii.dart' as pg_ascii;
import 'package:postgres_fork/src/utils/delegating_list.dart' as mine;
import 'package:test/test.dart';

String _outcome(Object? Function() fn) {
  try {
    final value = fn();
    if (value is Iterable) return 'value:${value.toList()}';
    return 'value:$value';
  } catch (e) {
    return 'error:${e.runtimeType}:$e';
  }
}

void main() {
  test('constantes ASCII', () {
    expect(pg_ascii.$3, charcode.$3);
    expect(pg_ascii.$C, charcode.$C);
    expect(pg_ascii.$P, charcode.$P);
    expect(pg_ascii.$S, charcode.$S);
    expect(pg_ascii.$X, charcode.$X);
  });

  test('DelegatingList: operações aleatórias', () {
    final random = Random(40);
    for (var round = 0; round < 2000; round++) {
      final initial = List.generate(random.nextInt(6), (_) => random.nextInt(5));
      final baseA = List<int>.of(initial);
      final baseB = List<int>.of(initial);
      final a = mine.DelegatingList<int>(baseA);
      final b = collection.DelegatingList<int>(baseB);
      for (var i = 0; i < 20; i++) {
        final x = random.nextInt(5);
        final y = random.nextInt(8) - 1;
        final ops = <String, List<Object? Function()>>{
          'index': [() => a[y], () => b[y]],
          'set': [() => a[y] = x, () => b[y] = x],
          'add': [() => a.add(x), () => b.add(x)],
          'addAll': [() => a.addAll([x, y]), () => b.addAll([x, y])],
          'plus': [() => a + [x], () => b + [x]],
          'insert': [() => a.insert(y, x), () => b.insert(y, x)],
          'insertAll': [() => a.insertAll(y, [x]), () => b.insertAll(y, [x])],
          'remove': [() => a.remove(x), () => b.remove(x)],
          'removeAt': [() => a.removeAt(y), () => b.removeAt(y)],
          'removeLast': [a.removeLast, b.removeLast],
          'removeRange': [() => a.removeRange(0, y), () => b.removeRange(0, y)],
          'removeWhere': [
            () => a.removeWhere((e) => e == x),
            () => b.removeWhere((e) => e == x)
          ],
          'retainWhere': [
            () => a.retainWhere((e) => e != x),
            () => b.retainWhere((e) => e != x)
          ],
          'first': [() => a.first, () => b.first],
          'last': [() => a.last, () => b.last],
          'setFirst': [() => a.first = x, () => b.first = x],
          'setLast': [() => a.last = x, () => b.last = x],
          'single': [() => a.single, () => b.single],
          'length': [() => a.length, () => b.length],
          'setLength': [() => a.length = y, () => b.length = y],
          'indexOf': [() => a.indexOf(x), () => b.indexOf(x)],
          'lastIndexOf': [() => a.lastIndexOf(x), () => b.lastIndexOf(x)],
          'indexWhere': [
            () => a.indexWhere((e) => e > x),
            () => b.indexWhere((e) => e > x)
          ],
          'lastIndexWhere': [
            () => a.lastIndexWhere((e) => e > x),
            () => b.lastIndexWhere((e) => e > x)
          ],
          'sublist': [() => a.sublist(0, y), () => b.sublist(0, y)],
          'getRange': [() => a.getRange(0, y), () => b.getRange(0, y)],
          'setRange': [
            () => a.setRange(0, y, [x, x, x, x, x, x, x, x]),
            () => b.setRange(0, y, [x, x, x, x, x, x, x, x])
          ],
          'fillRange': [() => a.fillRange(0, y, x), () => b.fillRange(0, y, x)],
          'replaceRange': [
            () => a.replaceRange(0, y, [x]),
            () => b.replaceRange(0, y, [x])
          ],
          'setAll': [() => a.setAll(y, [x]), () => b.setAll(y, [x])],
          'sort': [a.sort, b.sort],
          'shuffle': [
            () => a.shuffle(Random(x)),
            () => b.shuffle(Random(x))
          ],
          'reversed': [() => a.reversed, () => b.reversed],
          'asMap': [() => a.asMap(), () => b.asMap()],
          'contains': [() => a.contains(x), () => b.contains(x)],
          'elementAt': [() => a.elementAt(y), () => b.elementAt(y)],
          'where': [() => a.where((e) => e > x), () => b.where((e) => e > x)],
          'map': [() => a.map((e) => e * 2), () => b.map((e) => e * 2)],
          'expand': [() => a.expand((e) => [e, e]), () => b.expand((e) => [e, e])],
          'fold': [() => a.fold<int>(0, (p, e) => p + e), () => b.fold<int>(0, (p, e) => p + e)],
          'reduce': [() => a.reduce(max), () => b.reduce(max)],
          'join': [() => a.join(','), () => b.join(',')],
          'any': [() => a.any((e) => e == x), () => b.any((e) => e == x)],
          'every': [() => a.every((e) => e == x), () => b.every((e) => e == x)],
          'firstWhere': [
            () => a.firstWhere((e) => e == x, orElse: () => -1),
            () => b.firstWhere((e) => e == x, orElse: () => -1)
          ],
          'lastWhere': [
            () => a.lastWhere((e) => e == x),
            () => b.lastWhere((e) => e == x)
          ],
          'singleWhere': [
            () => a.singleWhere((e) => e == x),
            () => b.singleWhere((e) => e == x)
          ],
          'skip': [() => a.skip(x), () => b.skip(x)],
          'take': [() => a.take(x), () => b.take(x)],
          'skipWhile': [() => a.skipWhile((e) => e < x), () => b.skipWhile((e) => e < x)],
          'takeWhile': [() => a.takeWhile((e) => e < x), () => b.takeWhile((e) => e < x)],
          'followedBy': [() => a.followedBy([x]), () => b.followedBy([x])],
          'toList': [() => a.toList(growable: false), () => b.toList(growable: false)],
          'toSet': [() => a.toSet(), () => b.toSet()],
          'whereType': [() => a.whereType<int>(), () => b.whereType<int>()],
          'cast': [() => a.cast<num>(), () => b.cast<num>()],
          'isEmpty': [() => a.isEmpty, () => b.isEmpty],
          'isNotEmpty': [() => a.isNotEmpty, () => b.isNotEmpty],
          'iterator': [() => a.iterator.moveNext(), () => b.iterator.moveNext()],
          'toString': [a.toString, b.toString],
          'clear': [a.clear, b.clear],
        };
        final keys = ops.keys.toList();
        final key = keys[random.nextInt(keys.length)];
        expect(_outcome(ops[key]![0]), _outcome(ops[key]![1]), reason: key);
        expect(baseA, baseB, reason: 'estado após $key');
      }
    }
  });

  test('UnknownMessage.== equivale a ListEquality', () {
    final random = Random(41);
    Uint8List? randomBytes() {
      if (random.nextInt(5) == 0) return null;
      return Uint8List.fromList(
          List.generate(random.nextInt(4), (_) => random.nextInt(3)));
    }

    for (var i = 0; i < 5000; i++) {
      final codeA = random.nextInt(3);
      final codeB = random.nextInt(3);
      final bytesA = randomBytes();
      final bytesB = random.nextInt(4) == 0 ? bytesA : randomBytes();
      final expected = codeA == codeB &&
          const collection.ListEquality<int>().equals(bytesA, bytesB);
      expect(UnknownMessage(codeA, bytesA) == UnknownMessage(codeB, bytesB),
          expected);
    }
  });

  test('client_encoding enviado na StartupMessage', () {
    // Regra original: `encoding is Windows1252Codec` -> WIN1252.
    String expectedName(Encoding encoding) {
      if (encoding is Utf8Codec) return 'UTF8';
      if (encoding is AsciiCodec) return 'ascii';
      if (encoding is Latin1Codec) return 'ISO-8859-1';
      if (encoding is Windows1252Codec) return 'WIN1252';
      return 'UTF8';
    }

    final encodings = <Encoding>[
      utf8,
      ascii,
      latin1,
      const Utf8Codec(allowMalformed: true),
      const Windows1252Codec(),
      const Windows1252Codec(allowInvalid: true),
      const Windows1250Codec(),
      const Windows1251Codec(),
      const Latin2Codec(),
      const Latin15Codec(),
      const GbkCodec(),
    ];
    for (final encoding in encodings) {
      final bytes = StartupMessage('db', TimeZoneSettings('UTC'),
              username: 'user', encoding: encoding)
          .asBytes();
      final expected = [
        ...utf8.encode('client_encoding'),
        0,
        ...utf8.encode(expectedName(encoding)),
        0,
      ];
      final text = bytes.toList().join(',');
      expect(text.contains(expected.join(',')), isTrue,
          reason: '${encoding.name}: ${latin1.decode(bytes)}');
    }
  });
}
