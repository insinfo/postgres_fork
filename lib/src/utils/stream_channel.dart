// Implementação interna das abstrações de stream usadas pela API v3,
// substituindo os pacotes `stream_channel` (2.1.4) e `async` (2.13.0).
//
// O código foi portado dos pacotes originais mantendo a mesma semântica
// (incluindo a garantia de fechamento do `StreamChannel.withCloseGuarantee` e o
// fechamento "seguro" do sink interno em `StreamSinkTransformer.fromHandlers`).
//
// Copyright 2015, the Dart project authors.
//
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
//     * Neither the name of Google LLC nor the names of its
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

import 'dart:async';
import 'dart:convert';

/// An abstract class representing a two-way communication channel.
///
/// Users should consider the [stream] emitting a "done" event to be the
/// canonical indicator that the channel has closed. If they wish to close the
/// channel, they should close the [sink]; canceling the stream subscription is
/// not sufficient.
abstract class StreamChannel<T> {
  /// The single-subscription stream that emits values from the other endpoint.
  Stream<T> get stream;

  /// The sink for sending values to the other endpoint.
  StreamSink<T> get sink;

  /// Creates a new [StreamChannel] that communicates over [stream] and [sink].
  factory StreamChannel(Stream<T> stream, StreamSink<T> sink) =>
      _StreamChannel<T>(stream, sink);

  /// Creates a new [StreamChannel] that communicates over [stream] and [sink].
  ///
  /// This specifically enforces the guarantee that closing the sink causes
  /// the stream to emit a done event.
  factory StreamChannel.withCloseGuarantee(
          Stream<T> stream, StreamSink<T> sink) =>
      _CloseGuaranteeChannel(stream, sink);

  /// Connects this to [other], so that any values emitted by either are sent
  /// directly to the other.
  void pipe(StreamChannel<T> other);

  /// Transforms this using [transformer].
  StreamChannel<S> transform<S>(StreamChannelTransformer<S, T> transformer);

  /// Transforms only the [stream] component of this using [transformer].
  StreamChannel<T> transformStream(StreamTransformer<T, T> transformer);

  /// Transforms only the [sink] component of this using [transformer].
  StreamChannel<T> transformSink(StreamSinkTransformer<T, T> transformer);

  /// Returns a copy of this with [stream] replaced by [change]'s return value.
  StreamChannel<T> changeStream(Stream<T> Function(Stream<T>) change);

  /// Returns a copy of this with [sink] replaced by [change]'s return value.
  StreamChannel<T> changeSink(StreamSink<T> Function(StreamSink<T>) change);

  /// Returns a copy of this with the generic type coerced to [S].
  StreamChannel<S> cast<S>();
}

class _StreamChannel<T> extends StreamChannelMixin<T> {
  @override
  final Stream<T> stream;
  @override
  final StreamSink<T> sink;

  _StreamChannel(this.stream, this.sink);
}

/// A mixin that implements the instance methods of [StreamChannel] in terms
/// of [stream] and [sink].
abstract class StreamChannelMixin<T> implements StreamChannel<T> {
  @override
  void pipe(StreamChannel<T> other) {
    stream.pipe(other.sink);
    other.stream.pipe(sink);
  }

  @override
  StreamChannel<S> transform<S>(StreamChannelTransformer<S, T> transformer) =>
      transformer.bind(this);

  @override
  StreamChannel<T> transformStream(StreamTransformer<T, T> transformer) =>
      changeStream(transformer.bind);

  @override
  StreamChannel<T> transformSink(StreamSinkTransformer<T, T> transformer) =>
      changeSink(transformer.bind);

  @override
  StreamChannel<T> changeStream(Stream<T> Function(Stream<T>) change) =>
      StreamChannel.withCloseGuarantee(change(stream), sink);

  @override
  StreamChannel<T> changeSink(StreamSink<T> Function(StreamSink<T>) change) =>
      StreamChannel.withCloseGuarantee(stream, change(sink));

  @override
  StreamChannel<S> cast<S>() => StreamChannel(
      stream.cast(), StreamController(sync: true)..stream.cast<T>().pipe(sink));
}

