import 'dart:async';

import 'package:postgres_fork/src/utils/stream_channel.dart';
import 'package:test/test.dart';

void main() {
  test('StreamChannelTransformer transforma os dois sentidos', () async {
    final incoming = StreamController<int>();
    final outgoing = StreamController<int>();
    final sent = <int>[];
    outgoing.stream.listen(sent.add);

    final channel = StreamChannel<int>(incoming.stream, outgoing.sink)
        .transform(StreamChannelTransformer<String, int>(
      StreamTransformer.fromHandlers(
          handleData: (value, sink) => sink.add('v$value')),
      StreamSinkTransformer.fromHandlers(
          handleData: (value, sink) => sink.add(value.length)),
    ));

    final received = <String>[];
    channel.stream.listen(received.add);
    incoming
      ..add(1)
      ..add(2);
    channel.sink
      ..add('abc')
      ..add('');
    await Future<void>.delayed(Duration.zero);
    expect(received, ['v1', 'v2']);
    expect(sent, [3, 0]);
  });

  test('fechar o sink encerra o stream (withCloseGuarantee)', () async {
    final incoming = StreamController<int>();
    final outgoing = StreamController<int>();
    outgoing.stream.listen(null);
    final channel =
        StreamChannel<int>.withCloseGuarantee(incoming.stream, outgoing.sink);
    final received = <int>[];
    final done = Completer<void>();
    channel.stream.listen(received.add, onDone: done.complete);

    incoming.add(1);
    await Future<void>.delayed(Duration.zero);
    await channel.sink.close();
    incoming.add(2);
    unawaited(incoming.close());
    await done.future;
    expect(received, [1]);
  });

  test('StreamSinkTransformer.fromHandlers: handleDone e erros', () async {
    final target = StreamController<int>();
    final events = <String>[];
    target.stream.listen((v) => events.add('data:$v'),
        onError: (Object e) => events.add('error:$e'),
        onDone: () => events.add('done'));

    final sink = target.sink.transform(StreamSinkTransformer<int, int>.fromHandlers(
      handleError: (error, stackTrace, sink) => sink.add(-1),
      handleDone: (sink) {
        events.add('handleDone');
        sink.close();
      },
    ));
    sink
      ..add(1)
      ..addError(StateError('x'));
    await sink.close();
    // handleDone roda de forma síncrona em close(); o StreamController de
    // destino entrega os eventos de forma assíncrona (mesmo comportamento do
    // pacote async).
    expect(events, ['handleDone', 'data:1', 'data:-1', 'done']);
  });

  test('SubscriptionStream entrega eventos recebidos antes do listen', () async {
    final source = StreamController<int>();
    // ignore: cancel_subscriptions
    final early = source.stream.listen(null);
    final stream = SubscriptionStream(early);
    source
      ..add(1)
      ..add(2);
    unawaited(source.close());

    expect(await stream.toList(), [1, 2]);
    expect(() => stream.listen(null), throwsStateError);
  });

  test('SubscriptionStream com cancelOnError cancela no primeiro erro',
      () async {
    var cancelled = false;
    final source = StreamController<int>(onCancel: () => cancelled = true);
    // ignore: cancel_subscriptions
    final early = source.stream.listen(null);
    final events = <String>[];
    SubscriptionStream(early).listen((v) => events.add('data:$v'),
        onError: (Object e) => events.add('error'), cancelOnError: true);
    source
      ..add(1)
      ..addError(StateError('x'))
      ..add(2);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['data:1', 'error']);
    expect(cancelled, isTrue);
  });
}
