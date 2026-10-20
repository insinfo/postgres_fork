import 'dart:convert';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import 'package:postgres_fork/src/timezone_settings.dart';

import 'decimal.dart';
import 'decoding_settings.dart';
import 'pg_binary_text.dart';
import 'pg_values.dart';
import 'timezone/timestamptz.dart';
import 'types.dart';
import 'utils/buffer.dart';
import 'v3/types.dart';

final _bool0 = Uint8List(1)..[0] = 0;
final _bool1 = Uint8List(1)..[0] = 1;
final _dashUnit = '-'.codeUnits.first;
final _hex = <String>[
  '0',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  'a',
  'b',
  'c',
  'd',
  'e',
  'f',
];
final _numericRegExp = RegExp(r'^(\d*)(\.\d*)?$');
final _leadingZerosRegExp = RegExp(r'^0+');
final _trailingZerosRegExp = RegExp(r'0+$');

class PostgresBinaryEncoder<T extends Object>
    extends Converter<T?, Uint8List?> {
  final PgDataType<T> _dataType;
  final Encoding encoding;

  const PostgresBinaryEncoder(this._dataType, this.encoding);

  @override
  Uint8List? convert(Object? input) {
    if (input == null) {
      return null;
    }

    // ignore: unnecessary_cast
    switch (_dataType as PgDataType<Object>) {
      case PgDataType.boolean:
        {
          if (input is bool) {
            return input ? _bool1 : _bool0;
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: bool Got: ${input.runtimeType}');
        }
      case PgDataType.bigSerial:
      case PgDataType.bigInteger:
        {
          if (input is int) {
            final bd = ByteData(8);
            bd.setInt64(0, input);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: int Got: ${input.runtimeType}');
        }
      case PgDataType.serial:
      case PgDataType.integer:
        {
          if (input is int) {
            final bd = ByteData(4);
            bd.setInt32(0, input);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: int Got: ${input.runtimeType}');
        }
      case PgDataType.smallInteger:
        {
          if (input is int) {
            final bd = ByteData(2);
            bd.setInt16(0, input);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: int Got: ${input.runtimeType}');
        }
      case PgDataType.name:
      case PgDataType.text:
      case PgDataType.varChar:
        {
          if (input is String) {
            return castBytes(encoding.encode(input));
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: String Got: ${input.runtimeType}');
        }
      case PgDataType.real:
        {
          if (input is double) {
            final bd = ByteData(4);
            bd.setFloat32(0, input);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: double Got: ${input.runtimeType}');
        }
      case PgDataType.double:
        {
          if (input is double) {
            final bd = ByteData(8);
            bd.setFloat64(0, input);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: double Got: ${input.runtimeType}');
        }
      case PgDataType.date:
        {
          if (input is DateTime) {
            // A data do próprio DateTime (como no formato texto). Antes era
            // a data em UTC, truncada em direção a zero: antes de 2000, um
            // horário depois da meia-noite virava o dia seguinte.
            final bd = ByteData(4);
            bd.setInt32(
                0,
                DateTime.utc(input.year, input.month, input.day)
                    .difference(DateTime.utc(2000))
                    .inDays);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: DateTime Got: ${input.runtimeType}');
        }

      case PgDataType.timestampWithoutTimezone:
        {
          if (input is DateTime) {
            final bd = ByteData(8);
            final diff = input.toUtc().difference(DateTime.utc(2000));
            bd.setInt64(0, diff.inMicroseconds);

            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: DateTime Got: ${input.runtimeType}');
        }

      case PgDataType.timestampWithTimezone:
        {
          if (input is DateTime) {
            final bd = ByteData(8);
            bd.setInt64(
                0, input.toUtc().difference(DateTime.utc(2000)).inMicroseconds);

            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: DateTime Got: ${input.runtimeType}');
        }

      case PgDataType.interval:
        {
          if (input is Duration) {
            final bd = ByteData(16);
            bd.setInt64(0, input.inMicroseconds);
            // ignoring the second 8 bytes
            return bd.buffer.asUint8List();
          }
          if (input is PgInterval) {
            final bd = ByteData(16);
            bd.setInt64(0, input.microseconds);
            bd.setInt32(8, input.days);
            bd.setInt32(12, input.months);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: Duration or PgInterval Got: ${input.runtimeType}');
        }

      case PgDataType.numeric:
        {
          Object source = input;

          if (source is PgDecimal) {
            return encodePgDecimal(source);
          }
          if (source is double || source is int) {
            source = input.toString();
          }
          if (source is String) {
            return _encodeNumeric(source);
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: String|double|int|PgDecimal Got: ${input.runtimeType}');
        }

      case PgDataType.jsonb:
        {
          final jsonBytes = encoding.encode(json.encode(input));
          final writer = ByteDataWriter(bufferLength: jsonBytes.length + 1);
          writer.writeUint8(1);
          writer.write(jsonBytes);
          return writer.toBytes();
        }

      case PgDataType.json:
        return castBytes(encoding.encode(json.encode(input)));

      case PgDataType.byteArray:
        {
          if (input is List<int>) {
            return castBytes(input);
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<int> Got: ${input.runtimeType}');
        }

      case PgDataType.uuid:
        {
          if (input is! String) {
            throw FormatException(
                'Invalid type for parameter value. Expected: String Got: ${input.runtimeType}');
          }

          final hexBytes = input
              .toLowerCase()
              .codeUnits
              .where((c) => c != _dashUnit)
              .toList();
          if (hexBytes.length != 32) {
            throw FormatException(
                "Invalid UUID string. There must be exactly 32 hexadecimal (0-9 and a-f) characters and any number of '-' characters.");
          }

          int byteConvert(int charCode) {
            if (charCode >= 48 && charCode <= 57) {
              return charCode - 48;
            } else if (charCode >= 97 && charCode <= 102) {
              return charCode - 87;
            }

            throw FormatException(
                'Invalid UUID string. Contains non-hexadecimal character (0-9 and a-f).');
          }

          final outBuffer = Uint8List(16);
          for (var i = 0, j = 0; i < hexBytes.length; i += 2, j++) {
            final upperByte = byteConvert(hexBytes[i]);
            final lowerByte = byteConvert(hexBytes[i + 1]);

            outBuffer[j] = (upperByte << 4) + lowerByte;
          }
          return outBuffer;
        }

      case PgDataType.point:
        {
          if (input is PgPoint) {
            final bd = ByteData(16);
            bd.setFloat64(0, input.latitude);
            bd.setFloat64(8, input.longitude);
            return bd.buffer.asUint8List();
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: PgPoint Got: ${input.runtimeType}');
        }

      case PgDataType.booleanArray:
        {
          if (input is List<bool>) {
            return writeListBytes<bool>(input, 16, (_) => 1,
                (writer, item) => writer.writeUint8(item ? 1 : 0));
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<bool> Got: ${input.runtimeType}');
        }

      case PgDataType.integerArray:
        {
          if (input is List<int>) {
            return writeListBytes<int>(
                input, 23, (_) => 4, (writer, item) => writer.writeInt32(item));
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<int> Got: ${input.runtimeType}');
        }

      case PgDataType.bigIntegerArray:
        {
          if (input is List<int>) {
            return writeListBytes<int>(
                input, 20, (_) => 8, (writer, item) => writer.writeInt64(item));
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<int> Got: ${input.runtimeType}');
        }

      case PgDataType.varCharArray:
        {
          if (input is List<String>) {
            // ignore: unnecessary_lambdas
            final bytesArray = input.map((v) => encoding.encode(v));
            return writeListBytes<List<int>>(bytesArray, 1043,
                (item) => item.length, (writer, item) => writer.write(item));
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<String> Got: ${input.runtimeType}');
        }

      case PgDataType.textArray:
        {
          if (input is List<String>) {
            // ignore: unnecessary_lambdas
            final bytesArray = input.map((v) => encoding.encode(v));
            return writeListBytes<List<int>>(bytesArray, 25,
                (item) => item.length, (writer, item) => writer.write(item));
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<String> Got: ${input.runtimeType}');
        }

      case PgDataType.doubleArray:
        {
          if (input is List<double>) {
            return writeListBytes<double>(input, 701, (_) => 8,
                (writer, item) => writer.writeFloat64(item));
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<double> Got: ${input.runtimeType}');
        }

      case PgDataType.jsonbArray:
        {
          if (input is List<Object>) {
            final objectsArray =
                input.map((v) => encoding.encode(json.encode(v)));
            return writeListBytes<List<int>>(
                objectsArray, 3802, (item) => item.length + 1, (writer, item) {
              writer.writeUint8(1);
              writer.write(item);
            });
          }
          throw FormatException(
              'Invalid type for parameter value. Expected: List<Object> Got: ${input.runtimeType}');
        }
    }
  }

  Uint8List writeListBytes<V>(
      Iterable<V> value,
      int type,
      int Function(V item) lengthEncoder,
      void Function(ByteDataWriter writer, V item) valueEncoder) {
    final writer = ByteDataWriter();

    writer.writeInt32(1); // dimension
    writer.writeInt32(0); // ign
    writer.writeInt32(type); // type
    writer.writeInt32(value.length); // size
    writer.writeInt32(1); // index

    for (var i in value) {
      final len = lengthEncoder(i);
      writer.writeInt32(len);
      valueEncoder(writer, i);
    }

    return writer.toBytes();
  }

  /// Encode String / double / int to numeric / decimal  without loosing precision.
  /// Compare implementation: https://github.com/frohoff/jdk8u-dev-jdk/blob/da0da73ab82ed714dc5be94acd2f0d00fbdfe2e9/src/share/classes/java/math/BigDecimal.java#L409
  Uint8List _encodeNumeric(String value) {
    value = value.trim();
    var signByte = 0x0000;
    final lower = value.toLowerCase();
    if (lower == 'infinity' || lower == '+infinity' || lower == '-infinity') {
      return encodePgDecimal(PgDecimal.parse(lower));
    }
    if (lower == 'nan') {
      signByte = 0xc000;
      value = '';
    } else if (value.startsWith('-')) {
      value = value.substring(1);
      signByte = 0x4000;
    } else if (value.startsWith('+')) {
      value = value.substring(1);
    }
    if (!_numericRegExp.hasMatch(value)) {
      throw FormatException(
          'Invalid format for parameter value. Expected: String which matches "/^(\\d*)(\\.\\d*)?\$/" Got: $value');
    }
    final parts = value.split('.');

    var intPart = parts[0].replaceAll(_leadingZerosRegExp, '');
    var intWeight = intPart.isEmpty ? -1 : (intPart.length - 1) ~/ 4;
    intPart = intPart.padLeft((intWeight + 1) * 4, '0');

    var fractPart = parts.length > 1 ? parts[1] : '';
    final dScale = fractPart.length;
    fractPart = fractPart.replaceAll(_trailingZerosRegExp, '');
    var fractWeight = fractPart.isEmpty ? -1 : (fractPart.length - 1) ~/ 4;
    fractPart = fractPart.padRight((fractWeight + 1) * 4, '0');

    var weight = intWeight;
    if (intWeight < 0) {
      // If int part has no weight, handle leading zeros in fractional part.
      if (fractPart.isEmpty) {
        // Weight of value 0 or '' is 0;
        weight = 0;
      } else {
        final leadingZeros =
            _leadingZerosRegExp.firstMatch(fractPart)?.group(0);
        if (leadingZeros != null) {
          final leadingZerosWeight =
              leadingZeros.length ~/ 4; // Get count of leading zeros '0000'
          fractPart = fractPart
              .substring(leadingZerosWeight * 4); // Remove leading zeros '0000'
          fractWeight -= leadingZerosWeight;
          weight = -(leadingZerosWeight + 1); // Ignore leading zeros in weight
        }
      }
    } else if (fractWeight < 0) {
      // If int fract has no weight, handle trailing zeros in int part.
      final trailingZeros = _trailingZerosRegExp.firstMatch(intPart)?.group(0);
      if (trailingZeros != null) {
        final trailingZerosWeight =
            trailingZeros.length ~/ 4; // Get count of trailing zeros '0000'
        intPart = intPart.substring(
            0,
            intPart.length -
                trailingZerosWeight * 4); // Remove leading zeros '0000'
        intWeight -= trailingZerosWeight;
      }
    }

    final nDigits = intWeight + fractWeight + 2;

    final writer = ByteDataWriter();
    writer.writeInt16(nDigits);
    writer.writeInt16(weight);
    writer.writeUint16(signByte);
    writer.writeInt16(dScale);
    for (var i = 0; i <= intWeight * 4; i += 4) {
      writer.writeInt16(int.parse(intPart.substring(i, i + 4)));
    }
    for (var i = 0; i <= fractWeight * 4; i += 4) {
      writer.writeInt16(int.parse(fractPart.substring(i, i + 4)));
    }
    return writer.toBytes();
  }
}

/// Representação binária (`numeric_send`) de [value].
Uint8List encodePgDecimal(PgDecimal value) {
  final writer = ByteDataWriter();
  if (!value.isFinite) {
    writer
      ..writeInt16(0)
      ..writeInt16(0)
      ..writeUint16(value.isNaN
          ? 0xC000
          : value.isNegative
              ? 0xF000
              : 0xD000)
      ..writeInt16(0);
    return writer.toBytes();
  }
  final scale = value.scale;
  final unscaled = value.unscaledValue;
  if (unscaled == BigInt.zero) {
    writer
      ..writeInt16(0)
      ..writeInt16(0)
      ..writeUint16(0)
      ..writeInt16(scale);
    return writer.toBytes();
  }
  // Alinha a parte fracionária em grupos de 4 dígitos (base 10000).
  final scale4 = (scale + 3) ~/ 4 * 4;
  var text = unscaled.abs().toString() + '0' * (scale4 - scale);
  final pad = (4 - text.length % 4) % 4;
  text = '0' * pad + text;
  final groups = <int>[
    for (var i = 0; i < text.length; i += 4) int.parse(text.substring(i, i + 4))
  ];
  final weight = groups.length - 1 - scale4 ~/ 4;
  var count = groups.length;
  while (count > 0 && groups[count - 1] == 0) {
    count--;
  }
  writer
    ..writeInt16(count)
    ..writeInt16(weight)
    ..writeUint16(unscaled.isNegative ? 0x4000 : 0)
    ..writeInt16(scale);
  for (var i = 0; i < count; i++) {
    writer.writeInt16(groups[i]);
  }
  return writer.toBytes();
}

/// Lê a representação binária (`numeric_send`) de um `numeric`.
PgDecimal decodePgDecimal(Uint8List value) {
  final data = ByteData.view(value.buffer, value.offsetInBytes, value.length);
  final count = data.getInt16(0);
  final weight = data.getInt16(2);
  final sign = data.getUint16(4);
  final scale = data.getInt16(6);
  switch (sign) {
    case 0xC000:
      return PgDecimal.nan;
    case 0xD000:
      return PgDecimal.infinity;
    case 0xF000:
      return PgDecimal.negativeInfinity;
  }
  // N = dígitos na base 10000; valor = N × 10^exponent.
  BigInt n;
  if (count <= 4) {
    var small = 0;
    for (var i = 0; i < count; i++) {
      small = small * 10000 + data.getInt16(8 + 2 * i);
    }
    n = BigInt.from(small);
  } else {
    final buffer = StringBuffer();
    for (var i = 0; i < count; i++) {
      final digit = data.getInt16(8 + 2 * i).toString();
      buffer.write(i == 0 ? digit : digit.padLeft(4, '0'));
    }
    n = BigInt.parse(buffer.toString());
  }
  if (sign == 0x4000) n = -n;
  final exponent = 4 * (weight - count + 1);
  // unscaled = N × 10^(exponent + scale)
  final shift = exponent + scale;
  if (shift >= 0) {
    return PgDecimal.fromBigInt(n * BigInt.from(10).pow(shift), scale: scale);
  }
  final divisor = BigInt.from(10).pow(-shift);
  if (n.remainder(divisor) == BigInt.zero) {
    return PgDecimal.fromBigInt(n ~/ divisor, scale: scale);
  }
  // Dígitos além da escala informada (não enviados pelo PostgreSQL):
  // preserva o valor exato.
  return PgDecimal.fromBigInt(n, scale: -exponent);
}

class PostgresBinaryDecoder<T> extends Converter<Uint8List?, T?> {
  PostgresBinaryDecoder(this.typeCode, this.encoding, this.timeZone,
      {this.decoding = const DecodingSettings()})
      : _dataType = typeMap[typeCode],
        _isText = _textOids.contains(typeCode);

  /// [typeMap] for [typeCode], looked up once per column: [convert] runs for
  /// every value and used to look it up every time.
  final PostgreSQLDataType? _dataType;

  /// A text type ([_textOids]): decoded before anything else.
  final bool _isText;

  final int typeCode;
  final Encoding encoding;
  final TimeZoneSettings timeZone;
  final DecodingSettings decoding;

  /// Indica se o tipo [oid] é decodificado diretamente pelo OID (time,
  /// timetz, inet, cidr, oid e tipos derivados, e arrays).
  static bool decodesByOid(int oid) =>
      _extendedOids.contains(oid) ||
      _arrayTypes.containsKey(oid) ||
      _oidLikeTypes.contains(oid) ||
      oid == _macaddrOid ||
      oid == _macaddr8Oid ||
      oid == _moneyOid;

  @override
  T? convert(Uint8List? input) {
    if (input == null) {
      return null;
    }
    // text, varchar, name, bpchar, "char", xml: no ByteData and no switch.
    // bpchar (char(n)) has no PostgreSQLDataType: it went through every
    // check of the less common types before being decoded.
    if (_isText) return encoding.decode(input) as T;

    final dataType = _dataType;

    final buffer =
        ByteData.view(input.buffer, input.offsetInBytes, input.lengthInBytes);

    switch (dataType) {
      case PostgreSQLDataType.name:
      case PostgreSQLDataType.text:
      case PostgreSQLDataType.varChar:
        return encoding.decode(input) as T;
      case PostgreSQLDataType.boolean:
        return (buffer.getInt8(0) != 0) as T;
      case PostgreSQLDataType.smallInteger:
        return buffer.getInt16(0) as T;
      case PostgreSQLDataType.serial:
      case PostgreSQLDataType.integer:
        return buffer.getInt32(0) as T;
      case PostgreSQLDataType.bigSerial:
      case PostgreSQLDataType.bigInteger:
        return buffer.getInt64(0) as T;
      case PostgreSQLDataType.real:
        return buffer.getFloat32(0) as T;
      case PostgreSQLDataType.double:
        return buffer.getFloat64(0) as T;
      case PostgreSQLDataType.date:
        final value = buffer.getInt32(0);
        //infinity || -infinity
        if (value == 2147483647 || value == -2147483648) {
          return null;
        }
        if (decoding.timestamp == TimestampDecoding.localWallClock) {
          final utc = DateTime.utc(2000).add(Duration(days: value));
          return DateTime(utc.year, utc.month, utc.day) as T;
        }
        if (timeZone.forceDecodeDateAsUTC) {
          return DateTime.utc(2000).add(Duration(days: value)) as T;
        }

        // https://github.com/dart-lang/sdk/issues/56312
        // ignore past timestamp transitions and use only current timestamp in local datetime        
        final nowDt = DateTime.now();
        var baseDt = DateTime(2000);
        if (baseDt.timeZoneOffset != nowDt.timeZoneOffset) {
          final difference = baseDt.timeZoneOffset - nowDt.timeZoneOffset;
          baseDt = baseDt.add(difference);
        }
        return baseDt.add(Duration(days: value)) as T;

      case PostgreSQLDataType.timestampWithoutTimezone:
        final value = buffer.getInt64(0);
        //infinity || -infinity
        if (value == 9223372036854775807 || value == -9223372036854775808) {
          return null;
        }
        if (decoding.timestamp == TimestampDecoding.localWallClock) {
          final utc = DateTime.utc(2000).add(Duration(microseconds: value));
          return DateTime(utc.year, utc.month, utc.day, utc.hour, utc.minute,
              utc.second, utc.millisecond, utc.microsecond) as T;
        }
        if (timeZone.forceDecodeTimestampAsUTC) {
          return DateTime.utc(2000).add(Duration(microseconds: value)) as T;
        }

        // https://github.com/dart-lang/sdk/issues/56312
        // ignore previous timestamp transitions and use only the current system timestamp in local date and time so that the behavior is correct on Windows and Linux
        final nowDt = DateTime.now();
        var baseDt = DateTime(2000);
        if (baseDt.timeZoneOffset != nowDt.timeZoneOffset) {
          final difference = baseDt.timeZoneOffset - nowDt.timeZoneOffset;
          baseDt = baseDt.add(difference);
        }
        return baseDt.add(Duration(microseconds: value)) as T;

      case PostgreSQLDataType.timestampWithTimezone:
        final value = buffer.getInt64(0);

        //infinity || -infinity
        if (value == 9223372036854775807 || value == -9223372036854775808) {
          return null;
        }
       
        final datetime = DateTime.utc(2000).add(Duration(microseconds: value));
        return convertTimestamptz(datetime, timeZone) as T;

      case PostgreSQLDataType.interval:
        {
          final microseconds = buffer.getInt64(0);
          final days = buffer.getInt32(8);
          final months = buffer.getInt32(12);
          if (decoding.interval == IntervalDecoding.pgInterval) {
            return PgInterval(
                months: months, days: days, microseconds: microseconds) as T;
          }
          if (decoding.interval == IntervalDecoding.text) {
            return PgBinaryText.interval(months, days, microseconds) as T;
          }
          if (days != 0 || months != 0) {
            final value = PgInterval(
                months: months, days: days, microseconds: microseconds);
            throw UnimplementedError(
                'The interval "$value" has months or days and cannot be '
                'decoded as a Duration. Use DecodingSettings(interval: '
                'IntervalDecoding.pgInterval) to decode it as a PgInterval.');
          }
          return Duration(microseconds: microseconds) as T;
        }

      case PostgreSQLDataType.numeric:
        if (decoding.numeric == NumericDecoding.decimal) {
          return decodePgDecimal(input) as T;
        }
        return _decodeNumeric(input) as T;

      case PostgreSQLDataType.jsonb:
        {
          // Removes version which is first character and currently always '1'
          final bytes = input.buffer
              .asUint8List(input.offsetInBytes + 1, input.lengthInBytes - 1);
          return json.decode(encoding.decode(bytes)) as T;
        }

      case PostgreSQLDataType.json:
        return json.decode(encoding.decode(input)) as T;

      case PostgreSQLDataType.byteArray:
        return input as T;

      case PostgreSQLDataType.uuid:
        {
          final buf = StringBuffer();
          for (var i = 0; i < buffer.lengthInBytes; i++) {
            final byteValue = buffer.getUint8(i);
            final upperByteValue = byteValue >> 4;
            final lowerByteValue = byteValue & 0x0f;

            final upperByteHex = _hex[upperByteValue];
            final lowerByteHex = _hex[lowerByteValue];
            buf.write(upperByteHex);
            buf.write(lowerByteHex);
            if (i == 3 || i == 5 || i == 7 || i == 9) {
              buf.writeCharCode(_dashUnit);
            }
          }

          return buf.toString() as T;
        }

      case PostgreSQLDataType.point:
        if (decoding.extendedTypes == ExtendedTypeDecoding.text) {
          return PgBinaryText.point(buffer.getFloat64(0), buffer.getFloat64(8))
              as T;
        }
        return PgPoint(buffer.getFloat64(0), buffer.getFloat64(8)) as T;

      // Arrays de tipos primitivos: leitura direta do buffer (caminho rápido).
      case PostgreSQLDataType.booleanArray:
        return _readPrimitiveArray<bool>(
            input, 16, (reader, _) => reader.readUint8() != 0) as T;
      case PostgreSQLDataType.integerArray:
        return _readPrimitiveArray<int>(
            input, 23, (reader, _) => reader.readInt32()) as T;
      case PostgreSQLDataType.bigIntegerArray:
        return _readPrimitiveArray<int>(
            input, 20, (reader, _) => reader.readInt64()) as T;
      case PostgreSQLDataType.textArray:
        return _readPrimitiveArray<String>(input, 25,
            (reader, length) => encoding.decode(reader.read(length))) as T;
      case PostgreSQLDataType.varCharArray:
        return _readPrimitiveArray<String>(input, 1043,
            (reader, length) => encoding.decode(reader.read(length))) as T;
      case PostgreSQLDataType.doubleArray:
        return _readPrimitiveArray<double>(
            input, 701, (reader, _) => reader.readFloat64()) as T;
      case PostgreSQLDataType.jsonbArray:
        return _readPrimitiveArray<dynamic>(input, 3802, (reader, length) {
          reader.read(1);
          return json.decode(encoding.decode(reader.read(length - 1)));
        }) as T;

      default:
        // In its own method: the code for the less common types made
        // `convert` (run for every value) large enough to slow the common
        // types down (about 3% on a 100-row result).
        return _decodeOther(input, buffer) as T?;
    }
  }

  /// The types without a [PostgreSQLDataType] entry.
  @pragma('vm:never-inline')
  Object? _decodeOther(Uint8List input, ByteData buffer) {
    // oid e tipos derivados (regclass, regtype, xid...): inteiros sem
    // sinal de 4 bytes. Antes viravam uma String com os bytes.
    if (_oidLikeTypes.contains(typeCode)) {
      return buffer.getUint32(0);
    }
    // macaddr e macaddr8: o texto canônico do PostgreSQL
    // ('08:00:2b:01:02:03'). Antes viravam uma String com os bytes.
    if (typeCode == _macaddrOid || typeCode == _macaddr8Oid) {
      return input
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(':');
    }
    // money: int64 na menor unidade da moeda. Devolvido como texto
    // decimal exato com 2 casas (o padrão do lc_monetary em
    // praticamente todos os locales), sem o símbolo da moeda. Antes
    // vinham os bytes.
    if (typeCode == _moneyOid) {
      return _decodeMoney(buffer.getInt64(0));
    }

    // Tipos sem entrada em PostgreSQLDataType (time, timetz, inet,
    // cidr) e os demais arrays.
    final extended = _decodeByOid(input);
    if (!identical(extended, _notHandled)) return extended;

    // Geometric types, bit strings, tsvector, ranges and their
    // arrays: the server's text. They came back as their bytes or, when
    // the bytes happened to be valid UTF-8, as garbage ('ab' for the
    // tsvector 'a' 'b', '' for the int4range [1,5)).
    if (PgBinaryText.formats(typeCode)) {
      final text = PgBinaryText.scalar(typeCode, input);
      if (text != null) return text;
      final list = PgBinaryText.array(typeCode, input);
      if (list != null) return list;
    }
    // Arrays of user-defined types (enum[]): the array literal
    // ('{ok,sad}'). They came back as bytes.
    final literal = PgBinaryText.arrayLiteral(input, encoding);
    if (literal != null) return literal;

    // We'll try and decode this as a utf8 string and return that
    // for many internal types, this is valid. If it fails,
    // we just return the bytes and let the caller figure out what to
    // do with it.
    try {
      return encoding.decode(input);
    } catch (_) {
      return input;
    }
  }

  /// Decodifica os tipos identificados diretamente pelo OID: `time`,
  /// `timetz`, `inet`, `cidr` e os arrays. Devolve [_notHandled] para os
  /// demais tipos.
  Object? _decodeByOid(Uint8List input) {
    switch (typeCode) {
      case _timeOid:
      case _timeTzOid:
      case _inetOid:
      case _cidrOid:
        return _decodeExtended(input);
    }
    if (typeCode == _numericArrayOid &&
        decoding.numeric == NumericDecoding.decimal) {
      return _readArray<PgDecimal>(input, 1700);
    }
    final array = _arrayTypes[typeCode];
    if (array == null) return _notHandled;
    if (_extendedOids.contains(array.elementOid) &&
        decoding.extendedTypes == ExtendedTypeDecoding.bytes) {
      return input;
    }
    // Elements decoded as text: a List<String>, not a List<Object>.
    final element = array.elementOid;
    if ((decoding.extendedTypes == ExtendedTypeDecoding.text &&
            (_extendedOids.contains(element) || element == 600)) ||
        (decoding.interval == IntervalDecoding.text && element == 1186)) {
      return _readArray<String>(input, element);
    }
    return array.read(this, input);
  }

  Object _decodeExtended(Uint8List input) {
    if (decoding.extendedTypes == ExtendedTypeDecoding.bytes) return input;
    final buffer =
        ByteData.view(input.buffer, input.offsetInBytes, input.lengthInBytes);
    final Object value;
    switch (typeCode) {
      case _timeOid:
        value = PgTime.fromMicroseconds(buffer.getInt64(0));
        break;
      case _timeTzOid:
        // O PostgreSQL envia o fuso em segundos a oeste de UTC.
        value = PgTimeTz(
            PgTime.fromMicroseconds(buffer.getInt64(0)), -buffer.getInt32(8));
        break;
      default: // inet e cidr
        final bits = buffer.getUint8(1);
        final isCidr = buffer.getUint8(2) != 0;
        final length = buffer.getUint8(3);
        final address = InternetAddress.fromRawAddress(
            Uint8List.fromList(input.sublist(4, 4 + length)));
        value = PgInet(address, bits, isCidr: isCidr);
    }
    return decoding.extendedTypes == ExtendedTypeDecoding.text
        ? value.toString()
        : value;
  }

  /// Lê um array unidimensional de um tipo primitivo diretamente do buffer,
  /// sem criar um decodificador por elemento. Arrays com mais de uma
  /// dimensão usam o leitor genérico ([_readArray]).
  Object _readPrimitiveArray<V>(Uint8List data, int elementOid,
      V Function(ByteDataReader reader, int length) element) {
    final reader = ByteDataReader()..add(data);
    final dimensions = reader.readInt32();
    if (dimensions != 1) {
      if (dimensions == 0) return decoding.nullableArrays ? <V?>[] : <V>[];
      return _readArray<V>(data, elementOid);
    }
    reader.readInt32(); // flags (indica se há NULL)
    reader.readInt32(); // OID do elemento
    final count = reader.readInt32();
    reader.readInt32(); // limite inferior

    if (decoding.nullableArrays) {
      return <V?>[
        for (var i = 0; i < count; i++)
          switch (reader.readInt32()) {
            final length when length < 0 => null,
            final length => element(reader, length),
          },
      ];
    }
    final values = <V>[];
    for (var i = 0; i < count; i++) {
      final length = reader.readInt32();
      if (length < 0) {
        // Há NULL: continua numa lista que aceita null.
        final nullable = <V?>[...values, null];
        for (i++; i < count; i++) {
          final len = reader.readInt32();
          nullable.add(len < 0 ? null : element(reader, len));
        }
        return nullable;
      }
      values.add(element(reader, length));
    }
    return values;
  }

  /// Lê um array no formato binário do PostgreSQL (`array_send`).
  ///
  /// Elementos NULL viram `null`. Se o array não tem NULL, a lista é do tipo
  /// `List<V>`; se tem, `List<V?>`. Arrays com mais de uma dimensão viram
  /// listas aninhadas.
  Object _readArray<V>(Uint8List data, int elementOid) {
    final elementDecoder = PostgresBinaryDecoder<Object>(
        elementOid, encoding, timeZone,
        decoding: decoding);
    final reader = ByteDataReader()..add(data);
    final dimensions = reader.readInt32();
    reader.readInt32(); // flags (indica se há NULL)
    reader.readInt32(); // OID do elemento
    if (dimensions == 0) return decoding.nullableArrays ? <V?>[] : <V>[];
    final sizes = <int>[];
    for (var i = 0; i < dimensions; i++) {
      sizes.add(reader.readInt32());
      reader.readInt32(); // limite inferior
    }

    Object build(int level) {
      final count = sizes[level];
      if (level < dimensions - 1) {
        return [for (var i = 0; i < count; i++) build(level + 1)];
      }
      final values = List<V?>.filled(count, null);
      var hasNull = false;
      for (var i = 0; i < count; i++) {
        final length = reader.readInt32();
        if (length < 0) {
          hasNull = true;
          continue;
        }
        final value = elementDecoder.convert(reader.read(length));
        if (value == null) {
          hasNull = true;
        } else {
          values[i] = value as V;
        }
      }
      return hasNull || decoding.nullableArrays ? values : List<V>.from(values);
    }

    return build(0);
  }

  /// See: https://github.com/postgres/postgres/blob/master/src/include/catalog/pg_type.dat
  static final Map<int, PostgreSQLDataType> typeMap = {
    16: PostgreSQLDataType.boolean,
    17: PostgreSQLDataType.byteArray,
    19: PostgreSQLDataType.name,
    20: PostgreSQLDataType.bigInteger,
    21: PostgreSQLDataType.smallInteger,
    23: PostgreSQLDataType.integer,
    25: PostgreSQLDataType.text,
    114: PostgreSQLDataType.json,
    600: PostgreSQLDataType.point,
    700: PostgreSQLDataType.real,
    701: PostgreSQLDataType.double,
    1000: PostgreSQLDataType.booleanArray,
    1007: PostgreSQLDataType.integerArray,
    1016: PostgreSQLDataType.bigIntegerArray,
    1009: PostgreSQLDataType.textArray,
    1015: PostgreSQLDataType.varCharArray,
    1043: PostgreSQLDataType.varChar,
    1022: PostgreSQLDataType.doubleArray,
    1082: PostgreSQLDataType.date,
    1114: PostgreSQLDataType.timestampWithoutTimezone,
    1184: PostgreSQLDataType.timestampWithTimezone,
    1186: PostgreSQLDataType.interval,
    1700: PostgreSQLDataType.numeric,
    2950: PostgreSQLDataType.uuid,
    3802: PostgreSQLDataType.jsonb,
    3807: PostgreSQLDataType.jsonbArray,
  };

  /// Decode numeric / decimal to String without loosing precision.
  /// See encoding: https://github.com/postgres/postgres/blob/0e39a608ed5545cc6b9d538ac937c3c1ee8cdc36/src/backend/utils/adt/numeric.c#L305
  /// See implementation: https://github.com/charmander/pg-numeric/blob/0c310eeb11dc680dffb7747821e61d542831108b/index.js#L13
  static String _decodeNumeric(Uint8List value) {
    final reader = ByteDataReader()..add(value);
    final nDigits =
        reader.readInt16(); // non-zero digits, data buffer length = 2 * nDigits
    var weight = reader.readInt16(); // weight of first digit
    final signByte =
        reader.readUint16(); // NUMERIC_POS, NEG, NAN, PINF, or NINF
    final dScale = reader.readInt16(); // display scale
    if (signByte == 0xc000) return 'NaN';
    // PostgreSQL 14+: antes eram decodificados como '0'.
    if (signByte == 0xd000) return 'Infinity';
    if (signByte == 0xf000) return '-Infinity';
    final sign = signByte == 0x4000 ? '-' : '';
    var intPart = '';
    var fractPart = '';

    final fractOmitted = -(weight + 1);
    if (fractOmitted > 0) {
      // If value < 0, the leading zeros in fractional part were omitted.
      fractPart += '0000' * fractOmitted;
    }

    for (var i = 0; i < nDigits; i++) {
      if (weight >= 0) {
        intPart += reader.readInt16().toString().padLeft(4, '0');
      } else {
        fractPart += reader.readInt16().toString().padLeft(4, '0');
      }
      weight--;
    }

    if (weight >= 0) {
      // Trailing zeros were omitted
      intPart += '0000' * (weight + 1);
    }

    var result = intPart.replaceAll(_leadingZerosRegExp, '');
    if (result.isEmpty) {
      // Show at least 0, if no int value is given (antes '-0.5' virava
      // '-.5', porque o sinal já estava em result).
      result = '0';
    }
    result = '$sign$result';
    if (dScale > 0) {
      // Only add fractional digits, if dScale allows
      result += '.${fractPart.padRight(dScale, '0').substring(0, dScale)}';
    }
    return result;
  }
}

const _notHandled = Object();

/// oid, regproc, xid, cid, regprocedure, regoper, regoperator, regclass,
/// regtype, regconfig, regdictionary, regnamespace, regrole e regcollation.
/// Text types: text, varchar, name, bpchar, "char", xml.
const _textOids = {25, 1043, 19, 1042, 18, 142};

const _macaddrOid = 829;
const _macaddr8Oid = 774;
const _moneyOid = 790;

String _decodeMoney(int value) {
  final amount = BigInt.from(value);
  final abs = amount.abs();
  final cents = (abs % BigInt.from(100)).toString().padLeft(2, '0');
  return '${amount.isNegative ? '-' : ''}${abs ~/ BigInt.from(100)}.$cents';
}

const _oidLikeTypes = {
  26, 24, 28, 29, 2202, 2203, 2204, 2205, 2206, 3734, 3769, 4089, 4096, 4191
};

const _numericArrayOid = 1231;

const _timeOid = 1083;
const _timeTzOid = 1266;
const _inetOid = 869;
const _cidrOid = 650;
const _extendedOids = {_timeOid, _timeTzOid, _inetOid, _cidrOid};

class _ArrayType<V> {
  final int elementOid;
  const _ArrayType(this.elementOid);

  Object read(PostgresBinaryDecoder decoder, Uint8List input) =>
      decoder._readArray<V>(input, elementOid);
}

/// Arrays suportados: OID do array -> OID e tipo Dart do elemento.
const Map<int, _ArrayType> _arrayTypes = {
  1000: _ArrayType<bool>(16), // bool[]
  1001: _ArrayType<Uint8List>(17), // bytea[]
  1003: _ArrayType<String>(19), // name[]
  1005: _ArrayType<int>(21), // int2[]
  1007: _ArrayType<int>(23), // int4[]
  1016: _ArrayType<int>(20), // int8[]
  1009: _ArrayType<String>(25), // text[]
  1014: _ArrayType<String>(1042), // bpchar[]
  1015: _ArrayType<String>(1043), // varchar[]
  1021: _ArrayType<double>(700), // float4[]
  1022: _ArrayType<double>(701), // float8[]
  1017: _ArrayType<PgPoint>(600), // point[]
  1115: _ArrayType<DateTime>(1114), // timestamp[]
  1182: _ArrayType<DateTime>(1082), // date[]
  1185: _ArrayType<DateTime>(1184), // timestamptz[]
  1187: _ArrayType<Object>(1186), // interval[] (Duration ou PgInterval)
  1231: _ArrayType<String>(1700), // numeric[]
  2951: _ArrayType<String>(2950), // uuid[]
  199: _ArrayType<dynamic>(114), // json[]
  3807: _ArrayType<dynamic>(3802), // jsonb[]
  1183: _ArrayType<Object>(_timeOid), // time[]
  1270: _ArrayType<Object>(_timeTzOid), // timetz[]
  1041: _ArrayType<Object>(_inetOid), // inet[]
  651: _ArrayType<Object>(_cidrOid), // cidr[]
  1028: _ArrayType<int>(26), // oid[]
  22: _ArrayType<int>(21), // int2vector (pg_index.indkey)
  30: _ArrayType<int>(26), // oidvector
  1040: _ArrayType<String>(_macaddrOid), // macaddr[]
  775: _ArrayType<String>(_macaddr8Oid), // macaddr8[]
  791: _ArrayType<String>(_moneyOid), // money[]
};
