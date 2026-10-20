// Port para Dart do compilador de fusos horários `zic` da IANA
// (https://www.iana.org/time-zones, tzcode 2026e, zic.c).
//
// zic.c está em domínio público ("This file is in the public domain, so
// clarified as of 2006-07-17 by Arthur David Olson."), assim como este port.
//
// Lê arquivos-fonte do tzdata (linhas Rule, Zone e Link) e gera os arquivos
// binários TZif (RFC 9636) exatamente como o `zic` em C, incluindo a string TZ
// do rodapé e os modos `-b fat` e `-b slim`. A equivalência byte a byte é
// verificada por dependency_parity/tool/zic_parity.dart.
//
// Não implementado (não usado para gerar o banco do driver): segundos
// intercalares (-L), -l/-p (links de localtime/posixrules) e opções de
// permissão/dono de arquivos.

import 'dart:typed_data';

/// Erro fatal do zic (equivalente a `exit(EXIT_FAILURE)` no código C).
class ZicException implements Exception {
  final String message;
  ZicException(this.message);
  @override
  String toString() => 'zic: $message';
}

// ---------------------------------------------------------------------------
// Constantes (private.h / tzfile.h / zic.c)
// ---------------------------------------------------------------------------

const int _zicMin = -0x8000000000000000; // INT_FAST64_MIN
const int _zicMax = 0x7FFFFFFFFFFFFFFF; // INT_FAST64_MAX
const int _two31Minus1 = 2147483647;
const int _zic32Min = -1 - _two31Minus1;
const int _zic32Max = _two31Minus1;

/// Valores mínimo e máximo representáveis num TZif (TIME_T_BITS_IN_FILE = 64).
const int _minTime = _zicMin;
const int _maxTime = _zicMax;

const int _year32BitMin = 1901;
const int _year32BitMax = 2038;

const int _secsPerMin = 60;
const int _minsPerHour = 60;
const int _hoursPerDay = 24;
const int _daysPerWeek = 7;
const int _daysPerNYear = 365;
const int _secsPerHour = _secsPerMin * _minsPerHour;
const int _secsPerDay = _secsPerHour * _hoursPerDay;
const int _yearsPerRepeat = 400;
const int _daysPerRepeat = 400 * 365 + 100 - 4 + 1;
const int _yearsOfObservations = _yearsPerRepeat + 2;
const int _epochYear = 1970;
const int _epochWday = 4; // TM_THURSDAY

const int _tzMaxTypes = 256;
const int _tzMaxChars = 256;
const int _tzMaxTimes = 2000;

const int _tmJanuary = 0;
const int _tmFebruary = 1;
const int _tmDecember = 11;

const String _grandparented =
    'Local time zone must be set--see zic manual page';

/// ZIC_MAX_ABBR_LEN_WO_WARN
const int _zicMaxAbbrLenWoWarn = 6;

/// Limite do tamanho de uma expansão de %z ("+995959").
const int _percentZLenBound = 7;

const List<List<int>> _lenMonths = [
  [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31],
  [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31],
];

bool _isLeap(int y) =>
    y.remainder(4) == 0 && (y.remainder(100) != 0 || y.remainder(400) == 0);

int _yearDays(int y) => _daysPerNYear + (_isLeap(y) ? 1 : 0);

// r_dycode
const int _dcDom = 0;
const int _dcDowGeq = 1;
const int _dcDowLeq = 2;

// Year synonyms.
const int _yrMinimum = 0;
const int _yrMaximum = 1;
const int _yrOnly = 2;

class _Lookup {
  final String word;
  final int value;
  const _Lookup(this.word, this.value);
}

const _lcRule = 0;
const _lcZone = 1;
const _lcLink = 2;

const _ziLineCodes = [
  _Lookup('Rule', _lcRule),
  _Lookup('Zone', _lcZone),
  _Lookup('Link', _lcLink),
];

const _monNames = [
  _Lookup('January', 0),
  _Lookup('February', 1),
  _Lookup('March', 2),
  _Lookup('April', 3),
  _Lookup('May', 4),
  _Lookup('June', 5),
  _Lookup('July', 6),
  _Lookup('August', 7),
  _Lookup('September', 8),
  _Lookup('October', 9),
  _Lookup('November', 10),
  _Lookup('December', 11),
];

const _wdayNames = [
  _Lookup('Sunday', 0),
  _Lookup('Monday', 1),
  _Lookup('Tuesday', 2),
  _Lookup('Wednesday', 3),
  _Lookup('Thursday', 4),
  _Lookup('Friday', 5),
  _Lookup('Saturday', 6),
];

const _lasts = [
  _Lookup('last-Sunday', 0),
  _Lookup('last-Monday', 1),
  _Lookup('last-Tuesday', 2),
  _Lookup('last-Wednesday', 3),
  _Lookup('last-Thursday', 4),
  _Lookup('last-Friday', 5),
  _Lookup('last-Saturday', 6),
];

const _beginYears = [_Lookup('minimum', _yrMinimum)];

const _endYears = [
  _Lookup('maximum', _yrMaximum),
  _Lookup('only', _yrOnly),
];

// Campos das linhas.
const _zfName = 1;
const _zfStdoff = 2;
const _zfRule = 3;
const _zfFormat = 4;
const _zfTilYear = 5;
const _zfTilMonth = 6;
const _zfTilDay = 7;
const _zfTilTime = 8;
const _zoneMaxFields = 9;
const _zoneMinFields = _zfTilYear;

const _zfcStdoff = 0;
const _zfcRule = 1;
const _zfcFormat = 2;
const _zfcTilYear = 3;
const _zfcTilMonth = 4;
const _zfcTilDay = 5;
const _zfcTilTime = 6;
const _zonecMaxFields = 7;
const _zonecMinFields = _zfcTilYear;

const _rfName = 1;
const _rfLoYear = 2;
const _rfHiYear = 3;
const _rfCommand = 4;
const _rfMonth = 5;
const _rfDay = 6;
const _rfTod = 7;
const _rfSave = 8;
const _rfAbbrvar = 9;
const _ruleFields = 10;

const _lfTarget = 1;
const _lfLinkname = 2;
const _linkFields = 3;

/// MAX_FIELDS (o maior entre Rule, Link, Leap e Expires).
const _maxFields = 10;

// ---------------------------------------------------------------------------
// Estruturas
// ---------------------------------------------------------------------------

class _Rule {
  int filenum = 0;
  int linenum = 0;
  String name = '';

  int loyear = 0;
  int hiyear = 0;
  bool hiwasnum = false;

  int month = 0;

  int dycode = 0;
  int dayofmonth = 0;
  int wday = 0;

  int tod = 0;
  bool todisstd = false;
  bool todisut = false;
  bool isdst = false;
  int save = 0;
  String? abbrvar;

  bool todo = false;
  int temp = 0;

  _Rule();

  _Rule copy() => _Rule()
    ..filenum = filenum
    ..linenum = linenum
    ..name = name
    ..loyear = loyear
    ..hiyear = hiyear
    ..hiwasnum = hiwasnum
    ..month = month
    ..dycode = dycode
    ..dayofmonth = dayofmonth
    ..wday = wday
    ..tod = tod
    ..todisstd = todisstd
    ..todisut = todisut
    ..isdst = isdst
    ..save = save
    ..abbrvar = abbrvar;
}

class _Zone {
  int filenum = 0;
  int linenum = 0;

  String? name;
  int stdoff = 0;
  String rule = '';
  String format = '';

  /// '\0' (0), 's' ou 'z'.
  int formatSpecifier = 0;

  bool isdst = false;
  int save = 0;

  List<_Rule> rules = const [];

  _Rule untilrule = _Rule();
  int untiltime = 0;
}

class _Link {
  final int filenum;
  final int linenum;
  final String target;
  final String linkname;
  _Link(this.filenum, this.linenum, this.target, this.linkname);
}

class _AtType {
  int at;
  bool dontmerge;
  int type;
  _AtType(this.at, this.dontmerge, this.type);
}

class _TimeRange {
  int defaulttype = 0;
  int base = 0;
  int count = 0;
  int leapbase = 0;
  int leapcount = 0;
  bool leapexpiry = false;

  _TimeRange copy() => _TimeRange()
    ..defaulttype = defaulttype
    ..base = base
    ..count = count
    ..leapbase = leapbase
    ..leapcount = leapcount
    ..leapexpiry = leapexpiry;
}

// ---------------------------------------------------------------------------
// Funções auxiliares de caracteres (locale C)
// ---------------------------------------------------------------------------

bool _isDigit(int c) => 0x30 <= c && c <= 0x39;

bool _isSpace(int c) =>
    c == 0x20 || c == 0x0C || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0B;

bool _isAlpha(int c) => (0x41 <= c && c <= 0x5A) || (0x61 <= c && c <= 0x7A);

int _lowerit(int c) => (0x41 <= c && c <= 0x5A) ? c + 0x20 : c;

/// Acesso estilo C a uma string: índice além do fim devolve 0 (NUL).
int _ch(String s, int i) => i < s.length ? s.codeUnitAt(i) : 0;

bool _ciequal(String a, String b) {
  var i = 0;
  while (_lowerit(_ch(a, i)) == _lowerit(_ch(b, i))) {
    if (_ch(a, i) == 0) return true;
    i++;
  }
  return false;
}

bool _ciprefix(String abbr, String word) {
  var i = 0;
  while (true) {
    if (_ch(abbr, i) == 0) return true;
    if (_lowerit(_ch(abbr, i)) != _lowerit(_ch(word, i))) return false;
    i++;
  }
}

// ---------------------------------------------------------------------------
// O compilador
// ---------------------------------------------------------------------------

