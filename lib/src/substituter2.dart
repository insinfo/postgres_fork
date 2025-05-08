//lib\src\substituter2.dart
extension AppendToEnd on List {
  void replaceLast(dynamic item) {
    if (length == 0) {
      add(item);
    } else {
      this[length - 1] = item;
    }
  }

  /// like python index function
  /// Example: var placeholders = ['a','b','c','d','e'];
  /// pidx = placeholders.index(placeholders[-1],0,-1);
  /// Exception: ValueError: 'e' is not in list
  int indexWithEnd(Object? element, [int start = 0, int? stop]) {
    if (start < 0) start = 0;

    if (stop != null && stop < 0) stop = length - 1;

    for (int i = start; i < (stop ?? length); i++) {
      if (this[i] == element) return i;
    }
    throw Exception("ValueError: '$element' is not in list");
  }
}

/// outside quoted string
const OUTSIDE = 0;

/// inside single-quote string '...'
const INSIDE_SQ = 1;

/// inside quoted identifier   "..."
const INSIDE_QI = 2;

/// inside escaped single-quote string, E'...'
const INSIDE_ES = 3;

/// inside parameter name eg. :name
const INSIDE_PN = 4;

/// inside inline comment eg. --
const INSIDE_CO = 5;

/// The isalnum() method returns True if all characters in the string are alphanumeric (either alphabets or numbers). If not, it returns False.
bool isalnum(String? s) {
  // alphanumeric
  final validCharacters = RegExp(r'^[a-zA-Z0-9]+$');
  if (s == null) {
    return false;
  }
  return validCharacters.hasMatch(s);
}

/// the toStatement function is used to replace the 'placeholderIdentifier' to  '$#' for postgres sql statement style
/// Example: "INSERT INTO book (title) VALUES (:title)" to "INSERT INTO book (title) VALUES ($1)"
/// [placeholderIdentifier] placeholder identifier character represents the pattern that will be
///  replaced in the execution of the query by the supplied parameters
/// [params] parameters can be a list or a map
/// `Returns` [ String query,  List<dynamic> Function(dynamic) make_vals ]
/// Postgres uses $# for placeholders https://www.postgresql.org/docs/9.1/sql-prepare.html
List toStatement(String query, Map params,
    {String placeholderIdentifier = ':'}) {
  var inQuoteEscape = false;
  final placeholders = [];
  final outputQuery = [];
  var state = OUTSIDE;
  // ignore: prefer_typing_uninitialized_variables
  var prevC;
  String? nextC;

  //add space to end
  final splitString = '$query  '.split('');
  for (var i = 0; i < splitString.length; i++) {
    final c = splitString[i];

    if (i + 1 < splitString.length) {
      nextC = splitString[i + 1];
    } else {
      nextC = null;
    }

    if (state == OUTSIDE) {
      if (c == "'") {
        outputQuery.add(c);
        if (prevC == 'E') {
          state = INSIDE_ES;
        } else {
          state = INSIDE_SQ;
        }
      } else if (c == '"') {
        outputQuery.add(c);
        state = INSIDE_QI;
      } else if (c == '-') {
        outputQuery.add(c);
        if (prevC == '-') {
          state = INSIDE_CO;
        }

        //ignore operator @@ or := :: @= ?? ?=
      } else if (c == placeholderIdentifier &&
          '$placeholderIdentifier='.contains(nextC ?? '') == false &&
          '$placeholderIdentifier$placeholderIdentifier'
                  .contains(nextC ?? '') ==
              false &&
          prevC != placeholderIdentifier) {
        state = INSIDE_PN;
        placeholders.add('');
      } else {
        outputQuery.add(c);
      }
    }
    //
    else if (state == INSIDE_SQ) {
      if (c == "'") {
        if (inQuoteEscape) {
          inQuoteEscape = false;
        } else if (nextC == "'") {
          inQuoteEscape = true;
        } else {
          state = OUTSIDE;
        }
      }
      outputQuery.add(c);
    }
    //
    else if (state == INSIDE_QI) {
      if (c == '"') {
        state = OUTSIDE;
      }
      outputQuery.add(c);
    }
    //
    else if (state == INSIDE_ES) {
      if (c == "'" && prevC != '\\') {
        // check for escaped single-quote
        state = OUTSIDE;
      }
      outputQuery.add(c);
    }
    //
    else if (state == INSIDE_PN) {
      placeholders.replaceLast(placeholders.last + c);

      if (nextC == null || (!isalnum(nextC) && nextC != '_')) {
        state = OUTSIDE;
        try {
          final pidx = placeholders.indexWithEnd(placeholders.last, 0, -1);

          outputQuery.add('\$${pidx + 1}');
          //del placeholders[-1]
          placeholders.removeLast();
        } catch (_) {
          outputQuery.add('\$${placeholders.length}');
        }
      }
    }
    //
    else if (state == INSIDE_CO) {
      outputQuery.add(c);
      if (c == '\n') {
        state = OUTSIDE;
      }
    }
    prevC = c;
  }

  for (var reserved in ['types', 'stream']) {
    if (placeholders.contains(reserved)) {
      throw Exception(
          "The name '$reserved' can't be used as a placeholder because it's "
          'used for another purpose.');
    }
  }

  /// [args]
  // ignore: non_constant_identifier_names
  make_vals(Map args) {
    final vals = [];
    for (var p in placeholders) {
      try {
        vals.add(args[p]);
      } catch (_) {
        throw Exception(
            "There's a placeholder '$p' in the query, but no matching "
            'keyword argument.');
      }
    }
    return vals;
  }

  var resultQuery = outputQuery.join('');
  //resultQuery = resultQuery.substring(0, resultQuery.length - 1);
  resultQuery = resultQuery.trim();
  return [resultQuery, make_vals(params)];
}