/// A [StreamChannelTransformer] transforms the events being passed to and
/// emitted by a [StreamChannel].
///
/// This works on the same principle as [StreamTransformer] and
/// [StreamSinkTransformer]. Each transformer defines a [bind] method that
/// takes in the original [StreamChannel] and returns the transformed version.
class StreamChannelTransformer<S, T> {
  /// The transformer to use on the channel's stream.
  final StreamTransformer<T, S> _streamTransformer;

  /// The transformer to use on the channel's sink.
  final StreamSinkTransformer<S, T> _sinkTransformer;

  /// Creates a [StreamChannelTransformer] from existing stream and sink
  /// transformers.
  const StreamChannelTransformer(
      this._streamTransformer, this._sinkTransformer);

  /// Creates a [StreamChannelTransformer] from a codec's encoder and decoder.
  StreamChannelTransformer.fromCodec(Codec<S, T> codec)
      : this(codec.decoder,
            StreamSinkTransformer.fromStreamTransformer(codec.encoder));

  /// Transforms the events sent to and emitted by [channel].
  StreamChannel<S> bind(StreamChannel<T> channel) =>
      StreamChannel<S>.withCloseGuarantee(
          channel.stream.transform(_streamTransformer),
          _sinkTransformer.bind(channel.sink));
}

/// A [StreamSinkTransformer] transforms the events being passed to a sink.
abstract class StreamSinkTransformer<S, T> {
  /// Creates a [StreamSinkTransformer] that transforms events and errors
  /// using [transformer].
  const factory StreamSinkTransformer.fromStreamTransformer(
      StreamTransformer<S, T> transformer) = _StreamTransformerWrapper<S, T>;

  /// Creates a [StreamSinkTransformer] that delegates events to the given
  /// handlers.
  ///
  /// The handlers work exactly as they do for [StreamTransformer.fromHandlers].
  /// They're called for each incoming event, and any actions on the sink
  /// they're passed are forwarded to the inner sink. If a handler is omitted,
  /// the event is passed through unaltered.
  factory StreamSinkTransformer.fromHandlers(
      {void Function(S, EventSink<T>)? handleData,
      void Function(Object, StackTrace, EventSink<T>)? handleError,
      void Function(EventSink<T>)? handleDone}) {
    return _HandlerTransformer<S, T>(handleData, handleError, handleDone);
  }

  /// Transforms the events passed to [sink].
  ///
  /// Creates a new sink. When events are passed to the returned sink, it will
  /// transform them and pass the transformed versions to [sink].
  StreamSink<S> bind(StreamSink<T> sink);
}

/// Extensions on [StreamSink].
extension StreamSinkTransformExtension<T> on StreamSink<T> {
  /// Transforms a [StreamSink] using [transformer].
  StreamSink<S> transform<S>(StreamSinkTransformer<S, T> transformer) =>
      transformer.bind(this);
}

typedef _HandleData<S, T> = void Function(S data, EventSink<T> sink);

typedef _HandleError<T> = void Function(
    Object error, StackTrace stackTrace, EventSink<T> sink);

typedef _HandleDone<T> = void Function(EventSink<T> sink);

class _HandlerTransformer<S, T> implements StreamSinkTransformer<S, T> {
  final _HandleData<S, T>? _handleData;

  final _HandleError<T>? _handleError;

  final _HandleDone<T>? _handleDone;

  _HandlerTransformer(this._handleData, this._handleError, this._handleDone);

  @override
  StreamSink<S> bind(StreamSink<T> sink) => _HandlerSink<S, T>(this, sink);
}

class _HandlerSink<S, T> implements StreamSink<S> {
  final _HandlerTransformer<S, T> _transformer;

  /// The wrapped sink.
  final StreamSink<T> _inner;

  /// The wrapped sink, whose `close` method ignores errors.
  final StreamSink<T> _safeCloseInner;

  @override
  Future get done => _inner.done;

  _HandlerSink(this._transformer, StreamSink<T> inner)
      : _inner = inner,
        _safeCloseInner = _SafeCloseSink<T>(inner);

