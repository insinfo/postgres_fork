import 'dart:io' show InternetAddress, InternetAddressType;
import 'dart:typed_data';

const int _usecsPerSec = 1000000;
const int _usecsPerMinute = 60 * _usecsPerSec;
const int _usecsPerHour = 60 * _usecsPerMinute;
const int _usecsPerDay = 24 * _usecsPerHour;

String _two(int n) => n.toString().padLeft(2, '0');

/// Segundos com a fração (sem zeros à direita), como `AppendSeconds` do
/// PostgreSQL com `fillzeros`.
String _seconds(int seconds, int fraction) {
  final buf = StringBuffer(_two(seconds));
  if (fraction != 0) {
    var f = fraction.toString().padLeft(6, '0');
    while (f.endsWith('0')) {
      f = f.substring(0, f.length - 1);
    }
    buf
      ..write('.')
      ..write(f);
  }
  return buf.toString();
}

/// Valor do tipo `interval` do PostgreSQL, sem perda de informação.
///
/// O PostgreSQL guarda meses, dias e microssegundos separadamente: um mês
/// não tem duração fixa e um dia pode ter 23 ou 25 horas quando há mudança de
/// horário de verão, por isso esses valores não cabem num [Duration].
///
/// Usado ao decodificar `interval` com
/// `DecodingSettings(interval: IntervalDecoding.pgInterval)` e aceito como
/// parâmetro de consultas.
class PgInterval implements Comparable<PgInterval>, PostgresTextEncodable {
  /// Meses (12 meses = 1 ano).
  final int months;

  /// Dias.
  final int days;

  /// Parte de tempo, em microssegundos.
  final int microseconds;

  const PgInterval({this.months = 0, this.days = 0, this.microseconds = 0});

  /// Cria a partir de um [Duration] (apenas a parte de tempo).
  PgInterval.fromDuration(Duration duration)
      : months = 0,
        days = 0,
        microseconds = duration.inMicroseconds;

  /// Indica se o valor tem apenas a parte de tempo (sem meses nem dias).
  bool get isTimeOnly => months == 0 && days == 0;

  /// Converte para [Duration], contando cada dia como 24 horas.
  ///
  /// Lança [StateError] se houver meses, que não têm duração fixa.
  Duration toDuration() {
    if (months != 0) {
      throw StateError('$this has months and cannot be converted to Duration');
    }
    return Duration(days: days, microseconds: microseconds);
  }

  /// Compara como o PostgreSQL: meses valem 30 dias e dias valem 24 horas.
  @override
  int compareTo(PgInterval other) =>
      _comparable.compareTo(other._comparable);

  BigInt get _comparable =>
      BigInt.from(months) * BigInt.from(30 * _usecsPerDay) +
      BigInt.from(days) * BigInt.from(_usecsPerDay) +
      BigInt.from(microseconds);

  @override
  bool operator ==(Object other) =>
      other is PgInterval &&
      other.months == months &&
      other.days == days &&
      other.microseconds == microseconds;

  @override
  String toPostgresText() => toString();

  @override
  String get postgresTypeName => 'interval';

  @override
  int get hashCode => Object.hash(months, days, microseconds);

  /// Texto no formato de saída padrão do PostgreSQL (IntervalStyle
  /// `postgres`), por exemplo `1 year 2 mons 3 days 04:05:06.789`.
  @override
  String toString() {
    final years = months ~/ 12;
    final mons = months.remainder(12);
    var time = microseconds;
    final hour = time ~/ _usecsPerHour;
    time -= hour * _usecsPerHour;
    final min = time ~/ _usecsPerMinute;
    time -= min * _usecsPerMinute;
    final sec = time ~/ _usecsPerSec;
    final fsec = time - sec * _usecsPerSec;

    final buf = StringBuffer();
    var isBefore = false;
    var isZero = true;
    void addPart(int value, String units) {
      if (value == 0) return;
      buf
        ..write(isZero ? '' : ' ')
        ..write(isBefore && value > 0 ? '+' : '')
        ..write(value)
        ..write(' ')
        ..write(units)
        ..write(value != 1 ? 's' : '');
      isBefore = value < 0;
      isZero = false;
    }

    addPart(years, 'year');
    addPart(mons, 'mon');
    addPart(days, 'day');
    if (isZero || hour != 0 || min != 0 || sec != 0 || fsec != 0) {
      final minus = hour < 0 || min < 0 || sec < 0 || fsec < 0;
      buf
        ..write(isZero ? '' : ' ')
        ..write(minus ? '-' : (isBefore ? '+' : ''))
        ..write(_two(hour.abs()))
        ..write(':')
        ..write(_two(min.abs()))
        ..write(':')
        ..write(_seconds(sec.abs(), fsec.abs()));
    }
    return buf.toString();
  }
}