/// Compilador de arquivos-fonte do tzdata para TZif.
///
/// ```dart
/// final zic = Zic(bloat: true);
/// zic.addSource('africa', File('africa').readAsStringSync());
/// final files = zic.compile(); // nome -> bytes TZif
/// ```
class Zic {
  /// Equivale a `-b fat` (true) ou `-b slim` (false, padrão do zic atual).
  final bool bloat;

  /// Equivale a `-v`: emite também os avisos opcionais.
  final bool noise;

  /// `-r` (limite inferior); por padrão, o mínimo representável.
  final int loTime;

  /// `-r` (limite superior); por padrão, o máximo representável.
  final int hiTime;

  /// `-R`; por padrão, o maior entre o mínimo representável e [loTime].
  final int redundantTime;

  /// Erros reportados (o zic em C termina com falha se houver algum).
  final List<String> errors = [];

  /// Avisos reportados.
  final List<String> warnings = [];

  final List<String> _fileNames = [];

  final List<_Rule> _rules = [];
  final List<_Zone> _zones = [];
  final List<_Link> _links = [];

  int _maxAbbrvarLen = _percentZLenBound;
  int _maxFormatLen = 0;

  // Estado de diagnóstico.
  int _filenum = 0;
  int _linenum = 0;
  int _rfilenum = 0;
  int _rlinenum = 0;

  // Estado de outzone/writezone.
  int _maxYear = 0;
  int _minYear = 0;
  List<_AtType> _attypes = [];
  int _typecnt = 0;
  int _unspecifiedtype = 0;
  final List<int> _utoffs = List.filled(_tzMaxTypes, 0);
  final List<int> _isdsts = List.filled(_tzMaxTypes, 0);
  final List<int> _desigidx = List.filled(_tzMaxTypes, 0);
  final List<bool> _ttisstds = List.filled(_tzMaxTypes, false);
  final List<bool> _ttisuts = List.filled(_tzMaxTypes, false);
  final List<int> _chars = List.filled(_tzMaxChars, 0);
  int _charcnt = 0;

  final Map<String, Uint8List> _output = {};

  Zic({
    this.bloat = false,
    this.noise = false,
    this.loTime = _minTime,
    this.hiTime = _maxTime,
    int? redundantTime,
  }) : redundantTime = (redundantTime ?? _minTime) < loTime
            ? loTime
            : (redundantTime ?? _minTime);

  bool get _wantBloat => bloat;

  // -------------------------------------------------------------------------
  // Diagnósticos
  // -------------------------------------------------------------------------

  void _eats(int fnum, int num, int rfnum, int rnum) {
    _filenum = fnum;
    _linenum = num;
    _rfilenum = rfnum;
    _rlinenum = rnum;
  }

  void _eat(int fnum, int num) => _eats(fnum, num, 0, -1);

  String _filename(int i) => i > 0 && i <= _fileNames.length
      ? _fileNames[i - 1]
      : 'command line';

  String _context(String msg) {
    final buf = StringBuffer();
    if (_filenum != 0) buf.write('"${_filename(_filenum)}", line $_linenum: ');
    buf.write(msg);
    if (_rfilenum != 0) {
      buf.write(' (rule from "${_filename(_rfilenum)}", line $_rlinenum)');
    }
    return buf.toString();
  }

  void _error(String msg) => errors.add(_context(msg));

  void _warning(String msg) => warnings.add(_context(msg));

  Never _fatal(String msg) {
    _error(msg);
    throw ZicException(errors.join('\n'));
  }

  Never _timeOverflow() => _fatal('time overflow');

  int _oadd(int t1, int t2) {
    if (t1 < 0 ? _zicMin - t1 <= t2 : t2 <= _zicMax - t1) return t1 + t2;
    _timeOverflow();
  }

  int _tadd(int t1, int t2) {
    final sum = _oadd(t1, t2);
    if (_minTime <= sum && sum <= _maxTime) return sum;
    _timeOverflow();
  }

  int _omul(int t1, int t2) {
    if (t2 < 0
        ? _zicMax ~/ t2 <= t1 && (t2 == -1 || t1 <= _zicMin ~/ t2)
        : t2 == 0 || (_zicMin ~/ t2 <= t1 && t1 <= _zicMax ~/ t2)) {
      return t1 * t2;
    }
    _timeOverflow();
  }

  // -------------------------------------------------------------------------
  // Entrada
  // -------------------------------------------------------------------------

  /// Lê um arquivo-fonte do tzdata (equivalente a `infile`).
  void addSource(String name, String content) {
    _fileNames.add(name);
    final fnum = _fileNames.length;
    var wantcont = false;
    final lines = content.split('\n');
    // Como em inputline(): a última "linha" vazia após o '\n' final é o EOF;
    // texto sem '\n' final é um erro.
    final count = lines.length;
    for (var i = 0; i < count; i++) {
      final num = i + 1;
      _eat(fnum, num);
      final line = lines[i];
      if (i == count - 1) {
        if (line.isEmpty) break;
        _fatal('unterminated line');
      }
      if (line.contains('\u0000')) _fatal('NUL input byte');
      final fields = _getfields(line, _maxFields);
      if (fields.isEmpty) {
        // nada a fazer
      } else if (wantcont) {
        wantcont = _inzcont(fields);
      } else {
        final lp = _byword(fields[0], _ziLineCodes);
        if (lp == null) {
          _error('input line of unknown type');
        } else {
          switch (lp.value) {
            case _lcRule:
              _inrule(fields);
              wantcont = false;
              break;
            case _lcZone:
              wantcont = _inzone(fields);
              break;
            case _lcLink:
              _inlink(fields);
              wantcont = false;
              break;
          }
        }
      }
    }
    if (wantcont) _error('expected continuation line not found');
  }

  /// Divide a linha em campos (equivalente a `getfields`). Um campo que é
  /// apenas "-" vira a string vazia.
  List<String> _getfields(String line, int arrayelts) {
    final result = <String>[];
    var cp = 0;
    while (true) {
      while (_isSpace(_ch(line, cp))) {
        ++cp;
      }
      if (_ch(line, cp) == 0 || _ch(line, cp) == 0x23 /* # */) break;
      final field = StringBuffer();
      do {
        final c = _ch(line, cp++);
        if (c != 0x22 /* " */) {
          field.writeCharCode(c);
        } else {
          while (true) {
            final q = _ch(line, cp++);
            if (q == 0x22) break;
            if (q == 0) _fatal('Odd number of quotation marks');
            field.writeCharCode(q);
          }
        }
      } while (_ch(line, cp) != 0 &&
          _ch(line, cp) != 0x23 &&
          !_isSpace(_ch(line, cp)));
      if (_isSpace(_ch(line, cp))) ++cp;
      if (result.length == arrayelts) _fatal('Too many input fields');
      final s = field.toString();
      result.add(s == '-' ? '' : s);
    }
    return result;
  }

  _Lookup? _byword(String? word, List<_Lookup> table) {
    if (word == null) return null;
    var w = word;
    var t = table;
    if (identical(table, _lasts) && _ciprefix('last', w) && w.length > 4) {
      if (w.codeUnitAt(4) == 0x2D /* - */) {
        _warning('"$w" is undocumented; use "last${w.substring(5)}" instead');
      } else {
        w = w.substring(4);
        t = _wdayNames;
      }
    }
    for (final lp in t) {
      if (_ciequal(w, lp.word)) return lp;
    }
    _Lookup? foundlp;
    for (final lp in t) {
      if (_ciprefix(w, lp.word)) {
        if (foundlp == null) {
          foundlp = lp;
        } else {
          return null;
        }
      }
    }
    return foundlp;
  }

  /// Emula `sscanf(string, "%lld%c%d%c%d%c%1d%*[0]%c%*[0123456789]%c", ...)`
  /// usado por gethms e devolve o número de itens atribuídos e os valores.
  _HmsScan _scanHms(String s) {
    final r = _HmsScan();
    var p = 0;

    // %d: pula espaços, sinal opcional, pelo menos um dígito.
    int? scanInt({int maxWidth = -1}) {
      while (_isSpace(_ch(s, p))) {
        p++;
      }
      var q = p;
      var width = 0;
      var neg = false;
      final c0 = _ch(s, q);
      if ((c0 == 0x2B || c0 == 0x2D) && (maxWidth < 0 || width < maxWidth)) {
        neg = c0 == 0x2D;
        q++;
        width++;
      }
      final digitsStart = q;
      var value = 0;
      while (_isDigit(_ch(s, q)) && (maxWidth < 0 || width < maxWidth)) {
        value = value * 10 + (_ch(s, q) - 0x30);
        q++;
        width++;
      }
      if (q == digitsStart) return null;
      p = q;
      return neg ? -value : value;
    }

    int? scanChar() {
      final c = _ch(s, p);
      if (c == 0) return null;
      p++;
      return c;
    }

    bool scanSet(bool Function(int) accept) {
      final start = p;
      while (_ch(s, p) != 0 && accept(_ch(s, p))) {
        p++;
      }
      return p > start;
    }

    final hh = scanInt();
    if (hh == null) {
      r.count = _ch(s, p) == 0 ? -1 : 0;
      return r;
    }
    r.hh = hh;
    r.count = 1;
    final hhx = scanChar();
    if (hhx == null) return r;
    r.hhx = hhx;
    r.count = 2;
    final mm = scanInt();
    if (mm == null) return r;
    r.mm = mm;
    r.count = 3;
    final mmx = scanChar();
    if (mmx == null) return r;
    r.mmx = mmx;
    r.count = 4;
    final ss = scanInt();
    if (ss == null) return r;
    r.ss = ss;
    r.count = 5;
    final ssx = scanChar();
    if (ssx == null) return r;
    r.ssx = ssx;
    r.count = 6;
    final tenths = scanInt(maxWidth: 1);
    if (tenths == null) return r;
    r.tenths = tenths;
    r.count = 7;
    if (!scanSet((c) => c == 0x30)) return r;
    final xr = scanChar();
    if (xr == null) return r;
    r.xr = xr;
    r.count = 8;
    if (!scanSet(_isDigit)) return r;
    final xs = scanChar();
    if (xs == null) return r;
    r.count = 9;
    return r;
  }