/// the toStatement2 function is used to replace the Question mark '?' to  '$1' for sql statement
/// "INSERT INTO book (title) VALUES (?)" to "INSERT INTO book (title) VALUES ($1)"
/// `Returns` [ String query,  List<dynamic> Function(dynamic) make_vals ]
/// Postgres uses $# for placeholders https://www.postgresql.org/docs/9.1/sql-prepare.html
String toStatement2Old(String query) {
  final placeholderIdentifier = '?';
  var inQuoteEscape = false;
  // var placeholders = [];
  final outputQuery = [];
  var state = OUTSIDE;
  var paramCount = 1;
  //character anterior

  String? prevC;
  String? nextC;

  //add space to end of string to force INSIDE_PN;
  final splitString = '$query  '.split('');
  for (var i = 0; i < splitString.length; i++) {
    final c = splitString[i];

    if (i + 1 < splitString.length) {
      nextC = splitString[i + 1];
    } else {
      nextC = null;
    }

    if (state == OUTSIDE) {
      if (c == "'") {
        outputQuery.add(c);
        if (prevC == 'E') {
          state = INSIDE_ES;
        } else {
          state = INSIDE_SQ;
        }
      } else if (c == '"') {
        outputQuery.add(c);
        state = INSIDE_QI;
      } else if (c == '-') {
        outputQuery.add(c);
        if (prevC == '-') {
          state = INSIDE_CO;
        }
        //ignore operator @@ or := :: @= ?? ?=
      } else if (c == placeholderIdentifier && prevC != placeholderIdentifier) {
        state = INSIDE_PN;

        // placeholders.add("");
        outputQuery.add('\$$paramCount');
        paramCount++;
      } else {
        outputQuery.add(c);
      }
    }
    //
    else if (state == INSIDE_SQ) {
      if (c == "'") {
        if (inQuoteEscape) {
          inQuoteEscape = false;
        } else if (nextC == "'") {
          inQuoteEscape = true;
        } else {
          state = OUTSIDE;
        }
      }
      outputQuery.add(c);
    }
    //
    else if (state == INSIDE_QI) {
      if (c == '"') {
        state = OUTSIDE;
      }
      outputQuery.add(c);
    }
    //
    else if (state == INSIDE_ES) {
      if (c == "'" && prevC != '\\') {
        // check for escaped single-quote
        state = OUTSIDE;
      }
      outputQuery.add(c);
    }
    //
    else if (state == INSIDE_PN) {
      if (nextC == null || (!isalnum(nextC) && nextC != '_')) {
        state = OUTSIDE;
      }

      outputQuery.add(c);
    }
    //
    else if (state == INSIDE_CO) {
      outputQuery.add(c);
      if (c == '\n') {
        state = OUTSIDE;
      }
    }
    prevC = c;
  }

  final resultQuery = outputQuery.join('');
  //resultQuery = resultQuery.substring(0, resultQuery.length - 1);
  return resultQuery.trim();
}

