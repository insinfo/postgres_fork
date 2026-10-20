// Compara lib/src/utils/stream_channel.dart com os pacotes `stream_channel`
// 2.1.4 e `async` 2.13.0.
//
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:async/async.dart' as orig_async;
import 'package:postgres_fork/src/utils/stream_channel.dart' as mine;
import 'package:stream_channel/stream_channel.dart' as orig;
import 'package:test/test.dart';

/// Abstrai as duas implementações para que o mesmo cenário rode em ambas.
abstract class _Impl {
  dynamic channel<T>(Stream<T> stream, StreamSink<T> sink);
  dynamic closeGuarantee<T>(Stream<T> stream, StreamSink<T> sink);
  dynamic channelTransformer<S, T>(
      StreamTransformer<T, S> streamTransformer, dynamic sinkTransformer);
  dynamic channelTransformerFromCodec<S, T>(Codec<S, T> codec);
  dynamic sinkFromHandlers<S, T>({
    void Function(S, EventSink<T>)? handleData,
    void Function(Object, StackTrace, EventSink<T>)? handleError,
    void Function(EventSink<T>)? handleDone,
  });
  dynamic sinkFromStreamTransformer<S, T>(StreamTransformer<S, T> transformer);
  StreamSink<S> transformSink<S, T>(StreamSink<T> sink, dynamic transformer);
  Stream<T> subscriptionStream<T>(StreamSubscription<T> subscription);
}

class _Orig implements _Impl {
  @override
  dynamic channel<T>(Stream<T> stream, StreamSink<T> sink) =>
      orig.StreamChannel<T>(stream, sink);
  @override
  dynamic closeGuarantee<T>(Stream<T> stream, StreamSink<T> sink) =>
      orig.StreamChannel<T>.withCloseGuarantee(stream, sink);
  @override
  dynamic channelTransformer<S, T>(
          StreamTransformer<T, S> streamTransformer, dynamic sinkTransformer) =>
      orig.StreamChannelTransformer<S, T>(streamTransformer,
          sinkTransformer as orig_async.StreamSinkTransformer<S, T>);
  @override
  dynamic channelTransformerFromCodec<S, T>(Codec<S, T> codec) =>
      orig.StreamChannelTransformer<S, T>.fromCodec(codec);
  @override
  dynamic sinkFromHandlers<S, T>({
    void Function(S, EventSink<T>)? handleData,
    void Function(Object, StackTrace, EventSink<T>)? handleError,
    void Function(EventSink<T>)? handleDone,
  }) =>
      orig_async.StreamSinkTransformer<S, T>.fromHandlers(
          handleData: handleData,
          handleError: handleError,
          handleDone: handleDone);
  @override
  dynamic sinkFromStreamTransformer<S, T>(StreamTransformer<S, T> t) =>
      orig_async.StreamSinkTransformer<S, T>.fromStreamTransformer(t);
  @override
  StreamSink<S> transformSink<S, T>(StreamSink<T> sink, dynamic transformer) =>
      orig_async.StreamSinkExtensions(sink)
          .transform<S>(transformer as orig_async.StreamSinkTransformer<S, T>);
  @override
  Stream<T> subscriptionStream<T>(StreamSubscription<T> subscription) =>
      orig_async.SubscriptionStream<T>(subscription);
}

