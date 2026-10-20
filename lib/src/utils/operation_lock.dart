import 'dart:async';
import 'dart:collection';

/// Trava assíncrona de exclusão mútua com fila FIFO.
///
/// Substitui o uso de `Pool(1)` do pacote `pool` (que tinha apenas um recurso
/// e era usado só via [withResource]) mantendo a mesma semântica:
///
/// * se a trava está livre, ela é adquirida imediatamente (a continuação roda
///   numa microtask, assim como `await Future.value(...)`);
/// * caso contrário, o pedido entra no fim da fila e é atendido, na ordem de
///   chegada, quando a operação anterior terminar;
/// * a trava é sempre liberada ao fim do callback, mesmo que ele lance um
///   erro (síncrono ou assíncrono), e o erro é repassado ao chamador.
class OperationLock {
  final _waiters = Queue<Completer<void>>();
  bool _locked = false;

  /// Executa [callback] quando a trava estiver disponível e a libera ao fim.
  Future<T> withResource<T>(FutureOr<T> Function() callback) async {
    await _acquire();
    try {
      return await callback();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (!_locked) {
      _locked = true;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // A trava passa diretamente para o próximo da fila.
      _waiters.removeFirst().complete();
    } else {
      _locked = false;
    }
  }
}
