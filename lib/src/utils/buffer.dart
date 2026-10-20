// Implementação interna que substitui o pacote `buffer`
// (https://pub.dev/packages/buffer, versão 1.2.3), contendo apenas o
// subconjunto usado por este driver. A lógica foi mantida idêntica à original
// para preservar exatamente o mesmo comportamento (incluindo os casos em que
// os bytes retornados são views sobre os buffers recebidos, sem cópia).
//
// Copyright 2018, the project authors. All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
//       copyright notice, this list of conditions and the following
//       disclaimer in the documentation and/or other materials provided
//       with the distribution.
//     * Neither the name of the project nor the names of its
//       contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'dart:collection';
import 'dart:typed_data';

final _emptyData = ByteData(0);

/// Cast the list of bytes into a typed [Uint8List].
///
/// When [copy] is specified, the content will be copied even if the input
/// [bytes] are already Uint8List.
Uint8List castBytes(List<int> bytes, {bool copy = false}) {
  if (bytes is Uint8List) {
    if (copy) {
      final list = Uint8List(bytes.length);
      list.setRange(0, list.length, bytes);
      return list;
    } else {
      return bytes;
    }
  } else {
    return Uint8List.fromList(bytes);
  }
}

/// A class for concatenating byte arrays efficiently.
///
/// Allows for the incremental building of a byte array using add*() methods.
/// The arrays are concatenated to a single byte array only when [toBytes] is
/// called.
class BytesBuffer {
  final List<Uint8List> _chunks;
  final bool _copy;
  int _length = 0;

  BytesBuffer({bool copy = false})
      : _chunks = <Uint8List>[],
        _copy = copy;

  /// The total length of the buffer.
  int get length => _length;

  /// Add a byte array to the buffer.
  ///
  /// Set [copy] to true if [bytes] need to be copied (e.g. the underlying
  /// buffer will be modified.)
  void add(List<int> bytes, {bool? copy}) {
    _chunks.add(castBytes(bytes, copy: copy ?? _copy));
    _length += bytes.length;
  }

  /// Add a single byte to the buffer.
  void addByte(int byte) {
    add([byte]);
  }

  /// Concatenate the byte arrays and return them as a single unit.
  Uint8List toBytes({bool? copy}) {
    if (_chunks.length == 1 && !(copy ?? _copy)) {
      return _chunks.single;
    }
    final list = Uint8List(_length);
    var offset = 0;
    for (var i = 0; i < _chunks.length; i++) {
      final chunk = _chunks[i];
      list.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return list;
  }
}

/// A class for building byte arrays with a [BytesBuffer] and a fixed-length
/// work buffer.
///
/// Allows for the incremental building of a byte array using write*() methods.
/// The arrays are concatenated to a single byte array only when [toBytes] is
/// called.
class ByteDataWriter {
  int bufferLength;
  final Endian endian;
  BytesBuffer? _bb;
  ByteData _data = _emptyData;
  int _offset = 0;

  ByteDataWriter({this.bufferLength = 128, this.endian = Endian.big});

  void _flush() {
    if (_data != _emptyData) {
      if (_offset > 0) {
        _bb ??= BytesBuffer();
        _bb!.add(_data.buffer.asUint8List(0, _offset));
      }
      _data = _emptyData;
      _offset = 0;
    }
  }

  void _init(int required) {
    if (_data == _emptyData || _offset + required > _data.lengthInBytes) {
      _flush();
      _data = ByteData(bufferLength > required ? bufferLength : required);
    }
  }

  void write(List<int> bytes, {bool copy = false}) {
    _flush();
    _bb ??= BytesBuffer();
    _bb!.add(bytes, copy: copy);
  }

  void writeFloat32(double value, [Endian? endian]) {
    _init(4);
    _data.setFloat32(_offset, value, endian ?? this.endian);
    _offset += 4;
  }

  void writeFloat64(double value, [Endian? endian]) {
    _init(8);
    _data.setFloat64(_offset, value, endian ?? this.endian);
    _offset += 8;
  }

  void writeInt8(int value) {
    _init(1);
    _data.setInt8(_offset, value);
    _offset++;
  }

  void writeInt16(int value, [Endian? endian]) {
    _init(2);
    _data.setInt16(_offset, value, endian ?? this.endian);
    _offset += 2;
  }

  void writeInt32(int value, [Endian? endian]) {
    _init(4);
    _data.setInt32(_offset, value, endian ?? this.endian);
    _offset += 4;
  }

  void writeInt64(int value, [Endian? endian]) {
    _init(8);
    _data.setInt64(_offset, value, endian ?? this.endian);
    _offset += 8;
  }

  void writeUint8(int value) {
    _init(1);
    _data.setUint8(_offset, value);
    _offset++;
  }

  void writeUint16(int value, [Endian? endian]) {
    _init(2);
    _data.setUint16(_offset, value, endian ?? this.endian);
    _offset += 2;
  }

  void writeUint32(int value, [Endian? endian]) {
    _init(4);
    _data.setUint32(_offset, value, endian ?? this.endian);
    _offset += 4;
  }

  void writeUint64(int value, [Endian? endian]) {
    _init(8);
    _data.setUint64(_offset, value, endian ?? this.endian);
    _offset += 8;
  }