  /// Converte "h", "-h", "hh:mm", "hh:mm:ss" (e frações) em segundos.
  int _gethms(String? string, String msgid) {
    if (string == null || string.isEmpty) return 0;
    var str = string;
    int sign;
    if (str.codeUnitAt(0) == 0x2D) {
      sign = -1;
      str = str.substring(1);
    } else {
      sign = 1;
    }
    final scan = _scanHms(str);
    var ok = true;
    switch (scan.count) {
      case 8:
        ok = _isDigit(scan.xr);
        ok &= scan.ssx == 0x2E;
        if (ok && noise) {
          _warning('fractional seconds rejected by pre-2018 versions of zic');
        }
        ok &= scan.mmx == 0x3A;
        ok &= scan.hhx == 0x3A;
        break;
      case 7:
        ok &= scan.ssx == 0x2E;
        if (ok && noise) {
          _warning('fractional seconds rejected by pre-2018 versions of zic');
        }
        ok &= scan.mmx == 0x3A;
        ok &= scan.hhx == 0x3A;
        break;
      case 5:
        ok &= scan.mmx == 0x3A;
        ok &= scan.hhx == 0x3A;
        break;
      case 3:
        ok &= scan.hhx == 0x3A;
        break;
      case 1:
        break;
      default:
        ok = false;
    }
    final hh = scan.hh;
    final mm = scan.mm;
    var ss = scan.ss;
    if (!ok ||
        hh < 0 ||
        mm < 0 ||
        mm >= _minsPerHour ||
        ss < 0 ||
        ss > _secsPerMin) {
      _error('$str: $msgid');
      return 0;
    }
    // Arredonda para o par.
    final roundBias = (ss ^ 1) & (scan.xr == 0x30 ? 1 : 0);
    if (5 + roundBias <= scan.tenths) ss += 1;
    if (noise &&
        (hh > _hoursPerDay || (hh == _hoursPerDay && (mm != 0 || ss != 0)))) {
      _warning('values over 24 hours not handled by pre-2007 versions of zic');
    }
    final r = _oadd(_omul(hh, sign * _secsPerHour),
        sign * (mm * _secsPerMin + ss));
    _omul(r, 4);
    return r;
  }

  /// Devolve (save, isdst) para um campo SAVE (aceita sufixos 'd' e 's').
  _Save _getsave(String field) {
    var dst = -1;
    var f = field;
    if (f.isNotEmpty) {
      final last = f.codeUnitAt(f.length - 1);
      if (last == 0x64 /* d */) {
        dst = 1;
        f = f.substring(0, f.length - 1);
      } else if (last == 0x73 /* s */) {
        dst = 0;
        f = f.substring(0, f.length - 1);
      }
    }
    final save = _gethms(f, 'invalid saved time');
    return _Save(save, dst < 0 ? save != 0 : dst == 1);
  }

  void _inrule(List<String> fields) {
    if (fields.length != _ruleFields) {
      _error('wrong number of fields on Rule line');
      return;
    }
    final name = fields[_rfName];
    final c0 = name.isEmpty ? 0 : name.codeUnitAt(0);
    if (c0 == 0 ||
        _isSpace(c0) ||
        c0 == 0x2B ||
        c0 == 0x2D ||
        _isDigit(c0)) {
      _error('Invalid rule name "$name"');
      return;
    }
    final r = _Rule()
      ..filenum = _filenum
      ..linenum = _linenum;
    final saved = _getsave(fields[_rfSave]);
    r.save = saved.save;
    r.isdst = saved.isdst;
    if (!_rulesub(r, fields[_rfLoYear], fields[_rfHiYear], fields[_rfCommand],
        fields[_rfMonth], fields[_rfDay], fields[_rfTod])) {
      return;
    }
    r.name = name;
    r.abbrvar = fields[_rfAbbrvar];
    if (_maxAbbrvarLen < r.abbrvar!.length) {
      _maxAbbrvarLen = r.abbrvar!.length;
    }
    _rules.add(r);
  }

  bool _inzone(List<String> fields) {
    if (fields.length < _zoneMinFields || fields.length > _zoneMaxFields) {
      _error('wrong number of fields on Zone line');
      return false;
    }
    for (final z in _zones) {
      if (z.name != null && z.name == fields[_zfName]) {
        _error('duplicate zone name ${fields[_zfName]}'
            ' (file "${_filename(z.filenum)}", line ${z.linenum})');
        return false;
      }
    }
    return _inzsub(fields, false);
  }

  bool _inzcont(List<String> fields) {
    if (fields.length < _zonecMinFields || fields.length > _zonecMaxFields) {
      _error('wrong number of fields on Zone continuation line');
      return false;
    }
    return _inzsub(fields, true);
  }

  bool _inzsub(List<String> fields, bool iscont) {
    int iStdoff, iRule, iFormat, iUntilyear, iUntilmonth, iUntilday,
        iUntiltime;
    if (iscont) {
      iStdoff = _zfcStdoff;
      iRule = _zfcRule;
      iFormat = _zfcFormat;
      iUntilyear = _zfcTilYear;
      iUntilmonth = _zfcTilMonth;
      iUntilday = _zfcTilDay;
      iUntiltime = _zfcTilTime;
    } else if (!_namecheck(fields[_zfName])) {
      return false;
    } else {
      iStdoff = _zfStdoff;
      iRule = _zfRule;
      iFormat = _zfFormat;
      iUntilyear = _zfTilYear;
      iUntilmonth = _zfTilMonth;
      iUntilday = _zfTilDay;
      iUntiltime = _zfTilTime;
    }
    final nfields = fields.length;
    final z = _Zone()
      ..filenum = _filenum
      ..linenum = _linenum;
    z.stdoff = _gethms(fields[iStdoff], 'invalid UT offset');
    final format = fields[iFormat];
    final pct = format.indexOf('%');
    var spec = 0;
    if (pct >= 0) {
      spec = _ch(format, pct + 1);
      if ((spec != 0x73 && spec != 0x7A) ||
          format.indexOf('%', pct + 1) >= 0 ||
          format.contains('/')) {
        _error('invalid abbreviation format');
        return false;
      }
    }
    z.formatSpecifier = spec;
    if (_maxFormatLen < format.length) _maxFormatLen = format.length;
    final hasuntil = nfields > iUntilyear;
    if (hasuntil) {
      z.untilrule.filenum = _filenum;
      z.untilrule.linenum = _linenum;
      if (!_rulesub(
          z.untilrule,
          fields[iUntilyear],
          'only',
          '',
          nfields > iUntilmonth ? fields[iUntilmonth] : 'Jan',
          nfields > iUntilday ? fields[iUntilday] : '1',
          nfields > iUntiltime ? fields[iUntiltime] : '0')) {
        return false;
      }
      z.untiltime = _rpytime(z.untilrule, z.untilrule.loyear);
      if (iscont && _zones.isNotEmpty && _zones.last.untiltime >= z.untiltime) {
        _error('Zone continuation line end time is'
            ' not after end time of previous line');
        return false;
      }
    }
    z.name = iscont ? null : fields[_zfName];
    z.rule = fields[iRule];
    var fmt = format;
    if (spec == 0x7A /* z */) {
      fmt = '${format.substring(0, pct + 1)}s${format.substring(pct + 2)}';
      if (noise) {
        _warning("format '$format' not handled by pre-2015 versions of zic");
      }
    }
    z.format = fmt;
    _zones.add(z);
    return hasuntil;
  }

  void _inlink(List<String> fields) {
    if (fields.length != _linkFields) {
      _error('wrong number of fields on Link line');
      return;
    }
    if (fields[_lfTarget].isEmpty) {
      _error('blank TARGET field on Link line');
      return;
    }
    if (!_namecheck(fields[_lfTarget])) return;
    if (!_namecheck(fields[_lfLinkname])) return;
    _links.add(
        _Link(_filenum, _linenum, fields[_lfTarget], fields[_lfLinkname]));
  }

  bool _componentcheck(String name, int start, int end) {
    const componentLenMax = 14;
    final len = end - start;
    if (len == 0) {
      if (name.isEmpty) {
        _error('empty file name');
      } else if (start == 0) {
        _error("file name '$name' begins with '/'");
      } else if (end < name.length) {
        _error("file name '$name' contains '//'");
      } else {
        _error("file name '$name' ends with '/'");
      }
      return false;
    }
    if (len <= 2 &&
        name.codeUnitAt(start) == 0x2E &&
        name.codeUnitAt(end - 1) == 0x2E) {
      _error("file name '$name' contains '${name.substring(start, end)}'"
          ' component');
      return false;
    }
    if (noise) {
      if (name.codeUnitAt(start) == 0x2D) {
        _warning("file name '$name' component contains leading '-'");
      }
      if (componentLenMax < len) {
        _warning("file name '$name' contains overlength component"
            " '${name.substring(start, start + componentLenMax)}...'");
      }
    }
    return true;
  }

  bool _namecheck(String name) {
    const benign = '-/_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    var component = 0;
    for (var cp = 0; cp < name.length; cp++) {
      final c = name.codeUnitAt(cp);
      if (noise && !benign.contains(String.fromCharCode(c))) {
        _warning("file name '$name' contains byte '${String.fromCharCode(c)}'");
      }
      if (c == 0x2F) {
        if (!_componentcheck(name, component, cp)) return false;
        component = cp + 1;
      }
    }
    return _componentcheck(name, component, name.length);
  }

