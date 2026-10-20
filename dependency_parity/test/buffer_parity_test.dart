// Compara lib/src/utils/buffer.dart com o pacote `buffer` 1.2.3.
//
// ignore_for_file: implementation_imports

import 'dart:math';
import 'dart:typed_data';

import 'package:buffer/buffer.dart' as orig;
import 'package:postgres_fork/src/utils/buffer.dart' as mine;
import 'package:test/test.dart';

/// Resultado de uma operação: valor ou exceção (tipo + mensagem).
String _outcome(Object? Function() fn) {
  try {
    final value = fn();
    if (value is Uint8List) return 'bytes${value.toList()}';
    if (value is double && value.isNaN) return 'NaN';
    return 'value:$value';
  } catch (e) {
    return 'error:${e.runtimeType}:$e';
  }
}

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));

void main() {
  test('castBytes', () {
    final random = Random(1);
    for (var i = 0; i < 200; i++) {
      final copy = random.nextBool();
      final bytes = _randomBytes(random, random.nextInt(20));
      final asList = List<int>.from(bytes);
      // Uint8List: mesma instância quando copy == false.
      expect(identical(mine.castBytes(bytes, copy: copy), bytes),
          identical(orig.castBytes(bytes, copy: copy), bytes));
      expect(mine.castBytes(bytes, copy: copy), orig.castBytes(bytes, copy: copy));
      // List<int> genérica (inclui valores fora de 0..255).
      asList.add(random.nextInt(100000) - 50000);
      expect(mine.castBytes(asList, copy: copy),
          orig.castBytes(asList, copy: copy));
    }
  });

  test('ByteDataWriter: sequências aleatórias de escrita', () {
    final random = Random(2);
    for (var round = 0; round < 3000; round++) {
      final bufferLength = random.nextInt(40) + 1;
      final endian = random.nextBool() ? Endian.big : Endian.little;
      final a = mine.ByteDataWriter(bufferLength: bufferLength, endian: endian);
      final b = orig.ByteDataWriter(bufferLength: bufferLength, endian: endian);
      final ops = random.nextInt(30);
      for (var i = 0; i < ops; i++) {
        final opEndian = random.nextInt(3) == 0
            ? null
            : (random.nextBool() ? Endian.big : Endian.little);
        final op = random.nextInt(13);
        final intValue = random.nextInt(1 << 32) * (random.nextBool() ? 1 : -1);
        final doubleValue = (random.nextDouble() - 0.5) * 1e6;
        switch (op) {
          case 0:
            a.writeUint8(intValue);
            b.writeUint8(intValue);
            break;
          case 1:
            a.writeUint16(intValue, opEndian);
            b.writeUint16(intValue, opEndian);
            break;
          case 2:
            a.writeUint32(intValue, opEndian);
            b.writeUint32(intValue, opEndian);
            break;
          case 3:
            final v = intValue * 1000003;
            a.writeUint64(v, opEndian);
            b.writeUint64(v, opEndian);
            break;
          case 4:
            a.writeInt8(intValue);
            b.writeInt8(intValue);
            break;
          case 5:
            a.writeInt16(intValue, opEndian);
            b.writeInt16(intValue, opEndian);
            break;
          case 6:
            a.writeInt32(intValue, opEndian);
            b.writeInt32(intValue, opEndian);
            break;
          case 7:
            final v = intValue * 1000003;
            a.writeInt64(v, opEndian);
            b.writeInt64(v, opEndian);
            break;
          case 8:
            a.writeFloat32(doubleValue, opEndian);
            b.writeFloat32(doubleValue, opEndian);
            break;
          case 9:
            a.writeFloat64(doubleValue, opEndian);
            b.writeFloat64(doubleValue, opEndian);
            break;
          case 10:
          case 11:
            final bytes = random.nextBool()
                ? _randomBytes(random, random.nextInt(50))
                : List<int>.generate(random.nextInt(10), (_) => random.nextInt(300));
            final copy = random.nextBool();
            a.write(bytes, copy: copy);
            b.write(bytes, copy: copy);
            break;
          case 12:
            // toBytes no meio da escrita.
            expect(a.toBytes(), b.toBytes());
            break;
        }
      }
      expect(a.toBytes(), b.toBytes());
      expect(a.toBytes(), b.toBytes(), reason: 'toBytes repetido');
    }
  });

  test('ByteDataWriter: write sem cópia mantém o mesmo aliasing', () {
    final random = Random(3);
    for (var round = 0; round < 500; round++) {
      final sourceA = _randomBytes(random, random.nextInt(10) + 1);
      final sourceB = Uint8List.fromList(sourceA);
      final copy = random.nextBool();
      final a = mine.ByteDataWriter()..write(sourceA, copy: copy);
      final b = orig.ByteDataWriter()..write(sourceB, copy: copy);
      if (random.nextBool()) {
        a.writeUint8(7);
        b.writeUint8(7);
      }
      final resultA = a.toBytes();
      final resultB = b.toBytes();
      sourceA[0] = sourceA[0] ^ 0xFF;
      sourceB[0] = sourceB[0] ^ 0xFF;
      expect(resultA, resultB);
    }
  });

  test('ByteDataReader: leituras aleatórias sobre fragmentos aleatórios', () {
    final random = Random(4);
    for (var round = 0; round < 4000; round++) {
      final readerCopy = random.nextInt(3) == 0;
      final endian = random.nextBool() ? Endian.big : Endian.little;
      final a = mine.ByteDataReader(endian: endian, copy: readerCopy);
      final b = orig.ByteDataReader(endian: endian, copy: readerCopy);
      final chunksA = <Uint8List>[];
      final chunksB = <Uint8List>[];
      final resultsA = <Uint8List>[];
      final resultsB = <Uint8List>[];

      final ops = random.nextInt(40);
      for (var i = 0; i < ops; i++) {
        final op = random.nextInt(16);
        final opEndian = random.nextInt(3) == 0
            ? null
            : (random.nextBool() ? Endian.big : Endian.little);
        if (op < 4) {
          final chunk = _randomBytes(random, random.nextInt(12));
          final chunkB = Uint8List.fromList(chunk);
          final copy = random.nextInt(3) == 0 ? null : random.nextBool();
          if (random.nextInt(4) == 0 && chunk.length > 2) {
            // Views com offset, como os pedaços de um socket.
            final start = random.nextInt(chunk.length);
            final viewA = Uint8List.sublistView(chunk, start);
            final viewB = Uint8List.sublistView(chunkB, start);
            a.add(viewA, copy: copy);
            b.add(viewB, copy: copy);
          } else {
            a.add(chunk, copy: copy);
            b.add(chunkB, copy: copy);
          }
          chunksA.add(chunk);
          chunksB.add(chunkB);
          continue;
        }
        String compare(Object? Function() fa, Object? Function() fb) {
          final ra = _outcome(fa);
          final rb = _outcome(fb);
          expect(ra, rb);
          return ra;
        }

        switch (op) {
          case 4:
            compare(a.readUint8, b.readUint8);
            break;
          case 5:
            compare(() => a.readUint16(opEndian), () => b.readUint16(opEndian));
            break;
          case 6:
            compare(() => a.readUint32(opEndian), () => b.readUint32(opEndian));
            break;
          case 7:
            compare(() => a.readUint64(opEndian), () => b.readUint64(opEndian));
            break;
          case 8:
            compare(a.readInt8, b.readInt8);
            break;
          case 9:
            compare(() => a.readInt16(opEndian), () => b.readInt16(opEndian));
            break;
          case 10:
            compare(() => a.readInt32(opEndian), () => b.readInt32(opEndian));
            break;
          case 11:
            compare(() => a.readInt64(opEndian), () => b.readInt64(opEndian));
            break;
          case 12:
            compare(
                () => a.readFloat32(opEndian), () => b.readFloat32(opEndian));
            compare(
                () => a.readFloat64(opEndian), () => b.readFloat64(opEndian));
            break;
          case 13:
          case 14:
            final length = random.nextInt(15);
            final copy = random.nextInt(3) == 0 ? null : random.nextBool();
            Uint8List? ra;
            Uint8List? rb;
            compare(() => ra = a.read(length, copy: copy),
                () => rb = b.read(length, copy: copy));
            if (ra != null) resultsA.add(ra!);
            if (rb != null) resultsB.add(rb!);
            break;
          case 15:
            expect(a.remainingLength, b.remainingLength);
            expect(a.offsetInBytes, b.offsetInBytes);
            break;
        }
        expect(a.remainingLength, b.remainingLength);
      }

      // Aliasing: alterar os buffers de origem deve afetar (ou não) os
      // resultados lidos exatamente da mesma forma nas duas implementações.
      for (final chunk in [...chunksA, ...chunksB]) {
        for (var i = 0; i < chunk.length; i++) {
          chunk[i] = chunk[i] ^ 0x5A;
        }
      }
      expect(resultsA.length, resultsB.length);
      for (var i = 0; i < resultsA.length; i++) {
        expect(resultsA[i], resultsB[i], reason: 'leitura #$i após mutação');
      }
    }
  });
}