// feito pelo g
String toStatement2G(String query) {
  final placeholderIdentifier = '?';
  final questionMarkCodeUnit = placeholderIdentifier.codeUnitAt(0);
  final colonCodeUnit = ':'.codeUnitAt(0);
  final equalsCodeUnit = '='.codeUnitAt(0);
  final openParenCodeUnit = '('.codeUnitAt(0);

  var inQuoteEscape = false;
  final outputQuery = StringBuffer();
  var state = OUTSIDE;
  var paramCount = 1;
  int? prevPrevCUnit; // Para verificar ::?
  int? prevCUnit;
  final codeUnits = query.codeUnits;

  for (var i = 0; i < codeUnits.length; i++) {
    final cUnit = codeUnits[i];
    final c = String.fromCharCode(cUnit);
    final nextCUnit = (i + 1 < codeUnits.length) ? codeUnits[i + 1] : null;

    switch (state) {
      case OUTSIDE:
        if (cUnit == "'".codeUnitAt(0)) {
          outputQuery.write(c);
          // Usa prevCUnit para verificar 'E'
          state = (prevCUnit == 'E'.codeUnitAt(0)) ? INSIDE_ES : INSIDE_SQ;
        } else if (cUnit == '"'.codeUnitAt(0)) {
          outputQuery.write(c);
          state = INSIDE_QI;
        } else if (cUnit == '-'.codeUnitAt(0)) {
          outputQuery.write(c);
          // Usa prevCUnit para verificar '--'
          if (prevCUnit == '-'.codeUnitAt(0)) {
            state = INSIDE_CO;
          }
        } else if (cUnit == questionMarkCodeUnit) {
          // --- Lógica de Verificação de Operador ---
          final isOperator =
              // Precedido por '?' (??)
              (prevCUnit == questionMarkCodeUnit) ||
                  // Seguido por '?' (??)
                  (nextCUnit == questionMarkCodeUnit) ||
                  // Seguido por '=' (?=)
                  (nextCUnit == equalsCodeUnit) ||
                  // Seguido por '(' (?( )
                  (nextCUnit == openParenCodeUnit) ||
                  // Precedido por '::' (::?)
                  (prevCUnit == colonCodeUnit &&
                      prevPrevCUnit == colonCodeUnit);
          // --- Fim da Lógica ---

          if (!isOperator) {
            // É um placeholder real
            outputQuery.write('\$$paramCount');
            paramCount++;
          } else {
            // Faz parte de um operador, mantenha o '?'
            outputQuery.write(c);
          }
        } else {
          outputQuery.write(c);
        }
        break;

      case INSIDE_SQ:
        outputQuery.write(c);
        if (cUnit == "'".codeUnitAt(0)) {
          if (inQuoteEscape) {
            inQuoteEscape = false;
          } else if (nextCUnit == "'".codeUnitAt(0)) {
            inQuoteEscape = true;
          } else {
            state = OUTSIDE;
          }
        }
        break;

      case INSIDE_QI:
        outputQuery.write(c);
        if (cUnit == '"'.codeUnitAt(0)) {
          state = OUTSIDE;
        }
        break;

      case INSIDE_ES:
        outputQuery.write(c);
        // Apenas sai se for um ' não precedido por \
        if (cUnit == "'".codeUnitAt(0) && prevCUnit != '\\'.codeUnitAt(0)) {
          state = OUTSIDE;
        }
        break;

      case INSIDE_CO:
        outputQuery.write(c);
        if (cUnit == '\n'.codeUnitAt(0)) {
          state = OUTSIDE;
        }
        break;
    }
    // Atualiza os caracteres anteriores ANTES de mudar de estado no próximo loop
    prevPrevCUnit = prevCUnit;
    prevCUnit = cUnit;
  }

  return outputQuery.toString();
}


const INSIDE_CO_SL = 4; // -- ... \n
const INSIDE_CO_ML = 5; // /* ... */
const INSIDE_DOLLAR = 6; // $$...$$ ou $tag$...$tag$