  bool _rulesub(_Rule rp, String loyearp, String hiyearp, String typep,
      String monthp, String dayp, String timep) {
    var lp = _byword(monthp, _monNames);
    if (lp == null) {
      _error('invalid month name');
      return false;
    }
    rp.month = lp.value;
    rp.todisstd = false;
    rp.todisut = false;
    var dp = timep;
    if (dp.isNotEmpty) {
      final last = _lowerit(dp.codeUnitAt(dp.length - 1));
      var strip = true;
      switch (last) {
        case 0x73: // s: Standard
          rp.todisstd = true;
          rp.todisut = false;
          break;
        case 0x77: // w: Wall
          rp.todisstd = false;
          rp.todisut = false;
          break;
        case 0x67: // g: Greenwich
        case 0x75: // u: Universal
        case 0x7A: // z: Zulu
          rp.todisstd = true;
          rp.todisut = true;
          break;
        default:
          strip = false;
      }
      if (strip) dp = dp.substring(0, dp.length - 1);
    }
    rp.tod = _gethms(dp, 'invalid time of day');

    // Ano inicial.
    lp = _byword(loyearp, _beginYears);
    if (lp != null) {
      _warning('FROM year "$loyearp" is obsolete;'
          ' treated as ${_year32BitMin - 1}');
      rp.loyear = _year32BitMin - 1;
    } else {
      final y = _scanYear(loyearp);
      if (y == null) {
        _error('invalid starting year');
        return false;
      }
      rp.loyear = y;
    }
    // Ano final.
    lp = _byword(hiyearp, _endYears);
    rp.hiwasnum = lp == null;
    if (!rp.hiwasnum) {
      switch (lp!.value) {
        case _yrMaximum:
          rp.hiyear = _zicMax;
          break;
        case _yrOnly:
          rp.hiyear = rp.loyear;
          break;
      }
    } else {
      final y = _scanYear(hiyearp);
      if (y == null) {
        _error('invalid ending year');
        return false;
      }
      rp.hiyear = y;
    }
    if (rp.loyear > rp.hiyear) {
      _error('starting year greater than ending year');
      return false;
    }
    if (typep.isNotEmpty) {
      _error('year type "$typep" is unsupported; use "-" instead');
      return false;
    }

    // Dia.
    final lastLp = _byword(dayp, _lasts);
    if (lastLp != null) {
      rp.dycode = _dcDowLeq;
      rp.wday = lastLp.value;
      rp.dayofmonth = _lenMonths[1][rp.month];
    } else {
      var rest = dayp;
      var lt = dayp.indexOf('<');
      if (lt >= 0) {
        rp.dycode = _dcDowLeq;
      } else {
        lt = dayp.indexOf('>');
        rp.dycode = lt >= 0 ? _dcDowGeq : _dcDom;
      }
      if (rp.dycode != _dcDom) {
        final wdayName = dayp.substring(0, lt);
        if (_ch(dayp, lt + 1) != 0x3D /* = */) {
          _error('invalid day of month');
          return false;
        }
        rest = dayp.substring(lt + 2);
        final wl = _byword(wdayName, _wdayNames);
        if (wl == null) {
          _error('invalid weekday name');
          return false;
        }
        rp.wday = wl.value;
      }
      final d = _scanDayOfMonth(rest);
      if (d == null || d <= 0 || d > _lenMonths[1][rp.month]) {
        _error('invalid day of month');
        return false;
      }
      rp.dayofmonth = d;
    }
    return true;
  }

  /// Emula `sscanf(cp, "%lld%c", &y, &xs) == 1`.
  int? _scanYear(String s) => _scanIntExact(s);

  /// Emula `sscanf(ep, "%d%c", &d, &xs) == 1`.
  int? _scanDayOfMonth(String s) => _scanIntExact(s);

  int? _scanIntExact(String s) {
    var p = 0;
    while (_isSpace(_ch(s, p))) {
      p++;
    }
    var neg = false;
    if (_ch(s, p) == 0x2B || _ch(s, p) == 0x2D) {
      neg = _ch(s, p) == 0x2D;
      p++;
    }
    final start = p;
    var value = 0;
    while (_isDigit(_ch(s, p))) {
      value = value * 10 + (_ch(s, p) - 0x30);
      p++;
    }
    if (p == start) return null;
    if (p != s.length) return null; // %c leria mais um caractere.
    return neg ? -value : value;
  }

  // -------------------------------------------------------------------------
  // Associação de regras às zonas
  // -------------------------------------------------------------------------

  void _associate() {
    // Ordenação estável por nome (o zic usa qsort).
    final indexed = List<int>.generate(_rules.length, (i) => i);
    indexed.sort((a, b) {
      final c = _strcmp(_rules[a].name, _rules[b].name);
      return c != 0 ? c : a - b;
    });
    final sorted = [for (final i in indexed) _rules[i]];
    _rules
      ..clear()
      ..addAll(sorted);

    for (var i = 0; i < _rules.length - 1; ++i) {
      if (_rules[i].name != _rules[i + 1].name) continue;
      if (_rules[i].filenum == _rules[i + 1].filenum) continue;
      _eat(_rules[i].filenum, _rules[i].linenum);
      _warning('same rule name in multiple files');
      _eat(_rules[i + 1].filenum, _rules[i + 1].linenum);
      _warning('same rule name in multiple files');
      var j = i + 2;
      for (; j < _rules.length; ++j) {
        if (_rules[i].name != _rules[j].name) break;
        if (_rules[i].filenum == _rules[j].filenum) continue;
        if (_rules[i + 1].filenum == _rules[j].filenum) continue;
        break;
      }
      i = j - 1;
    }
    for (final zp in _zones) {
      zp.rules = const [];
    }
    for (var base = 0, out = 0; base < _rules.length; base = out) {
      final rp = _rules[base];
      for (out = base + 1; out < _rules.length; ++out) {
        if (rp.name != _rules[out].name) break;
      }
      final group = _rules.sublist(base, out);
      for (final zp in _zones) {
        if (zp.rule != rp.name) continue;
        zp.rules = group;
      }
    }
    for (final zp in _zones) {
      if (zp.rules.isEmpty) {
        _eat(zp.filenum, zp.linenum);
        final saved = _getsave(zp.rule);
        zp.save = saved.save;
        zp.isdst = saved.isdst;
        if (zp.formatSpecifier == 0x73 /* s */) {
          _error('%s in ruleless zone');
        }
      }
    }
    if (errors.isNotEmpty) throw ZicException(errors.join('\n'));
  }

  // -------------------------------------------------------------------------
  // Compilação
  // -------------------------------------------------------------------------

  /// Gera os arquivos TZif de todas as zonas e links lidos.
  ///
  /// Retorna um mapa (em ordem de geração) do nome do arquivo para os bytes.
  Map<String, Uint8List> compile() {
    if (errors.isNotEmpty) throw ZicException(errors.join('\n'));
    _associate();
    _output.clear();
    for (var i = 0, j = 0; i < _zones.length; i = j) {
      for (j = i + 1; j < _zones.length && _zones[j].name == null; ++j) {}
      _outzone(_zones.sublist(i, j));
    }
    _makeLinks();
    if (errors.isNotEmpty) throw ZicException(errors.join('\n'));
    return Map.unmodifiable(_output);
  }

  void _makeLinks() {
    final links = List<_Link>.of(_links);
    // Ordenação estável por nome do link, depois arquivo e linha.
    final idx = List<int>.generate(links.length, (i) => i);
    idx.sort((a, b) {
      var c = _strcmp(links[a].linkname, links[b].linkname);
      if (c != 0) return c;
      c = links[a].filenum - links[b].filenum;
      if (c != 0) return c;
      c = links[a].linenum.compareTo(links[b].linenum);
      return c != 0 ? c : a - b;
    });
    final sorted = [for (final i in idx) links[i]];

    // Ignora links substituídos por um link posterior de mesmo nome.
    final unique = <_Link>[];
    for (var i = 0; i < sorted.length; i++) {
      while (i + 1 < sorted.length &&
          sorted[i].linkname == sorted[i + 1].linkname) {
        i++;
      }
      unique.add(sorted[i]);
    }

    final arr = List<_Link>.of(unique);
    final nlinks = arr.length;
    var passSize = nlinks;
    var j = nlinks;
    var nalinks = nlinks;

    int? bsearch(String key, int from, int to) {
      var lo = from, hi = to - 1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        final c = _strcmp(key, arr[mid].linkname);
        if (c == 0) return mid;
        if (c < 0) {
          hi = mid - 1;
        } else {
          lo = mid + 1;
        }
      }
      return null;
    }

