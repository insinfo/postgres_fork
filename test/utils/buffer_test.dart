import 'dart:typed_data';

import 'package:postgres_fork/src/utils/buffer.dart';
import 'package:test/test.dart';

void main() {
  group('ByteDataWriter', () {
    test('escreve em big-endian por padrão', () {
      final writer = ByteDataWriter()
        ..writeUint8(0x01)
        ..writeInt16(-2)
        ..writeUint32(0x01020304)
        ..writeInt64(-1)
        ..writeFloat64(1.5);
      expect(writer.toBytes(), [
        0x01, 0xFF, 0xFE, 0x01, 0x02, 0x03, 0x04, //
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, //
        0x3F, 0xF8, 0, 0, 0, 0, 0, 0, //
      ]);
    });

    test('respeita o endian informado', () {
      final writer = ByteDataWriter(endian: Endian.little)
        ..writeUint16(0x0102)
        ..writeUint32(0x01020304, Endian.big);
      expect(writer.toBytes(), [0x02, 0x01, 0x01, 0x02, 0x03, 0x04]);
    });

    test('intercala bytes brutos e valores, com buffer pequeno', () {
      final writer = ByteDataWriter(bufferLength: 2)
        ..writeUint8(1)
        ..write([2, 3])
        ..writeUint32(0x04050607)
        ..write(Uint8List.fromList([8]))
        ..writeUint16(0x090A);
      expect(writer.toBytes(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    });

    test('vazio', () {
      expect(ByteDataWriter().toBytes(), isEmpty);
    });
  });

  group('ByteDataReader', () {
    test('lê valores atravessando fragmentos', () {
      final reader = ByteDataReader()
        ..add([0x01, 0x02])
        ..add([0x03])
        ..add([0x04, 0xFF, 0xFE]);
      expect(reader.remainingLength, 6);
      expect(reader.readUint32(), 0x01020304);
      expect(reader.offsetInBytes, 4);
      expect(reader.readInt16(), -2);
      expect(reader.remainingLength, 0);
    });

    test('read(n) concatena fragmentos e read(0) retorna vazio', () {
      final reader = ByteDataReader()
        ..add([1, 2, 3])
        ..add([4, 5]);
      expect(reader.read(0), isEmpty);
      expect(reader.read(4), [1, 2, 3, 4]);
      expect(reader.read(1), [5]);
    });

    test('falta de bytes lança StateError', () {
      final reader = ByteDataReader()..add([1, 2, 3]);
      expect(reader.readUint32, throwsStateError);
      expect(() => reader.read(4), throwsStateError);
      // Nada foi consumido.
      expect(reader.read(3), [1, 2, 3]);
    });

    test('sem cópia, read retorna uma view do buffer recebido', () {
      final chunk = Uint8List.fromList([1, 2, 3, 4]);
      final reader = ByteDataReader()..add(chunk);
      final view = reader.read(2);
      final copied = reader.read(2, copy: true);
      chunk[0] = 9;
      chunk[2] = 9;
      expect(view, [9, 2]);
      expect(copied, [3, 4]);
    });

    test('pedaços que são views de um buffer maior (regressão)', () {
      // O pacote `buffer` original lia além do fim do pedaço neste caso.
      final base = Uint8List.fromList(List.generate(20, (i) => i));
      final reader = ByteDataReader()
        ..add(Uint8List.sublistView(base, 0, 5))
        ..add(Uint8List.sublistView(base, 5, 10));
      expect(reader.read(2), [0, 1]);
      expect(reader.read(6), [2, 3, 4, 5, 6, 7]);
      expect(reader.remainingLength, 2);
      expect(reader.read(2), [8, 9]);
      expect(() => reader.read(1), throwsStateError);
    });

    test('respeita o offset de views recebidas', () {
      final base = Uint8List.fromList([0, 0, 0x12, 0x34, 0x56]);
      final reader = ByteDataReader()..add(Uint8List.sublistView(base, 2));
      expect(reader.readUint16(), 0x1234);
      expect(reader.readUint8(), 0x56);
    });
  });

  test('castBytes', () {
    final bytes = Uint8List.fromList([1, 2]);
    expect(identical(castBytes(bytes), bytes), isTrue);
    expect(identical(castBytes(bytes, copy: true), bytes), isFalse);
    expect(castBytes([1, 258]), [1, 2]);
  });
}