class _Mine implements _Impl {
  @override
  dynamic channel<T>(Stream<T> stream, StreamSink<T> sink) =>
      mine.StreamChannel<T>(stream, sink);
  @override
  dynamic closeGuarantee<T>(Stream<T> stream, StreamSink<T> sink) =>
      mine.StreamChannel<T>.withCloseGuarantee(stream, sink);
  @override
  dynamic channelTransformer<S, T>(
          StreamTransformer<T, S> streamTransformer, dynamic sinkTransformer) =>
      mine.StreamChannelTransformer<S, T>(
          streamTransformer, sinkTransformer as mine.StreamSinkTransformer<S, T>);
  @override
  dynamic channelTransformerFromCodec<S, T>(Codec<S, T> codec) =>
      mine.StreamChannelTransformer<S, T>.fromCodec(codec);
  @override
  dynamic sinkFromHandlers<S, T>({
    void Function(S, EventSink<T>)? handleData,
    void Function(Object, StackTrace, EventSink<T>)? handleError,
    void Function(EventSink<T>)? handleDone,
  }) =>
      mine.StreamSinkTransformer<S, T>.fromHandlers(
          handleData: handleData,
          handleError: handleError,
          handleDone: handleDone);
  @override
  dynamic sinkFromStreamTransformer<S, T>(StreamTransformer<S, T> t) =>
      mine.StreamSinkTransformer<S, T>.fromStreamTransformer(t);
  @override
  StreamSink<S> transformSink<S, T>(StreamSink<T> sink, dynamic transformer) =>
      mine.StreamSinkTransformExtension(sink)
          .transform<S>(transformer as mine.StreamSinkTransformer<S, T>);
  @override
  Stream<T> subscriptionStream<T>(StreamSubscription<T> subscription) =>
      mine.SubscriptionStream<T>(subscription);
}

/// Registra a conclusão de um future no log (valor ou erro).
void _track(List<String> log, String name, Future<dynamic> future) {
  future.then((v) => log.add('$name:done:$v'),
      onError: (Object e) => log.add('$name:error:$e'));
}

/// Cenário parecido com o da conexão v3: canal base de ints, transformado em
/// canal de Strings (com validação no sink, como o messageTransformer), mais
/// um transformer "do usuário" que observa as mensagens nos dois sentidos.
Future<List<String>> _channelScenario(_Impl impl, int seed) async {
  final random = Random(seed);
  final log = <String>[];
  var tick = 0;
  void ticks() {
    for (var i = random.nextInt(3); i > 0; i--) {
      scheduleMicrotask(() => log.add('tick${tick++}'));
    }
  }

  final incoming = StreamController<int>(
      sync: random.nextBool(),
      onListen: () => log.add('incoming:listen'),
      onPause: () => log.add('incoming:pause'),
      onResume: () => log.add('incoming:resume'),
      onCancel: () => log.add('incoming:cancel'));
  final outgoing = StreamController<int>(sync: random.nextBool());
  // ignore: cancel_subscriptions
  final outgoingSubscription = outgoing.stream.listen(
      (v) => log.add('socket:data:$v'),
      onError: (Object e) => log.add('socket:error:$e'),
      onDone: () => log.add('socket:done'));
  if (random.nextInt(4) == 0) outgoingSubscription.pause();

  var channel = impl.channel<int>(incoming.stream, outgoing.sink);

  // Transformer de protocolo (int <-> String).
  channel = channel.transform(impl.channelTransformer<String, int>(
    StreamTransformer<int, String>.fromHandlers(
      handleData: (value, sink) {
        if (value % 7 == 0) {
          sink.addError(StateError('bad incoming $value'));
        } else {
          sink.add('in$value');
        }
      },
    ),
    impl.sinkFromHandlers<String, int>(
      handleData: (message, out) {
        if (message.startsWith('x')) {
          out.addError(ArgumentError.value(message, 'message', 'invalid'),
              StackTrace.current);
          return;
        }
        out.add(message.length);
      },
    ),
  ));

  // Transformer "do usuário".
  if (random.nextBool()) {
    channel = channel.transform(impl.channelTransformer<String, String>(
      StreamTransformer<String, String>.fromHandlers(handleData: (msg, sink) {
        log.add('user:in:$msg');
        sink.add(msg);
      }),
      impl.sinkFromHandlers<String, String>(handleData: (msg, sink) {
        log.add('user:out:$msg');
        sink.add(msg);
      }),
    ));
  }

  StreamSubscription<String>? subscription;
  final stream = channel.stream as Stream<String>;
  final sink = channel.sink as StreamSink<String>;
  _track(log, 'sink.done', sink.done);

  final actions = 5 + random.nextInt(25);
  var closedIncoming = false;
  var closedSink = false;
  for (var i = 0; i < actions; i++) {
    ticks();
    switch (random.nextInt(10)) {
      case 0:
        if (subscription == null) {
          subscription = stream.listen((v) => log.add('client:data:$v'),
              onError: (Object e) => log.add('client:error:$e'),
              onDone: () => log.add('client:done'),
              cancelOnError: random.nextInt(4) == 0);
          log.add('client:listen');
        }
        break;
      case 1:
      case 2:
        if (!closedIncoming) incoming.add(random.nextInt(50));
        break;
      case 3:
        if (!closedIncoming && random.nextInt(3) == 0) {
          incoming.addError(StateError('socket error $i'));
        }
        break;
      case 4:
      case 5:
        if (!closedSink) {
          sink.add(random.nextInt(5) == 0 ? 'x$i' : 'msg$i');
        }
        break;
      case 6:
        if (!closedSink && random.nextInt(4) == 0) {
          sink.addError(StateError('client error $i'));
        }
        break;
      case 7:
        if (subscription != null && random.nextBool()) {
          if (subscription.isPaused) {
            subscription.resume();
          } else {
            subscription.pause();
          }
          log.add('client:paused=${subscription.isPaused}');
        }
        break;
      case 8:
        if (!closedSink && random.nextInt(5) == 0) {
          closedSink = true;
          _track(log, 'sink.close', sink.close());
        }
        break;
      case 9:
        if (!closedIncoming && random.nextInt(5) == 0) {
          closedIncoming = true;
          _track(log, 'incoming.close', incoming.close());
        }
        break;
    }
    if (random.nextBool()) await Future<void>.value();
  }

  subscription ??= stream.listen((v) => log.add('client:data:$v'),
      onError: (Object e) => log.add('client:error:$e'),
      onDone: () => log.add('client:done'));
  if (subscription.isPaused) subscription.resume();
  if (outgoingSubscription.isPaused) outgoingSubscription.resume();
  if (!closedSink) _track(log, 'sink.close', sink.close());
  if (!closedIncoming) _track(log, 'incoming.close', incoming.close());
  await Future<void>.delayed(const Duration(milliseconds: 2));
  await outgoingSubscription.cancel();
  await subscription.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 2));
  return log;
}