  @override
  void add(S event) {
    final handleData = _transformer._handleData;
    if (handleData == null) {
      _inner.add(event as T);
    } else {
      handleData(event, _safeCloseInner);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    final handleError = _transformer._handleError;
    if (handleError == null) {
      _inner.addError(error, stackTrace);
    } else {
      handleError(error, stackTrace ?? AsyncError.defaultStackTrace(error),
          _safeCloseInner);
    }
  }

  @override
  Future addStream(Stream<S> stream) {
    return _inner.addStream(stream.transform(
        StreamTransformer<S, T>.fromHandlers(
            handleData: _transformer._handleData,
            handleError: _transformer._handleError,
            handleDone: _closeSink)));
  }

  @override
  Future close() {
    final handleDone = _transformer._handleDone;
    if (handleDone == null) return _inner.close();

    handleDone(_safeCloseInner);
    return _inner.done;
  }
}

/// A wrapper for [StreamSink]s that swallows any errors returned by [close].
class _SafeCloseSink<T> extends _DelegatingStreamSink<T> {
  _SafeCloseSink(super.inner);

  @override
  Future close() => super.close().catchError((_) {});
}

/// A function to pass as a [StreamTransformer]'s `handleDone` callback.
void _closeSink(EventSink sink) {
  sink.close();
}

class _StreamTransformerWrapper<S, T> implements StreamSinkTransformer<S, T> {
  final StreamTransformer<S, T> _transformer;

  const _StreamTransformerWrapper(this._transformer);

  @override
  StreamSink<S> bind(StreamSink<T> sink) =>
      _StreamTransformerWrapperSink<S, T>(_transformer, sink);
}

class _StreamTransformerWrapperSink<S, T> implements StreamSink<S> {
  final _controller = StreamController<S>(sync: true);

  final StreamSink<T> _inner;

  @override
  Future get done => _inner.done;

  _StreamTransformerWrapperSink(
      StreamTransformer<S, T> transformer, this._inner) {
    _controller.stream
        .transform(transformer)
        .listen(_inner.add, onError: _inner.addError, onDone: () {
      // Ignore any errors that come from this call to [_inner.close]. The
      // user can access them through [done] or the value returned from
      // [this.close], and we don't want them to get top-leveled.
      _inner.close().catchError((_) {});
    });
  }

  @override
  void add(S event) {
    _controller.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _controller.addError(error, stackTrace);
  }

  @override
  Future addStream(Stream<S> stream) => _controller.addStream(stream);

  @override
  Future close() {
    _controller.close();
    return _inner.done;
  }
}

class _DelegatingStreamSink<T> implements StreamSink<T> {
  final StreamSink<T> _sink;

  @override
  Future get done => _sink.done;

  _DelegatingStreamSink(StreamSink<T> sink) : _sink = sink;

  @override
  void add(T data) {
    _sink.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _sink.addError(error, stackTrace);
  }

  @override
  Future addStream(Stream<T> stream) => _sink.addStream(stream);

  @override
  Future close() => _sink.close();
}

/// A [StreamChannel] that specifically enforces the stream channel guarantee
/// that closing the sink causes the stream to close before it emits any more
/// events.
class _CloseGuaranteeChannel<T> extends StreamChannelMixin<T> {
  @override
  Stream<T> get stream => _stream;
  late final _CloseGuaranteeStream<T> _stream;

  @override
  StreamSink<T> get sink => _sink;
  late final _CloseGuaranteeSink<T> _sink;

  /// The subscription to the inner stream.
  // ignore: cancel_subscriptions
  StreamSubscription<T>? _subscription;

  /// Whether the sink has closed, causing the underlying channel to disconnect.
  bool _disconnected = false;

  _CloseGuaranteeChannel(Stream<T> innerStream, StreamSink<T> innerSink) {
    _sink = _CloseGuaranteeSink<T>(innerSink, this);
    _stream = _CloseGuaranteeStream<T>(innerStream, this);
  }
}

class _CloseGuaranteeStream<T> extends Stream<T> {
  final Stream<T> _inner;

  final _CloseGuaranteeChannel<T> _channel;