/// Valor do tipo `time` (hora do dia, sem fuso), com precisão de
/// microssegundos. Aceita de `00:00:00` a `24:00:00`.
class PgTime implements Comparable<PgTime>, PostgresTextEncodable {
  /// Microssegundos desde a meia-noite.
  final int microsecondsSinceMidnight;

  const PgTime.fromMicroseconds(this.microsecondsSinceMidnight);

  PgTime(int hour, [int minute = 0, int second = 0, int microsecond = 0])
      : microsecondsSinceMidnight = hour * _usecsPerHour +
            minute * _usecsPerMinute +
            second * _usecsPerSec +
            microsecond;

  int get hour => microsecondsSinceMidnight ~/ _usecsPerHour;
  int get minute =>
      (microsecondsSinceMidnight % _usecsPerHour) ~/ _usecsPerMinute;
  int get second =>
      (microsecondsSinceMidnight % _usecsPerMinute) ~/ _usecsPerSec;

  /// Fração de segundo, em microssegundos.
  int get microsecond => microsecondsSinceMidnight % _usecsPerSec;

  /// Tempo desde a meia-noite.
  Duration toDuration() => Duration(microseconds: microsecondsSinceMidnight);

  @override
  int compareTo(PgTime other) =>
      microsecondsSinceMidnight.compareTo(other.microsecondsSinceMidnight);

  @override
  bool operator ==(Object other) =>
      other is PgTime &&
      other.microsecondsSinceMidnight == microsecondsSinceMidnight;

  @override
  String toPostgresText() => toString();

  @override
  String get postgresTypeName => 'time';

  @override
  int get hashCode => microsecondsSinceMidnight.hashCode;

  /// Texto no formato do PostgreSQL, por exemplo `13:45:10.5`.
  @override
  String toString() =>
      '${_two(hour)}:${_two(minute)}:${_seconds(second, microsecond)}';
}

/// Valor do tipo `timetz` (hora do dia com deslocamento de fuso).
class PgTimeTz implements PostgresTextEncodable {
  /// Hora local.
  final PgTime time;

  /// Deslocamento em relação a UTC, em segundos (positivo a leste).
  final int offsetSeconds;

  const PgTimeTz(this.time, this.offsetSeconds);

  /// Deslocamento em relação a UTC.
  Duration get offset => Duration(seconds: offsetSeconds);

  @override
  bool operator ==(Object other) =>
      other is PgTimeTz &&
      other.time == time &&
      other.offsetSeconds == offsetSeconds;

  @override
  String toPostgresText() => toString();

  @override
  String get postgresTypeName => 'timetz';

  @override
  int get hashCode => Object.hash(time, offsetSeconds);

  /// Texto no formato do PostgreSQL, por exemplo `13:45:10.5-03`.
  @override
  String toString() {
    final sign = offsetSeconds < 0 ? '-' : '+';
    final abs = offsetSeconds.abs();
    final hours = abs ~/ 3600;
    final minutes = (abs % 3600) ~/ 60;
    final seconds = abs % 60;
    final buf = StringBuffer('$time$sign${_two(hours)}');
    if (minutes != 0 || seconds != 0) buf.write(':${_two(minutes)}');
    if (seconds != 0) buf.write(':${_two(seconds)}');
    return buf.toString();
  }
}