/// Cenário do socket da conexão v3: SubscriptionStream sobre uma inscrição já
/// existente e um sink com handleDone que destrói o socket.
Future<List<String>> _socketScenario(_Impl impl, int seed) async {
  final random = Random(seed);
  final log = <String>[];

  final socket = StreamController<int>(
      onPause: () => log.add('socket:pause'),
      onResume: () => log.add('socket:resume'),
      onCancel: () => log.add('socket:cancel'));
  // ignore: cancel_subscriptions
  final early = socket.stream.listen((v) => log.add('early:$v'));
  socket.add(1);
  await Future<void>.value();

  final adapted = impl.subscriptionStream<int>(early);
  for (var i = 0; i < random.nextInt(4); i++) {
    socket.add(10 + i);
  }
  if (random.nextBool()) socket.addError(StateError('e1'));

  final cancelOnError = random.nextBool();
  // ignore: cancel_subscriptions
  final subscription = adapted.listen((v) => log.add('data:$v'),
      onError: random.nextBool()
          ? (Object e) => log.add('error1:$e')
          : (Object e, StackTrace s) => log.add('error2:$e'),
      onDone: () => log.add('done'),
      cancelOnError: cancelOnError);
  try {
    adapted.listen(null);
  } catch (e) {
    log.add('second listen: $e');
  }

  for (var i = 0; i < random.nextInt(4); i++) {
    socket.add(20 + i);
    if (random.nextBool()) await Future<void>.value();
  }
  if (random.nextBool()) socket.addError(StateError('e2'));
  socket.add(30);
  _track(log, 'socket.close', socket.close());

  // Sink de saída: handleDone fecha (e loga) o destino.
  final out = StreamController<int>();
  out.stream.listen((v) => log.add('out:data:$v'),
      onError: (Object e) => log.add('out:error:$e'),
      onDone: () => log.add('out:done'));
  final failingClose = random.nextInt(3) == 0;
  final StreamSink<int> target =
      failingClose ? _FailingCloseSink(out.sink, log) : out.sink;
  final outgoing = impl.transformSink<int, int>(
      target,
      impl.sinkFromHandlers<int, int>(handleDone: (sink) {
        log.add('handleDone');
        sink.close();
      }));
  outgoing.add(5);
  outgoing.addError(StateError('out error'));
  if (random.nextBool()) {
    _track(log, 'addStream',
        outgoing.addStream(Stream.fromIterable([6, 7])));
    await Future<void>.delayed(Duration.zero);
  }
  _track(log, 'outgoing.close', outgoing.close());
  _track(log, 'outgoing.done', outgoing.done);

  await Future<void>.delayed(const Duration(milliseconds: 2));
  await subscription.cancel();
  log.add('isPaused=${subscription.isPaused}');
  return log;
}

