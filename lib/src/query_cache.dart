import 'query.dart';

/// Cache de prepared statements de uma conexão (chave: SQL).
///
/// Com [maxSize], guarda no máximo esse número de statements: ao passar do
/// limite, o usado há mais tempo é removido e o nome dele entra em
/// [takePendingCloses], para que a conexão envie um `Close` ao servidor antes
/// do próximo `Parse`.
class QueryCache {
  QueryCache({this.maxSize});

  /// Número máximo de statements (null = sem limite).
  final int? maxSize;

  final Map<String, CachedQuery> _queries = {};
  final List<String> _pendingCloses = [];
  int _idCounter = 0;

  int get length => _queries.length;
  bool get isEmpty => _queries.isEmpty;

  void add(Query<dynamic> query) {
    if (query.cache == null) {
      return;
    }

    if (query.cache!.isValid) {
      _queries.remove(query.statement);
      _queries[query.statement] = query.cache!;
      final max = maxSize;
      if (max != null) {
        while (_queries.length > max) {
          final oldest = _queries.keys.first;
          final evicted = _queries.remove(oldest)!;
          _pendingCloses.add(evicted.preparedStatementName!);
        }
      }
    }
  }

  CachedQuery? operator [](String? statementId) {
    if (statementId == null) {
      return null;
    }

    final cached = _queries[statementId];
    if (cached != null && maxSize != null) {
      // Marca como usado recentemente.
      _queries.remove(statementId);
      _queries[statementId] = cached;
    }
    return cached;
  }

  String identifierForQuery(Query<dynamic> query) {
    final existing = _queries[query.statement];
    if (existing != null) {
      return existing.preparedStatementName!;
    }

    final string = '$_idCounter'.padLeft(12, '0');

    _idCounter++;

    return string;
  }

  /// Nomes de statements removidos do cache que ainda precisam ser fechados
  /// no servidor. A lista é esvaziada.
  List<String> takePendingCloses() {
    if (_pendingCloses.isEmpty) return const [];
    final result = List<String>.of(_pendingCloses);
    _pendingCloses.clear();
    return result;
  }
}