    for (var i = 0; i < nalinks; i++) {
      _eat(arr[i].filenum, arr[i].linenum);
      if (i == j) {
        if (nalinks - i == passSize) {
          _error('"Link ${arr[i].target} ${arr[i].linkname}" is part of a'
              ' link cycle');
          break;
        }
        j = nalinks;
        passSize = nalinks - i;
      }
      if (arr[i].target == arr[i].linkname) {
        _error('link ${arr[i].target} targets itself');
        continue;
      }
      var l = bsearch(arr[i].target, i + 1, j);
      l ??= bsearch(arr[i].target, j, nalinks);
      if (l == null) {
        _dolink(arr[i].target, arr[i].linkname);
      } else {
        arr.add(arr[i]);
        nalinks++;
      }
      if (noise && i < nlinks) {
        if (l != null) {
          _warning('link ${arr[i].linkname} targeting link ${arr[i].target}'
              ' mishandled by pre-2023 zic');
        } else if (bsearch(arr[i].target, 0, nlinks) != null) {
          _warning('link ${arr[i].linkname} targeting link ${arr[i].target}');
        }
      }
    }
  }

  void _dolink(String target, String linkname) {
    if (target == '-') {
      _output.remove(linkname);
      return;
    }
    final data = _output[target];
    if (data == null) _fatal("Can't read $target: No such file or directory");
    // O zic tenta link físico/simbólico; o conteúdo é sempre o do alvo.
    _output[linkname] = data;
  }

  // -------------------------------------------------------------------------
  // outzone
  // -------------------------------------------------------------------------

  void _updateminmax(int x) {
    if (_minYear > x) _minYear = x;
    if (_maxYear < x) _maxYear = x;
  }

  void _addtt(int starttime, int type) {
    _attypes.add(_AtType(starttime, false, type));
  }

  void _outzone(List<_Zone> zones) {
    final zonecount = zones.length;
    var starttime = 0;
    var untiltime = 0;
    var startttisstd = false;
    var startttisut = false;
    var nonTZlimtime = _zicMin;
    var nonTZlimtype = -1;
    var defaulttype = -1;

    _attypes = [];
    _typecnt = 0;
    _charcnt = 0;
    _minYear = _maxYear = _epochYear;
    for (var i = 0; i < zonecount; ++i) {
      final zp = zones[i];
      if (i < zonecount - 1) _updateminmax(zp.untilrule.loyear);
      for (final rp in zp.rules) {
        _updateminmax(rp.loyear);
        if (rp.hiwasnum) _updateminmax(rp.hiyear);
      }
    }

    // Gera muitos dados se uma regra não cobrir todo o futuro.
    final tz = _stringzone(zones);
    final envvar = tz.text;
    final compat = tz.compat;
    final version = compat < 2013 ? '2' : '3';
    final doExtend = compat < 0;
    if (noise) {
      if (envvar.isEmpty) {
        _warning('no proleptic TZ string for zone ${zones.first.name}');
      } else if (compat != 0) {
        _warning('${zones.first.name}: pre-$compat clients may mishandle'
            ' distant timestamps');
      }
    }
    if (doExtend) {
      if (_minYear >= _zicMin + _yearsOfObservations) {
        _minYear -= _yearsOfObservations;
      } else {
        _minYear = _zicMin;
      }
      if (_maxYear <= _zicMax - _yearsOfObservations) {
        _maxYear += _yearsOfObservations;
      } else {
        _maxYear = _zicMax;
      }
    }
    final fromRedundant =
        redundantTime ~/ (_secsPerDay * _daysPerNYear) + _epochYear + 1;
    if (_maxYear < fromRedundant) _maxYear = fromRedundant;
    final maxYear0 = _maxYear;
    if (_wantBloat) {
      // Para sistemas antigos, gera dados de 1900 a 2038.
      if (_minYear > _year32BitMin - 1) _minYear = _year32BitMin - 1;
      if (_maxYear < _year32BitMax) _maxYear = _year32BitMax;
    }

    if (_minTime < loTime || hiTime < _maxTime) {
      _unspecifiedtype = _addtype(0, '-00', false, false, false);
    }

    for (var i = 0; i < zonecount; ++i) {
      var save = 0;
      final zp = zones[i];
      var usestart = i > 0 && zones[i - 1].untiltime > _minTime;
      final useuntil = i < zonecount - 1;
      final stdoff = zp.stdoff;
      var startoff = stdoff;
      if (useuntil && zp.untiltime <= _minTime) continue;
      _eat(zp.filenum, zp.linenum);
      String startbuf = '';
      if (zp.rules.isEmpty) {
        save = zp.save;
        startbuf = _doabbr(zp, null, zp.isdst, save, false);
        final type = _addtype(
            zp.stdoff + save, startbuf, zp.isdst, startttisstd, startttisut);
        if (usestart) {
          _addtt(starttime, type);
          if (nonTZlimtime < starttime) {
            nonTZlimtime = starttime;
            nonTZlimtype = type;
          }
          usestart = false;
        } else {
          defaulttype = type;
        }
      } else {
        var tryNextYear = true;
        for (var year = _minYear, nextYear = 0;
            tryNextYear;
            year = nextYear) {
          if (useuntil && year > zp.untilrule.hiyear) break;
          tryNextYear = false;
          nextYear = _maxYear;
          // Marca as regras a aplicar no ano corrente.
          for (final rp in zp.rules) {
            const y2038Boundary = 1 << 31;
            _eats(zp.filenum, zp.linenum, rp.filenum, rp.linenum);
            if (year < rp.hiyear) {
              final next = year + 1 > rp.loyear ? year + 1 : rp.loyear;
              if (next <= nextYear) {
                nextYear = next;
                tryNextYear = true;
              }
            }
            rp.todo = year >= rp.loyear && year <= rp.hiyear;
            if (rp.todo) {
              rp.temp = _rpytime(rp, year);
              rp.todo = rp.temp < y2038Boundary || year <= maxYear0;
            }
          }
          while (true) {
            var ktime = 0;
            if (useuntil) {
              // Converte untiltime para UT com os valores correntes de
              // stdoff e save.
              untiltime = zp.untiltime;
              if (!zp.untilrule.todisut) {
                untiltime = _tadd(untiltime, -stdoff);
              }
              if (!zp.untilrule.todisstd) {
                untiltime = _tadd(untiltime, -save);
              }
            }
            // Encontra a regra que entra em vigor mais cedo no ano.
            var k = -1;
            for (var j = 0; j < zp.rules.length; ++j) {
              final r = zp.rules[j];
              if (!r.todo) continue;
              _eats(zp.filenum, zp.linenum, r.filenum, r.linenum);
              var offset = r.todisut ? 0 : stdoff;
              if (!r.todisstd) offset += save;
              var jtime = r.temp;
              jtime = _tadd(jtime, -offset);
              if (k < 0 || jtime < ktime) {
                k = j;
                ktime = jtime;
              } else if (jtime == ktime) {
                const dupRules = 'two rules for same instant';
                _eats(zp.filenum, zp.linenum, r.filenum, r.linenum);
                _warning(dupRules);
                final rk = zp.rules[k];
                _eats(zp.filenum, zp.linenum, rk.filenum, rk.linenum);
                _error(dupRules);
              }
            }
            if (k < 0) break; // próximo ano
            final rp = zp.rules[k];
            rp.todo = false;
            if (useuntil && ktime >= untiltime) {
              if (startbuf.isEmpty && zp.stdoff + rp.save == startoff) {
                startbuf =
                    _doabbr(zp, rp.abbrvar, rp.isdst, rp.save, false);
              }
              break;
            }
            save = rp.save;
            if (usestart && ktime == starttime) usestart = false;
            if (usestart) {
              if (ktime < starttime) {
                startoff = zp.stdoff + save;
                startbuf =
                    _doabbr(zp, rp.abbrvar, rp.isdst, rp.save, false);
                continue;
              }
              if (startbuf.isEmpty && startoff == zp.stdoff + save) {
                startbuf =
                    _doabbr(zp, rp.abbrvar, rp.isdst, rp.save, false);
              }
            }
            _eats(zp.filenum, zp.linenum, rp.filenum, rp.linenum);
            final ab = _doabbr(zp, rp.abbrvar, rp.isdst, rp.save, false);
            final offset = zp.stdoff + rp.save;
            final type =
                _addtype(offset, ab, rp.isdst, rp.todisstd, rp.todisut);
            if (defaulttype < 0 && !rp.isdst) defaulttype = type;
            _addtt(ktime, type);
            if (nonTZlimtime < ktime &&
                (useuntil || rp.hiyear != _zicMax)) {
              nonTZlimtime = ktime;
              nonTZlimtype = type;
            }
          }
        }
      }
      if (usestart) {
        final isdst = startoff != zp.stdoff;
        if (startbuf.isEmpty) {
          startbuf = _doabbr(zp, _disablePercentS, isdst, save, false);
        }
        _eat(zp.filenum, zp.linenum);
        if (startbuf.isEmpty) {
          _error("can't determine time zone abbreviation"
              ' to use just after until time');
        } else {
          final type =
              _addtype(startoff, startbuf, isdst, startttisstd, startttisut);
          if (defaulttype < 0 && !isdst) defaulttype = type;
          _addtt(starttime, type);
        }
      }
      // Agora define starttime para a próxima linha da zona.
      if (useuntil) {
        startttisstd = zp.untilrule.todisstd;
        startttisut = zp.untilrule.todisut;
        starttime = zp.untiltime;
        if (!startttisstd) starttime = _tadd(starttime, -save);
        if (!startttisut) starttime = _tadd(starttime, -stdoff);
      }
    }
    if (defaulttype < 0) defaulttype = 0;
    if (!doExtend && !_wantBloat) {
      // A transição mais antiga para um período regido pela string TZ.
      var tzStarttime = _zicMax;
      for (final a in _attypes) {
        if (nonTZlimtime < a.at && a.at < tzStarttime) tzStarttime = a.at;
      }
      if (tzStarttime == _zicMax) tzStarttime = nonTZlimtime;

      // Omite transições finais dedutíveis da string TZ.
      final keepAtMax =
          tzStarttime > redundantTime ? tzStarttime : redundantTime;
      final kept = <_AtType>[];
      for (final a in _attypes) {
        if (a.at <= keepAtMax) {
          kept.add(_AtType(
              a.at,
              a.at == tzStarttime &&
                  (nonTZlimtype != a.type || envvar.contains(',')),
              a.type));
        }
      }
      _attypes = kept;
    }
    if (doExtend) {
      // Se as observações foram estendidas por 400 anos, garante que há
      // uma transição perto do fim do período.
      final xr = _Rule()
        ..month = _tmJanuary
        ..dycode = _dcDom
        ..dayofmonth = 1
        ..tod = 0;
      _AtType? lastat = _attypes.isEmpty ? null : _attypes[0];
      for (var i = 1; i < _attypes.length; i++) {
        if (_attypes[i].at > lastat!.at) lastat = _attypes[i];
      }
      if (lastat == null || lastat.at < _rpytime(xr, _maxYear - 1)) {
        _addtt(_rpytime(xr, _maxYear + 1),
            lastat != null ? lastat.type : defaulttype);
        _attypes.last.dontmerge = true;
      }
    }
    _writezone(zones.first.name!, envvar, version, defaulttype);
  }

  int _addtype(int utoff, String abbr, bool isdst, bool ttisstd, bool ttisut) {
    return _addtypeRaw(utoff, abbr, isdst ? 1 : 0, ttisstd, ttisut);
  }

  /// [isdst] é inteiro porque o zic compara com `isdsts[]`, que pode valer -1
  /// temporariamente (ver writezone).
  int _addtypeRaw(
      int utoff, String abbr, int isdst, bool ttisstd, bool ttisut) {
    if (!(-_two31Minus1 <= utoff && utoff <= _two31Minus1)) {
      _fatal('UT offset out of range');
    }
    if (!_wantBloat) ttisstd = ttisut = false;

    _checkabbr(abbr);

    final charcnt0 = _charcnt;
    final res = _addabbr(_chars, _charcnt, abbr);
    final j = res.index;
    _charcnt = res.count;
    if (charcnt0 < _charcnt) {
      // Se uma abreviação foi inserida, ajusta os índices posteriores.
      for (var i = 0; i < _typecnt; i++) {
        if (j <= _desigidx[i]) {
          _desigidx[i] = (_desigidx[i] + _charcnt - charcnt0) & 0xFF;
        }
      }
    } else {
      // Se o tipo já existe, devolve o índice dele.
      for (var i = 0; i < _typecnt; i++) {
        if (utoff == _utoffs[i] &&
            isdst == _isdsts[i] &&
            j == _desigidx[i] &&
            ttisstd == _ttisstds[i] &&
            ttisut == _ttisuts[i]) {
          return i;
        }
      }
    }
    if (_typecnt >= _tzMaxTypes) _fatal('too many local time types');
    final i = _typecnt++;
    _utoffs[i] = utoff;
    _isdsts[i] = isdst;
    _ttisstds[i] = ttisstd;
    _ttisuts[i] = ttisut;
    _desigidx[i] = j;
    return i;
  }

  void _checkabbr(String string) {
    if (string == _grandparented) return;
    var cp = 0;
    while (cp < string.length) {
      final c = string.codeUnitAt(cp);
      if (_isAlpha(c) || _isDigit(c) || c == 0x2D || c == 0x2B) {
        cp++;
      } else {
        break;
      }
    }
    String? mp;
    if (noise && cp < 3) {
      mp = 'time zone abbreviation has fewer than 3 characters';
    }
    if (cp > _zicMaxAbbrLenWoWarn) {
      mp = 'time zone abbreviation has too many characters';
    }
    if (cp != string.length) {
      mp = 'time zone abbreviation differs from POSIX standard';
    }
    if (mp != null) _warning('$mp ($string)');
  }

  // -------------------------------------------------------------------------
  // Abreviações e string TZ
  // -------------------------------------------------------------------------

  static const String _disablePercentS = '\u0000disable_percent_s';

  String _abbroffset(int offset) {
    const offsetLim = 100 * _secsPerHour;
    if (!(-offsetLim < offset && offset < offsetLim)) {
      _error('%z UT offset magnitude exceeds 99:59:59');
      return '%z';
    }
    final sign = offset < 0 ? '-' : '+';
    final absOffset = offset < 0 ? -offset : offset;
    final seconds = absOffset % _secsPerMin;
    final absMinutesOffset = absOffset ~/ _secsPerMin;
    final minutes = absMinutesOffset % _minsPerHour;
    final hours = absMinutesOffset ~/ _minsPerHour;
    final buf = StringBuffer()
      ..write(sign)
      ..write(hours ~/ 10)
      ..write(hours % 10);
    if ((minutes | seconds) != 0) {
      buf
        ..write(minutes ~/ 10)
        ..write(minutes % 10);
      if (seconds != 0) {
        buf
          ..write(seconds ~/ 10)
          ..write(seconds % 10);
      }
    }
    return buf.toString();
  }

  /// Equivalente a `doabbr`; devolve a abreviação gerada.
  String _doabbr(
      _Zone zp, String? letters, bool isdst, int save, bool doquotes) {
    final format = zp.format;
    final slash = format.indexOf('/');
    String abbr;
    if (slash < 0) {
      if (zp.formatSpecifier == 0x7A /* z */) {
        letters = _abbroffset(zp.stdoff + save);
      } else if (letters == null) {
        letters = '%s';
      } else if (identical(letters, _disablePercentS)) {
        return '';
      }
      abbr = _sprintfS(format, letters);
    } else if (isdst) {
      abbr = format.substring(slash + 1);
    } else {
      abbr = format.substring(0, slash);
    }
    if (!doquotes) return abbr;
    var cp = 0;
    while (cp < abbr.length && _isAlpha(abbr.codeUnitAt(cp))) {
      cp++;
    }
    if (abbr.isNotEmpty && cp == abbr.length) return abbr;
    return '<$abbr>';
  }

  /// `sprintf(abbr, format, letters)` para um formato com no máximo um %s.
  String _sprintfS(String format, String letters) {
    final pct = format.indexOf('%s');
    if (pct < 0) return format;
    return format.substring(0, pct) + letters + format.substring(pct + 2);
  }

  /// Equivalente a `stringoffset`; devolve null quando o C devolve 0.
  String? _stringoffset(int offset) {
    final negative = offset < 0;
    if (negative) offset = -offset;
    final seconds = offset.remainder(_secsPerMin);
    offset = offset ~/ _secsPerMin;
    final minutes = offset.remainder(_minsPerHour);
    offset = offset ~/ _minsPerHour;
    if (offset >= _hoursPerDay * _daysPerWeek) return null;
    final hours = offset;
    final buf = StringBuffer();
    if (negative) buf.write('-');
    buf.write(hours);
    if (minutes != 0 || seconds != 0) {
      buf.write(':${minutes.toString().padLeft(2, '0')}');
      if (seconds != 0) buf.write(':${seconds.toString().padLeft(2, '0')}');
    }
    return buf.toString();
  }

  /// Equivalente a `stringrule`; devolve (texto, compat) ou compat < 0.
  _TextCompat _stringrule(_Rule rp, int save, int stdoff) {
    var tod = rp.tod;
    var compat = 0;
    final out = StringBuffer();
    if (rp.dycode == _dcDom) {
      if (rp.dayofmonth == 29 && rp.month == _tmFebruary) {
        return const _TextCompat('', -1);
      }
      var total = 0;
      for (var month = 0; month < rp.month; ++month) {
        total += _lenMonths[0][month];
      }
      // Omite o "J" em janeiro e fevereiro, por ser mais curto.
      if (rp.month <= 1) {
        out.write(total + rp.dayofmonth - 1);
      } else {
        out.write('J${total + rp.dayofmonth}');
      }
    } else {
      int week;
      var wday = rp.wday;
      int wdayoff;
      if (rp.dycode == _dcDowGeq) {
        wdayoff = (rp.dayofmonth - 1).remainder(_daysPerWeek);
        if (wdayoff != 0) compat = 2013;
        wday -= wdayoff;
        tod += wdayoff * _secsPerDay;
        week = 1 + (rp.dayofmonth - 1) ~/ _daysPerWeek;
      } else if (rp.dycode == _dcDowLeq) {
        if (rp.dayofmonth == _lenMonths[1][rp.month]) {
          week = 5;
        } else {
          wdayoff = rp.dayofmonth.remainder(_daysPerWeek);
          if (wdayoff != 0) compat = 2013;
          wday -= wdayoff;
          tod += wdayoff * _secsPerDay;
          week = rp.dayofmonth ~/ _daysPerWeek;
        }
      } else {
        return const _TextCompat('', -1);
      }
      if (wday < 0) wday += _daysPerWeek;
      out.write('M${rp.month + 1}.$week.$wday');
    }
    if (rp.todisut) tod += stdoff;
    if (rp.todisstd && !rp.isdst) tod += save;
    if (tod != 2 * _secsPerMin * _minsPerHour) {
      out.write('/');
      final off = _stringoffset(tod);
      if (off == null) return const _TextCompat('', -1);
      out.write(off);
      if (tod < 0) {
        if (compat < 2013) compat = 2013;
      } else if (_secsPerDay <= tod) {
        if (compat < 1994) compat = 1994;
      }
    }
    return _TextCompat(out.toString(), compat);
  }

  int _ruleCmp(_Rule? a, _Rule? b) {
    if (a == null) return b == null ? 0 : -1;
    if (b == null) return 1;
    if (a.hiyear != b.hiyear) return a.hiyear < b.hiyear ? -1 : 1;
    if (a.hiyear == _zicMax) return 0;
    if (a.month - b.month != 0) return a.month - b.month;
    return a.dayofmonth - b.dayofmonth;
  }

  /// Equivalente a `stringzone`: devolve (string TZ, compat).
  _TextCompat _stringzone(List<_Zone> zones) {
    var compat = 0;
    if (hiTime < _maxTime) return const _TextCompat('', -1);

    final zp = zones.last;
    final lastrp = <_Rule?>[null, null];
    for (final rp in zp.rules) {
      final idx = rp.isdst ? 1 : 0;
      final cmp = _ruleCmp(lastrp[idx], rp);
      if (cmp < 0) {
        lastrp[idx] = rp;
      } else if (cmp == 0) {
        return const _TextCompat('', -1);
      }
    }
    _Rule? stdrp = lastrp[0];
    _Rule? dstrp = lastrp[1];
    final dstcmp = zp.rules.isNotEmpty
        ? _ruleCmp(dstrp, stdrp)
        : zp.isdst
            ? 1
            : -1;
    var stdzp = zp;
    var dstzp = zp;

    if (dstcmp < 0) {
      // Horário padrão o ano todo.
      dstrp = null;
    } else if (0 < dstcmp) {
      // Horário de verão o ano todo.
      final save = dstrp != null ? dstrp.save : zp.save;
      if (0 <= save) {
        // Caso típico: simula uma zona com horário de verão negativo.
        stdzp = _Zone()
          ..stdoff = zp.stdoff + 2 * save
          ..format = 'XXX'
          ..formatSpecifier = 0;
        dstzp = _Zone()
          ..stdoff = stdzp.stdoff
          ..format = zp.format
          ..formatSpecifier = zp.formatSpecifier;
      }
      final dstr = _Rule()
        ..month = _tmJanuary
        ..dycode = _dcDom
        ..dayofmonth = 1
        ..tod = 0
        ..todisstd = false
        ..todisut = false
        ..isdst = true
        ..save = save < 0 ? save : -save
        ..abbrvar = dstrp?.abbrvar;
      final stdr = _Rule()
        ..month = _tmDecember
        ..dycode = _dcDom
        ..dayofmonth = 31
        ..tod = _secsPerDay + dstr.save
        ..todisstd = false
        ..todisut = false
        ..isdst = false
        ..save = 0
        ..abbrvar = save < 0 && stdrp != null ? stdrp.abbrvar : null;
      dstrp = dstr;
      stdrp = stdr;
    }
    final result = StringBuffer();
    result.write(_doabbr(stdzp, stdrp?.abbrvar, false, 0, true));
    var off = _stringoffset(-stdzp.stdoff);
    if (off == null) return const _TextCompat('', -1);
    result.write(off);
    if (dstrp == null) return _TextCompat(result.toString(), compat);
    result.write(_doabbr(dstzp, dstrp.abbrvar, dstrp.isdst, dstrp.save, true));
    if (dstrp.save != _secsPerMin * _minsPerHour) {
      off = _stringoffset(-(dstzp.stdoff + dstrp.save));
      if (off == null) return const _TextCompat('', -1);
      result.write(off);
    }
    result.write(',');
    var rule = _stringrule(dstrp, dstrp.save, stdzp.stdoff);
    if (rule.compat < 0) return const _TextCompat('', -1);
    if (compat < rule.compat) compat = rule.compat;
    result.write(rule.text);
    result.write(',');
    rule = _stringrule(stdrp!, dstrp.save, stdzp.stdoff);
    if (rule.compat < 0) return const _TextCompat('', -1);
    if (compat < rule.compat) compat = rule.compat;
    result.write(rule.text);
    return _TextCompat(result.toString(), compat);
  }

  // -------------------------------------------------------------------------
  // rpytime
  // -------------------------------------------------------------------------

  /// Momento (segundos desde 1970-01-01 00:00 no horário LOCAL) em que a
  /// regra [rp] se aplica no ano [wantedy].
  int _rpytime(_Rule rp, int wantedy) {
    var m = _tmJanuary;
    var y = _epochYear;

    // dayoff = floor((wantedy - y) / YEARSPERREPEAT) * DAYSPERREPEAT.
    final yrem =
        wantedy.remainder(_yearsPerRepeat) - y.remainder(_yearsPerRepeat);
    var dayoff = _omul(
        wantedy ~/ _yearsPerRepeat -
            y ~/ _yearsPerRepeat +
            yrem ~/ _yearsPerRepeat -
            (yrem.remainder(_yearsPerRepeat) < 0 ? 1 : 0),
        _daysPerRepeat);
    // wantedy = y + ((wantedy - y) mod YEARSPERREPEAT), sem overflow.
    final target =
        y + (yrem + 2 * _yearsPerRepeat).remainder(_yearsPerRepeat);

    while (target != y) {
      dayoff = _oadd(dayoff, _yearDays(y));
      y++;
    }
    while (m != rp.month) {
      dayoff = _oadd(dayoff, _lenMonths[_isLeap(y) ? 1 : 0][m]);
      ++m;
    }
    var i = rp.dayofmonth;
    if (m == _tmFebruary && i == 29 && !_isLeap(y)) {
      if (rp.dycode == _dcDowLeq) {
        --i;
      } else {
        _fatal('use of 2/29 in non leap-year');
      }
    }
    --i;
    dayoff = _oadd(dayoff, i);
    if (rp.dycode == _dcDowGeq || rp.dycode == _dcDowLeq) {
      var wday = (_epochWday + dayoff.remainder(_daysPerWeek) + _daysPerWeek)
          .remainder(_daysPerWeek);
      while (wday != rp.wday) {
        if (rp.dycode == _dcDowGeq) {
          dayoff = _oadd(dayoff, 1);
          if (++wday >= _daysPerWeek) wday = 0;
          ++i;
        } else {
          dayoff = _oadd(dayoff, -1);
          if (--wday < 0) wday = _daysPerWeek - 1;
          --i;
        }
      }
      if (i < 0 || i >= _lenMonths[_isLeap(y) ? 1 : 0][m]) {
        if (noise) {
          _warning('rule goes past start/end of month;'
              ' will not work with pre-2004 versions of zic');
        }
      }
    }
    final t = _omul(dayoff, _secsPerDay);
    return _tadd(t, rp.tod);
  }

  // -------------------------------------------------------------------------
  // writezone
  // -------------------------------------------------------------------------

  _TimeRange _limitrange(
      _TimeRange r0, int lo, int hi, List<int> ats, List<int> types) {
    final r = r0.copy();
    // Omite transições comuns < LO.
    while (0 < r.count && ats[r.base] < lo) {
      r.defaulttype = types[r.base];
      r.count--;
      r.base++;
    }
    // (Sem segundos intercalares.)
    // Omite transições maiores que HI + 1.
    if (hi < _maxTime) {
      while (0 < r.count && hi + 1 < ats[r.base + r.count - 1]) {
        r.count--;
      }
    }
    r.leapexpiry = false;
    return r;
  }

  void _writezone(String name, String string, String version, int defaulttype) {
    // Ordena (de forma estável) por instante.
    final indexed = List<int>.generate(_attypes.length, (i) => i);
    indexed.sort((a, b) {
      final x = _attypes[a].at, y = _attypes[b].at;
      if (x != y) return x < y ? -1 : 1;
      return a - b;
    });
    final attypes = [for (final i in indexed) _attypes[i]];

    // Otimiza e descarta transições indesejadas.
    var toi = 0;
    for (var fromi = 0; fromi < attypes.length; ++fromi) {
      if (toi != 0) {
        // Descarta a transição anterior se o horário local dela não for
        // anterior.
        final type2 = toi == 1 ? 0 : attypes[toi - 2].type;
        if (attypes[fromi].at + _utoffs[attypes[toi - 1].type] <=
            attypes[toi - 1].at + _utoffs[type2]) {
          if (attypes[fromi].type == type2) {
            toi--;
          } else {
            attypes[toi - 1].type = attypes[fromi].type;
          }
          continue;
        }
      }
      if (toi == 0 ||
          attypes[fromi].dontmerge ||
          _utoffs[attypes[toi - 1].type] != _utoffs[attypes[fromi].type] ||
          _isdsts[attypes[toi - 1].type] != _isdsts[attypes[fromi].type] ||
          _desigidx[attypes[toi - 1].type] !=
              _desigidx[attypes[fromi].type]) {
        attypes[toi++] = _AtType(
            attypes[fromi].at, attypes[fromi].dontmerge, attypes[fromi].type);
      }
    }
    final timecnt = toi;

    if (noise && 1200 < timecnt) {
      if (_tzMaxTimes < timecnt) {
        _warning('reference clients mishandle'
            ' more than $_tzMaxTimes transition times');
      } else {
        _warning('pre-2014 clients may mishandle'
            ' more than 1200 transition times');
      }
    }

    final ats = List<int>.generate(timecnt, (i) => attypes[i].at);
    final types = List<int>.generate(timecnt, (i) => attypes[i].type);

    final rangeall = _TimeRange()
      ..defaulttype = defaulttype
      ..count = timecnt;
    final range64 = _limitrange(
        rangeall,
        loTime,
        hiTime > redundantTime - (_zicMin < redundantTime ? 1 : 0)
            ? hiTime
            : redundantTime - (_zicMin < redundantTime ? 1 : 0),
        ats,
        types);
    final range32 = _limitrange(range64, _zic32Min, _zic32Max, ats, types);

    final out = BytesBuilder(copy: false);

    for (var pass = 1; pass <= 2; ++pass) {
      int thistimei, thistimecnt, thisdefaulttype;
      int thismin, thismax;
      var pretranstype = -1;
      if (pass == 1) {
        thisdefaulttype = range32.defaulttype;
        thistimei = range32.base;
        thistimecnt = range32.count;
        thismin = _zic32Min;
        thismax = _zic32Max;
      } else {
        thisdefaulttype = range64.defaulttype;
        thistimei = range64.base;
        thistimecnt = range64.count;
        thismin = _minTime;
        thismax = _maxTime;
      }

      final locut = thismin < loTime && loTime <= thismax;
      var hicut = thismin <= hiTime && hiTime < thismax;
      final thistimelim = thistimei + thistimecnt;
      final omittype = List<bool>.filled(_tzMaxTypes, true);

      // Decide se é preciso uma transição antes da primeira no intervalo.
      if ((locut || (pass == 1 && thistimei != 0)) &&
          !(thistimecnt != 0 && ats[thistimei] == loTime)) {
        pretranstype = thisdefaulttype;
        omittype[pretranstype] = false;
      }

      // Tipo padrão dos dados de 32 bits (ver comentário no zic.c).
      if (pass == 1 && loTime <= thismin) {
        thisdefaulttype = range64.defaulttype;
      }

      if (locut) thisdefaulttype = _unspecifiedtype;
      omittype[thisdefaulttype] = false;
      for (var i = thistimei; i < thistimelim; i++) {
        omittype[types[i]] = false;
      }
      if (hicut) omittype[_unspecifiedtype] = false;

      // Reordena os tipos para que THISDEFAULTTYPE seja o tipo 0.
      var old0 = 0;
      while (omittype[old0]) {
        old0++;
      }

      // Para alguns sistemas pré-2011 (LEAVE_SOME_PRE_2011_SYSTEMS_IN_THE_LURCH
      // não definido).
      if (_wantBloat) {
        var hidst = -1, histd = -1, mrudst = -1, mrustd = -1;
        if (0 <= pretranstype) {
          if (_isdsts[pretranstype] != 0) {
            mrudst = pretranstype;
          } else {
            mrustd = pretranstype;
          }
        }
        for (var i = thistimei; i < thistimelim; i++) {
          if (_isdsts[types[i]] != 0) {
            mrudst = types[i];
          } else {
            mrustd = types[i];
          }
        }
        for (var i = old0; i < _typecnt; i++) {
          final h = i == old0
              ? thisdefaulttype
              : i == thisdefaulttype
                  ? old0
                  : i;
          if (!omittype[h]) {
            if (_isdsts[h] != 0) {
              hidst = i;
            } else {
              histd = i;
            }
          }
        }
        if (hidst >= 0 &&
            mrudst >= 0 &&
            hidst != mrudst &&
            _utoffs[hidst] != _utoffs[mrudst]) {
          _isdsts[mrudst] = -1;
          final type = _addtypeRaw(_utoffs[mrudst], _abbrAt(_desigidx[mrudst]),
              1, _ttisstds[mrudst], _ttisuts[mrudst]);
          _isdsts[mrudst] = 1;
          omittype[type] = false;
        }
        if (histd >= 0 &&
            mrustd >= 0 &&
            histd != mrustd &&
            _utoffs[histd] != _utoffs[mrustd]) {
          _isdsts[mrustd] = -1;
          final type = _addtypeRaw(_utoffs[mrustd], _abbrAt(_desigidx[mrustd]),
              0, _ttisstds[mrustd], _ttisuts[mrustd]);
          _isdsts[mrustd] = 0;
          omittype[type] = false;
        }
      }
      final typemap = List<int>.filled(_tzMaxTypes, 0);
      var thistypecnt = 0;
      for (var i = old0; i < _typecnt; i++) {
        if (!omittype[i]) {
          typemap[i == old0
              ? thisdefaulttype
              : i == thisdefaulttype
                  ? old0
                  : i] = thistypecnt++;
        }
      }

      final thischars = List<int>.filled(_tzMaxChars, 0);
      var thischarcnt = 0;
      var stdcnt = 0, utcnt = 0;
      for (var i = old0; i < _typecnt; i++) {
        if (omittype[i]) continue;
        if (_ttisstds[i]) stdcnt = thistypecnt;
        if (_ttisuts[i]) utcnt = thistypecnt;
        thischarcnt =
            _addabbr(thischars, thischarcnt, _abbrAt(_desigidx[i])).count;
      }

      final indmap = List<int>.filled(_tzMaxChars, -1);
      for (var i = old0; i < _typecnt; i++) {
        if (!omittype[i] && indmap[_desigidx[i]] < 0) {
          final res =
              _addabbr(thischars, thischarcnt, _abbrAt(_desigidx[i]));
          thischarcnt = res.count;
          indmap[_desigidx[i]] = res.index;
        }
      }

      if (pass == 1 && !_wantBloat) {
        hicut = false;
        pretranstype = -1;
        thistimecnt = 0;
        thistypecnt = thischarcnt = 1;
      }

      // Cabeçalho.
      out.add(const [0x54, 0x5A, 0x69, 0x66]); // "TZif"
      out.addByte(version.codeUnitAt(0));
      out.add(List<int>.filled(15, 0));
      _put32(out, utcnt);
      _put32(out, stdcnt);
      _put32(out, 0); // leapcnt
      _put32(out, (0 <= pretranstype ? 1 : 0) + thistimecnt + (hicut ? 1 : 0));
      _put32(out, thistypecnt);
      _put32(out, thischarcnt);

      if (pass == 1 && !_wantBloat) {
        // Bloco mínimo com um único tipo.
        _put32(out, 0); // utoff
        out.addByte(0); // dst
        out.addByte(0); // índice da abreviação
        out.addByte(0); // abreviação vazia
        continue;
      }

      if (pass == 2 && noise && 50 < thischarcnt) {
        _warning('$name: pre-2026 reference clients mishandle'
            ' more than 50 bytes of abbreviations');
      }

      final lo = pass == 1 && loTime < _zic32Min ? _zic32Min : loTime;

      if (0 <= pretranstype) _putPass(out, lo, pass);
      for (var i = thistimei; i < thistimelim; ++i) {
        _putPass(out, ats[i], pass);
      }
      if (hicut) _putPass(out, hiTime + 1, pass);
      if (0 <= pretranstype) out.addByte(typemap[pretranstype]);
      for (var i = thistimei; i < thistimelim; i++) {
        out.addByte(typemap[types[i]]);
      }
      if (hicut) out.addByte(typemap[_unspecifiedtype]);

      for (var i = old0; i < _typecnt; i++) {
        final h = i == old0
            ? thisdefaulttype
            : i == thisdefaulttype
                ? old0
                : i;
        if (!omittype[h]) {
          _put32(out, _utoffs[h]);
          out.addByte(_isdsts[h] & 0xFF);
          out.addByte(indmap[_desigidx[h]] & 0xFF);
        }
      }
      if (thischarcnt != 0) out.add(thischars.sublist(0, thischarcnt));
      if (stdcnt != 0) {
        for (var i = old0; i < _typecnt; i++) {
          if (!omittype[i]) out.addByte(_ttisstds[i] ? 1 : 0);
        }
      }
      if (utcnt != 0) {
        for (var i = old0; i < _typecnt; i++) {
          if (!omittype[i]) out.addByte(_ttisuts[i] ? 1 : 0);
        }
      }
    }
    out.add('\n$string\n'.codeUnits);
    _output[name] = out.toBytes();
  }

  void _put32(BytesBuilder out, int val) {
    out
      ..addByte((val >> 24) & 0xFF)
      ..addByte((val >> 16) & 0xFF)
      ..addByte((val >> 8) & 0xFF)
      ..addByte(val & 0xFF);
  }

  void _putPass(BytesBuilder out, int val, int pass) {
    if (pass == 1) {
      _put32(out, val);
    } else {
      for (var shift = 56; shift >= 0; shift -= 8) {
        out.addByte((val >> shift) & 0xFF);
      }
    }
  }

  /// Abreviação (terminada em NUL) que começa em `chars[index]`.
  String _abbrAt(int index) {
    var end = index;
    while (end < _charcnt && _chars[end] != 0) {
      end++;
    }
    return String.fromCharCodes(_chars.sublist(index, end));
  }
}

