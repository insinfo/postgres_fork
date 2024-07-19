import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:buffer/buffer.dart';
import 'package:postgres_fork/postgres.dart';
import 'package:stream_channel/stream_channel.dart';

import '../client_messages.dart';
import '../message_window.dart';
import '../server_messages.dart';
import '../shared_messages.dart';

export '../client_messages.dart';
export '../server_messages.dart';
export '../shared_messages.dart';

class AggregatedClientMessage extends ClientMessage {
  final List<ClientMessage> messages;

  AggregatedClientMessage(this.messages);

  @override
  void applyToBuffer(ByteDataWriter buffer) {
    for (final cm in messages) {
      cm.applyToBuffer(buffer);
    }
  }

  @override
  String toString() {
    return 'Aggregated $messages';
  }
}

StreamChannelTransformer<BaseMessage, List<int>> messageTransformer(
    Encoding encoding, TimeZoneSettings timeZone) {
  return StreamChannelTransformer(
    _readMessages(encoding, timeZone),
    StreamSinkTransformer.fromHandlers(
      handleData: (message, out) {
        if (message is! ClientMessage) {
          out.addError(
              ArgumentError.value(
                  message, 'message', 'Must be a client message'),
              StackTrace.current);
          return;
        }

        out.add(message.asBytes());
      },
    ),
  );
}

StreamTransformer<Uint8List, ServerMessage> _readMessages(
    Encoding encoding, TimeZoneSettings timeZone) {
  return StreamTransformer.fromBind((rawStream) {
    return Stream.multi((listener) {
      final framer = MessageFramer(encoding, timeZone);

      var paused = false;

      void emitFinishedMessages() {
        while (framer.hasMessage) {
          listener.addSync(framer.popMessage());

          if (paused) break;
        }
      }

      void handleChunk(Uint8List bytes) {
        framer.addBytes(bytes);
        emitFinishedMessages();
      }

      final rawSubscription = rawStream.listen(handleChunk)
        ..onError(listener.addErrorSync);

      listener.onPause = () {
        paused = true;
        rawSubscription.pause();
      };

      listener.onResume = () {
        paused = false;
        emitFinishedMessages();

        if (!paused) {
          rawSubscription.resume();
        }
      };

      listener.onCancel = () {
        paused = true;
        rawSubscription.cancel();
      };
    });
  });
}


/*class WrapMessageTransformer {
  final Encoding encoding;

  late StreamChannelTransformer<BaseMessage, List<int>> messageTransformer;
  late StreamTransformer<Uint8List, ServerMessage> _readMessages;

  WrapMessageTransformer(this.encoding) {
    _readMessages = StreamTransformer.fromBind((rawStream) {
      return Stream.multi((listener) {
        final framer = MessageFramer(encoding);

        var paused = false;

        void emitFinishedMessages() {
          while (framer.hasMessage) {
            listener.addSync(framer.popMessage());

            if (paused) break;
          }
        }

        void handleChunk(Uint8List bytes) {
          framer.addBytes(bytes);
          emitFinishedMessages();
        }

        final rawSubscription = rawStream.listen(handleChunk)
          ..onError(listener.addErrorSync);

        listener.onPause = () {
          paused = true;
          rawSubscription.pause();
        };

        listener.onResume = () {
          paused = false;
          emitFinishedMessages();

          if (!paused) {
            rawSubscription.resume();
          }
        };

        listener.onCancel = () {
          paused = true;
          rawSubscription.cancel();
        };
      });
    });

    messageTransformer = StreamChannelTransformer(
      _readMessages,
      StreamSinkTransformer.fromHandlers(
        handleData: (message, out) {
          if (message is! ClientMessage) {
            out.addError(
                ArgumentError.value(
                    message, 'message', 'Must be a client message'),
                StackTrace.current);
            return;
          }

          out.add(message.asBytes());
        },
      ),
    );
  }
}
*/