  _CloseGuaranteeStream(this._inner, this._channel);

  @override
  StreamSubscription<T> listen(void Function(T)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    // If the channel is already disconnected, we shouldn't dispatch anything
    // but a done event.
    if (_channel._disconnected) {
      onData = null;
      onError = null;
    }

    final subscription = _inner.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    if (!_channel._disconnected) {
      _channel._subscription = subscription;
    }
    return subscription;
  }
}

class _CloseGuaranteeSink<T> extends _DelegatingStreamSink<T> {
  final _CloseGuaranteeChannel<T> _channel;

  _CloseGuaranteeSink(super.inner, this._channel);

  @override
  Future<void> close() {
    final done = super.close();
    _channel._disconnected = true;
    // ignore: cancel_subscriptions
    final subscription = _channel._subscription;
    if (subscription != null) {
      // Don't dispatch anything but a done event.
      subscription.onData(null);
      subscription.onError(null);
    }
    return done;
  }
}

/// A [Stream] adapter for a [StreamSubscription].
///
/// This class allows a [StreamSubscription] to be treated as a [Stream].
///
/// The subscription is paused until the stream is listened to,
/// then it is resumed and the events are passed on to the
/// stream's new subscription.
///
/// This class assumes that is has control over the original subscription.
/// If other code is accessing the subscription, results may be unpredictable.
class SubscriptionStream<T> extends Stream<T> {
  /// The subscription providing the events for this stream.
  StreamSubscription<T>? _source;

  /// Create a single-subscription `Stream` from [subscription].
  ///
  /// The `subscription` should not be paused. This class will not resume prior
  /// pauses, so being paused is indistinguishable from not providing any
  /// events.
  ///
  /// If the `subscription` doesn't send any `done` events, neither will this
  /// stream. That may be an issue if `subscription` was made with
  /// `cancelOnError` set to true.
  SubscriptionStream(StreamSubscription<T> subscription)
      : _source = subscription {
    // ignore: cancel_subscriptions
    final source = _source!;
    source.pause();
    // Clear callbacks to avoid keeping them alive unnecessarily.
    source.onData(null);
    source.onError(null);
    source.onDone(null);
  }

  @override
  StreamSubscription<T> listen(void Function(T)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    final subscription = _source;
    if (subscription == null) {
      throw StateError('Stream has already been listened to.');
    }
    cancelOnError = (true == cancelOnError);
    _source = null;

    final result = cancelOnError
        ? _CancelOnErrorSubscriptionWrapper<T>(subscription)
        : subscription;
    result.onData(onData);
    result.onError(onError);
    result.onDone(onDone);
    subscription.resume();
    return result;
  }
}

/// Subscription wrapper that cancels on error.
///
/// Used by [SubscriptionStream] when forwarding a subscription
/// created with `cancelOnError` as `true` to one with (assumed)
/// `cancelOnError` as `false`. It automatically cancels the
/// source subscription on the first error.
class _CancelOnErrorSubscriptionWrapper<T> implements StreamSubscription<T> {
  final StreamSubscription<T> _source;

  _CancelOnErrorSubscriptionWrapper(this._source);

  @override
  void onData(void Function(T)? handleData) {
    _source.onData(handleData);
  }

  @override
  void onError(Function? handleError) {
    // Cancel when receiving an error.
    _source.onError((Object error, StackTrace stackTrace) {
      _source.cancel().whenComplete(() {
        if (handleError is dynamic Function(Object, StackTrace)) {
          handleError(error, stackTrace);
        } else if (handleError is dynamic Function(Object)) {
          handleError(error);
        }
      });
    });
  }

  @override
  void onDone(void Function()? handleDone) {
    _source.onDone(handleDone);
  }

  @override
  void pause([Future? resumeFuture]) {
    _source.pause(resumeFuture);
  }

  @override
  void resume() {
    _source.resume();
  }

  @override
  Future cancel() => _source.cancel();

  @override
  Future<E> asFuture<E>([E? futureValue]) => _source.asFuture(futureValue);

  @override
  bool get isPaused => _source.isPaused;
}