/// Valor dos tipos `inet` e `cidr`: endereço IPv4/IPv6 com tamanho de
/// prefixo (máscara).
class PgInet implements PostgresTextEncodable {
  /// Endereço.
  final InternetAddress address;

  /// Tamanho do prefixo, em bits (32/128 = endereço de host).
  final int prefixLength;

  /// Indica se o valor é do tipo `cidr` (rede) em vez de `inet`.
  final bool isCidr;

  PgInet(this.address, this.prefixLength, {this.isCidr = false});

  /// Quantidade máxima de bits do endereço (32 ou 128).
  int get maxPrefixLength =>
      address.type == InternetAddressType.IPv4 ? 32 : 128;

  @override
  bool operator ==(Object other) =>
      other is PgInet &&
      other.address == address &&
      other.prefixLength == prefixLength &&
      other.isCidr == isCidr;

  @override
  String toPostgresText() => toString();

  @override
  String get postgresTypeName => isCidr ? 'cidr' : 'inet';

  @override
  int get hashCode => Object.hash(address, prefixLength, isCidr);

  /// Texto no formato do PostgreSQL (`network_out`): `inet` omite o prefixo
  /// quando ele é o máximo; `cidr` sempre o mostra.
  @override
  String toString() {
    final raw = address.rawAddress;
    final text = raw.length == 4 ? raw.join('.') : _ipv6ToString(raw);
    if (!isCidr && prefixLength == maxPrefixLength) return text;
    return '$text/$prefixLength';
  }
}

/// Formata um IPv6 como `inet_net_ntop_ipv6` do PostgreSQL: comprime a
/// maior sequência de zeros (com pelo menos 2 palavras) e usa notação IPv4
/// para endereços IPv4 encapsulados.
String _ipv6ToString(Uint8List src) {
  final words = List<int>.generate(8, (i) => (src[2 * i] << 8) | src[2 * i + 1]);
  var bestBase = -1, bestLen = 0, curBase = -1, curLen = 0;
  for (var i = 0; i < 8; i++) {
    if (words[i] == 0) {
      if (curBase == -1) {
        curBase = i;
        curLen = 1;
      } else {
        curLen++;
      }
    } else if (curBase != -1) {
      if (bestBase == -1 || curLen > bestLen) {
        bestBase = curBase;
        bestLen = curLen;
      }
      curBase = -1;
    }
  }
  if (curBase != -1 && (bestBase == -1 || curLen > bestLen)) {
    bestBase = curBase;
    bestLen = curLen;
  }
  if (bestBase != -1 && bestLen < 2) bestBase = -1;

  final buf = StringBuffer();
  for (var i = 0; i < 8; i++) {
    if (bestBase != -1 && i >= bestBase && i < bestBase + bestLen) {
      if (i == bestBase) buf.write(':');
      continue;
    }
    if (i != 0) buf.write(':');
    if (i == 6 &&
        bestBase == 0 &&
        (bestLen == 6 ||
            (bestLen == 7 && words[7] != 0x0001) ||
            (bestLen == 5 && words[5] == 0xffff))) {
      buf.write(src.sublist(12, 16).join('.'));
      return buf.toString();
    }
    buf.write(words[i].toRadixString(16));
  }
  if (bestBase != -1 && bestBase + bestLen == 8) buf.write(':');
  return buf.toString();
}

/// Valor que sabe se representar no formato de texto de entrada do
/// PostgreSQL, para ser usado como parâmetro de consulta.
///
/// Implemente esta interface em tipos da aplicação para usá-los diretamente
/// como parâmetros (sem tipo explícito) ou em consultas com substituição no
/// SQL. [PgInterval], [PgTime], [PgTimeTz] e [PgInet] a implementam.
abstract interface class PostgresTextEncodable {
  /// Texto aceito pela função de entrada do tipo no PostgreSQL.
  String toPostgresText();

  /// Nome do tipo usado no cast quando o valor é inserido no SQL (por exemplo
  /// `interval`), ou `null` para não fazer cast.
  String? get postgresTypeName;
}