class _Save {
  final int save;
  final bool isdst;
  const _Save(this.save, this.isdst);
}

class _TextCompat {
  final String text;
  final int compat;
  const _TextCompat(this.text, this.compat);
}

class _HmsScan {
  int count = 0;
  int hh = 0;
  int hhx = 0;
  int mm = 0;
  int mmx = 0;
  int ss = 0;
  int ssx = 0;
  int tenths = 0;
  int xr = 0x30; // '0'
}

class _AddAbbrResult {
  final int index;
  final int count;
  const _AddAbbrResult(this.index, this.count);
}

/// Equivalente a `addabbr`: insere [abbr] (com o NUL final) em [chs], que
/// contém [nchs] bytes de abreviações terminadas em NUL, reaproveitando
/// sufixos. Devolve o índice da abreviação e o novo tamanho.
_AddAbbrResult _addabbr(List<int> chs, int nchs, String abbr) {
  final a = abbr.codeUnits;
  final alen = a.length;
  var nchsIncr = alen + 1;
  var i = 0;
  while (i < nchs) {
    var clen = 0;
    while (chs[i + clen] != 0) {
      clen++;
    }
    if (alen <= clen) {
      // ABBR é sufixo de uma abreviação existente.
      final isuff = i + (clen - alen);
      var match = true;
      for (var k = 0; k < alen; k++) {
        if (chs[isuff + k] != a[k]) {
          match = false;
          break;
        }
      }
      if (match) return _AddAbbrResult(isuff, nchs);
    } else {
      // Uma abreviação existente é sufixo de ABBR: substitui por ABBR.
      var match = true;
      for (var k = 0; k < clen; k++) {
        if (chs[i + k] != a[alen - clen + k]) {
          match = false;
          break;
        }
      }
      if (match) {
        nchsIncr = alen - clen;
        break;
      }
    }
    i += clen + 1;
  }
  if (_tzMaxChars < nchs + nchsIncr) {
    throw ZicException('too many, or too long, time zone abbreviations');
  }
  // memmove(&chs[i + nchs_incr], &chs[i], nchs - i)
  for (var k = nchs - 1; k >= i; k--) {
    chs[k + nchsIncr] = chs[k];
  }
  // memcpy(&chs[i], abbr, nchs_incr) — copia nchs_incr bytes de ABBR
  // (incluindo o NUL final quando nchs_incr == alen + 1).
  for (var k = 0; k < nchsIncr; k++) {
    chs[i + k] = k < alen ? a[k] : 0;
  }
  return _AddAbbrResult(i, nchs + nchsIncr);
}

int _strcmp(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final c = a.codeUnitAt(i) - b.codeUnitAt(i);
    if (c != 0) return c;
  }
  return a.length - b.length;
}