// mais robusto
/// the toStatement2 function is used to replace the Question mark '?' to  '$1' for sql statement
/// "INSERT INTO book (title) VALUES (?)" to "INSERT INTO book (title) VALUES ($1)"
/// `Returns` [ String query,  List<dynamic> Function(dynamic) make_vals ]
/// Postgres uses $# for placeholders https://www.postgresql.org/docs/9.1/sql-prepare.html
String toStatement2(String query) {
  /* —— caractere “?” e código unit —— */
  const question  = '?';
  const qUnit     = 63;  // '?'
  const colonUnit = 58;  // ':'

  /* —— segundo caractere que forma operadores iniciados por “?” (adjacente) —— */
  final operatorNext = <int>{
    qUnit,                      // ??
    '='.codeUnitAt(0),          // ?=
    '('.codeUnitAt(0),          // ?(
    '|'.codeUnitAt(0),          // ?|
    '&'.codeUnitAt(0),          // ?&
    '#'.codeUnitAt(0),          // ?#
    '-'.codeUnitAt(0),          // ?-
    '@'.codeUnitAt(0),          // ?@
  };

  /* —— dollar-quoted opener: $$ ou $tag$ —— */
  final dollarTagReg = RegExp(r'^\$([A-Za-z0-9_]*)\$');

  final out   = StringBuffer();
  var   state = OUTSIDE;
  var   param = 1;

  int? prevUnit, prevPrevUnit;          // caracteres adjacentes já emitidos
  String? currentDollarTag;             // fecha $tag$

  final units = query.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u  = units[i];
    final ch = String.fromCharCode(u);

    final nextUnit = (i + 1 < units.length) ? units[i + 1] : null;

    switch (state) {
      /* ───────────────────────────── OUTSIDE ───────────────────────────── */
      case OUTSIDE:
        if (u == "'".codeUnitAt(0)) {             // '...'
          out.write(ch);
          state = (prevUnit == 'E'.codeUnitAt(0)) ? INSIDE_ES : INSIDE_SQ;

        } else if (u == '"'.codeUnitAt(0)) {      // "..."
          out.write(ch);
          state = INSIDE_QI;

        } else if (u == r'$'.codeUnitAt(0)) {     // $$…$$  ou  $tag$…$tag$
          final rest = query.substring(i);        // string a partir de i
          final m    = dollarTagReg.firstMatch(rest);
          if (m != null) {
            final opener = '\$${m[1]!}\$';
            out.write(opener);
            currentDollarTag = opener;
            state = INSIDE_DOLLAR;
            i += opener.length - 1;               // já consumimos opener
          } else {                               // apenas um '$' isolado
            out.write(ch);
          }

        } else if (u == '-'.codeUnitAt(0) &&      // -- comentário
                   prevUnit == '-'.codeUnitAt(0)) {
          out.write(ch);
          state = INSIDE_CO_SL;

        } else if (u == '/'.codeUnitAt(0) &&      // /* comentário */
                   nextUnit == '*'.codeUnitAt(0)) {
          out.write('/*');
          state = INSIDE_CO_ML;
          i++;                                   // pula '*'

        } else if (u == qUnit) {                 // ?  operador ou placeholder
          final isOperator =
              (prevUnit == qUnit) ||                             // ??
              (nextUnit != null && operatorNext.contains(nextUnit)) ||
              (prevUnit == colonUnit && prevPrevUnit == colonUnit); // ::?

          if (isOperator) {
            out.write(question);
          } else {
            out.write('\$$param');
            param++;
          }

        } else {                                 // caractere comum
          out.write(ch);
        }
        break;

      /* ───────────────────────────── STRINGS ───────────────────────────── */
      case INSIDE_SQ:   // string simples '...'
        out.write(ch);
        if (u == "'".codeUnitAt(0)) {
          if (nextUnit == "'".codeUnitAt(0)) {      // ''   → mantém escape
            out.write("'");
            i++;
          } else {
            state = OUTSIDE;
          }
        }
        break;

      case INSIDE_ES:   // E'...'
        out.write(ch);
        if (u == "'".codeUnitAt(0) && prevUnit != r'\'.codeUnitAt(0)) {
          state = OUTSIDE;
        }
        break;

      case INSIDE_QI:   // identificador "..."
        out.write(ch);
        if (u == '"'.codeUnitAt(0)) state = OUTSIDE;
        break;

      /* ─────────────────────────── COMENTÁRIOS ─────────────────────────── */
      case INSIDE_CO_SL:               // -- … \n
        out.write(ch);
        if (u == '\n'.codeUnitAt(0)) state = OUTSIDE;
        break;

      case INSIDE_CO_ML:               // /* … */
        out.write(ch);
        if (u == '*'.codeUnitAt(0) && nextUnit == '/'.codeUnitAt(0)) {
          out.write('/');
          i++;
          state = OUTSIDE;
        }
        break;

      /* ───────────────────────── DOLLAR-QUOTED ─────────────────────────── */
      case INSIDE_DOLLAR:
        out.write(ch);
        if (u == r'$'.codeUnitAt(0) &&
            query.startsWith(currentDollarTag!, i)) {
          // já escrevemos '$'; faltam (tag)$
          out.write(currentDollarTag.substring(1));
          i    += currentDollarTag.length - 1;
          state = OUTSIDE;
          currentDollarTag = null;
        }
        break;
    }

    /* —— histórico —— */
    prevPrevUnit = prevUnit;
    prevUnit     = u;
  }

  return out.toString();
}