  /// Concatenate the byte arrays and return them as a single unit.
  Uint8List toBytes() {
    if (_bb == null) {
      return _data.buffer.asUint8List(0, _offset);
    }
    _flush();
    return _bb?.toBytes() ?? _emptyData.buffer.asUint8List();
  }
}

/// A class for parsing byte arrays.
///
/// Allows incremental building of the input byte stream using the add() method.
/// The input arrays are concatenated as needed.
class ByteDataReader {
  final Endian endian;
  final _queue = DoubleLinkedQueue<Uint8List>();
  final bool _copy;
  int _offset = 0;
  int _queueCurrentLength = 0;
  int _queueTotalLength = 0;
  ByteData _data = _emptyData;

  ByteDataReader({this.endian = Endian.big, bool copy = false}) : _copy = copy;

  /// The number of bytes available to read.
  int get remainingLength => _queueCurrentLength - _offset;

  /// The offset in bytes (the current position).
  int get offsetInBytes => _queueTotalLength - remainingLength;

  void _clearQueue() {
    while (_queue.isNotEmpty && _queue.first.length == _offset) {
      final first = _queue.removeFirst();
      _queueCurrentLength -= first.length;
      _offset = 0;
      _data = _emptyData;
    }
  }

  void _init(int required) {
    if (remainingLength < required) {
      throw StateError('Not enough bytes to read.');
    }
    _clearQueue();
    if (_offset + required > _queue.first.length) {
      final buffer = BytesBuffer();
      final first = _queue.removeFirst();
      _queueCurrentLength -= first.length;
      buffer.add(first.buffer.asUint8List(
          first.offsetInBytes + _offset, first.lengthInBytes - _offset));
      _offset = 0;
      while (buffer.length < required) {
        final next = _queue.removeFirst();
        _queueCurrentLength -= next.length;
        buffer.add(next);
      }
      final merged = buffer.toBytes();
      _queueCurrentLength += merged.length;
      _queue.addFirst(merged);
      _data = _emptyData;
    }
    if (_data == _emptyData) {
      _data = ByteData.view(_queue.first.buffer, _queue.first.offsetInBytes);
    }
  }

  void add(List<int> bytes, {bool? copy}) {
    _queue.add(castBytes(bytes, copy: copy ?? _copy));
    _queueCurrentLength += bytes.length;
    _queueTotalLength += bytes.length;
  }

  Uint8List read(int length, {bool? copy}) {
    if (length == 0) {
      return Uint8List(0);
    }
    if (_queue.isEmpty || _queueCurrentLength - _offset < length) {
      throw StateError('Not enough bytes to read.');
    }
    _clearQueue();
    final shouldCopy = copy ?? _copy;
    if (!shouldCopy && (_offset + length <= _queue.first.length)) {
      final value = Uint8List.view(
          _queue.first.buffer, _queue.first.offsetInBytes + _offset, length);
      _offset += length;
      return value;
    }
    final bb = BytesBuffer(copy: copy ?? _copy);
    while (bb.length < length) {
      _clearQueue();
      final remaining = length - bb.length;
      if (_offset + remaining <= _queue.first.length) {
        _addNextBytesToBuffer(bb, remaining);
      } else {
        _removeFirstQueueItemAddToBuffer(bb);
      }
    }
    return bb.toBytes();
  }

  void _addNextBytesToBuffer(BytesBuffer bb, int amount) {
    bb.add(Uint8List.view(
        _queue.first.buffer, _queue.first.offsetInBytes + _offset, amount));
    _offset += amount;
  }

  void _removeFirstQueueItemAddToBuffer(BytesBuffer bb) {
    final first = _queue.removeFirst();
    _queueCurrentLength -= first.length;
    if (_offset == 0) {
      bb.add(first, copy: false);
    } else {
      // Correção em relação ao pacote `buffer` original: limita a view ao fim
      // do pedaço. Sem o comprimento, quando o pedaço é uma view de um buffer
      // maior, eram lidos bytes além dele (mensagens perdidas ou RangeError).
      bb.add(Uint8List.view(
          first.buffer, first.offsetInBytes + _offset, first.length - _offset));
    }
    _data = _emptyData;
    _offset = 0;
  }

  double readFloat32([Endian? endian]) {
    _init(4);
    final value = _data.getFloat32(_offset, endian ?? this.endian);
    _offset += 4;
    return value;
  }

  double readFloat64([Endian? endian]) {
    _init(8);
    final value = _data.getFloat64(_offset, endian ?? this.endian);
    _offset += 8;
    return value;
  }

  int readInt8() {
    _init(1);
    final value = _data.getInt8(_offset);
    _offset += 1;
    return value;
  }

  int readInt16([Endian? endian]) {
    _init(2);
    final value = _data.getInt16(_offset, endian ?? this.endian);
    _offset += 2;
    return value;
  }

  int readInt32([Endian? endian]) {
    _init(4);
    final value = _data.getInt32(_offset, endian ?? this.endian);
    _offset += 4;
    return value;
  }

  int readInt64([Endian? endian]) {
    _init(8);
    final value = _data.getInt64(_offset, endian ?? this.endian);
    _offset += 8;
    return value;
  }

  int readUint8() {
    _init(1);
    final value = _data.getUint8(_offset);
    _offset += 1;
    return value;
  }

  int readUint16([Endian? endian]) {
    _init(2);
    final value = _data.getUint16(_offset, endian ?? this.endian);
    _offset += 2;
    return value;
  }

  int readUint32([Endian? endian]) {
    _init(4);
    final value = _data.getUint32(_offset, endian ?? this.endian);
    _offset += 4;
    return value;
  }

  int readUint64([Endian? endian]) {
    _init(8);
    final value = _data.getUint64(_offset, endian ?? this.endian);
    _offset += 8;
    return value;
  }
}