class _FailingCloseSink implements StreamSink<int> {
  final StreamSink<int> _inner;
  final List<String> _log;
  _FailingCloseSink(this._inner, this._log);

  @override
  void add(int event) => _inner.add(event);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<int> stream) => _inner.addStream(stream);
  @override
  Future close() {
    _log.add('failingClose');
    _inner.close();
    return Future<void>.error(StateError('close failed'));
  }

  @override
  Future get done => _inner.done;
}

/// Garantia de fechamento e demais operações do canal.
Future<List<String>> _closeGuaranteeScenario(_Impl impl, int seed) async {
  final random = Random(seed);
  final log = <String>[];
  final incoming = StreamController<int>();
  final outgoing = StreamController<int>();
  outgoing.stream.listen((v) => log.add('out:$v'),
      onDone: () => log.add('out:done'));

  final channel = impl.closeGuarantee<int>(incoming.stream, outgoing.sink);
  final listenFirst = random.nextBool();
  void listen() {
    (channel.stream as Stream<int>).listen((v) => log.add('in:$v'),
        onError: (Object e) => log.add('in:error:$e'),
        onDone: () => log.add('in:done'));
  }

  if (listenFirst) listen();
  incoming.add(1);
  (channel.sink as StreamSink<int>).add(2);
  await Future<void>.value();
  _track(log, 'close', (channel.sink as StreamSink<int>).close());
  incoming.add(3);
  incoming.addError(StateError('after close'));
  if (!listenFirst) listen();
  _track(log, 'incoming.close', incoming.close());
  await Future<void>.delayed(const Duration(milliseconds: 2));
  return log;
}

/// fromCodec, fromStreamTransformer, changeStream/changeSink, transformStream,
/// transformSink, cast e pipe.
Future<List<String>> _miscScenario(_Impl impl, int seed) async {
  final random = Random(seed);
  final log = <String>[];

  // fromCodec (utf8) sobre um canal de bytes.
  final bytesIn = StreamController<List<int>>();
  final bytesOut = StreamController<List<int>>();
  bytesOut.stream.listen((v) => log.add('bytesOut:$v'),
      onDone: () => log.add('bytesOut:done'));
  final textChannel = impl
      .channel<List<int>>(bytesIn.stream, bytesOut.sink)
      .transform(impl.channelTransformerFromCodec<String, List<int>>(utf8));
  (textChannel.stream as Stream<String>).listen((v) => log.add('text:$v'),
      onError: (Object e) => log.add('text:error:${e.runtimeType}'),
      onDone: () => log.add('text:done'));
  bytesIn.add(utf8.encode('olá '));
  bytesIn.add([0xC3]);
  bytesIn.add([0xA9]);
  if (random.nextBool()) bytesIn.add([0xFF]);
  (textChannel.sink as StreamSink<String>).add('ação');
  _track(log, 'text.close', (textChannel.sink as StreamSink<String>).close());
  _track(log, 'bytesIn.close', bytesIn.close());

  // fromStreamTransformer.
  final target = StreamController<String>();
  target.stream.listen((v) => log.add('target:$v'),
      onError: (Object e) => log.add('target:error:$e'),
      onDone: () => log.add('target:done'));
  final mapped = impl.transformSink<int, String>(
      target.sink,
      impl.sinkFromStreamTransformer<int, String>(
          StreamTransformer.fromHandlers(handleData: (v, s) => s.add('#$v'))));
  mapped.add(1);
  mapped.addError(StateError('mapped error'));
  _track(log, 'mapped.addStream', mapped.addStream(Stream.fromIterable([2, 3])));
  await Future<void>.delayed(Duration.zero);
  _track(log, 'mapped.close', mapped.close());

  // changeStream / changeSink / transformStream / transformSink / cast.
  final aIn = StreamController<int>();
  final aOut = StreamController<int>();
  aOut.stream.listen((v) => log.add('aOut:$v'), onDone: () => log.add('aOut:done'));
  dynamic channel = impl.channel<int>(aIn.stream, aOut.sink);
  channel = channel.changeStream((Stream<int> s) => s.map((v) => v * 2));
  channel = channel.changeSink((StreamSink<int> s) => impl.transformSink<int, int>(
      s, impl.sinkFromHandlers<int, int>(handleData: (v, o) => o.add(v + 1))));
  channel = channel.transformStream(
      StreamTransformer<int, int>.fromHandlers(handleData: (v, s) => s.add(-v)));
  channel = channel.transformSink(impl.sinkFromHandlers<int, int>(
      handleData: (v, o) => o.add(v * 10)));
  final casted = channel.cast<num>();
  (casted.stream as Stream<num>).listen((v) => log.add('casted:$v'),
      onDone: () => log.add('casted:done'));
  (casted.sink as StreamSink<num>).add(4);
  aIn.add(5);
  await Future<void>.delayed(Duration.zero);
  _track(log, 'casted.close', (casted.sink as StreamSink<num>).close());
  _track(log, 'aIn.close', aIn.close());

  // pipe entre dois canais.
  final leftIn = StreamController<int>();
  final leftOut = StreamController<int>();
  final rightIn = StreamController<int>();
  final rightOut = StreamController<int>();
  leftOut.stream.listen((v) => log.add('leftOut:$v'),
      onDone: () => log.add('leftOut:done'));
  rightOut.stream.listen((v) => log.add('rightOut:$v'),
      onDone: () => log.add('rightOut:done'));
  impl
      .channel<int>(leftIn.stream, leftOut.sink)
      .pipe(impl.channel<int>(rightIn.stream, rightOut.sink));
  leftIn.add(1);
  rightIn.add(2);
  await Future<void>.delayed(Duration.zero);
  _track(log, 'leftIn.close', leftIn.close());
  _track(log, 'rightIn.close', rightIn.close());

  await Future<void>.delayed(const Duration(milliseconds: 2));
  return log;
}

/// Executa o cenário em uma zona que captura erros não tratados, que também
/// fazem parte do comportamento observado.
Future<List<String>> _run(
    Future<List<String>> Function(_Impl, int) scenario, _Impl impl, int seed) {
  final completer = Completer<List<String>>();
  final uncaught = <String>[];
  runZonedGuarded(() async {
    final log = await scenario(impl, seed);
    completer.complete([...log, ...uncaught.map((e) => 'uncaught:$e')]);
  }, (error, stack) {
    uncaught.add('$error');
  });
  return completer.future;
}

void main() {
  final scenarios = <String, Future<List<String>> Function(_Impl, int)>{
    'canal com transformers (fluxo da conexão v3)': _channelScenario,
    'SubscriptionStream e sink com handleDone (socket v3)': _socketScenario,
    'withCloseGuarantee': _closeGuaranteeScenario,
    'fromCodec, fromStreamTransformer, change*, transform*, cast e pipe':
        _miscScenario,
  };
  scenarios.forEach((name, scenario) {
    test(name, () async {
      final seeds = name.startsWith('canal') ? 2000 : 300;
      for (var seed = 0; seed < seeds; seed++) {
        final expected = await _run(scenario, _Orig(), seed);
        final actual = await _run(scenario, _Mine(), seed);
        expect(actual, expected, reason: 'seed $seed');
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
