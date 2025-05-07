import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:buffer/buffer.dart';
import 'package:charcode/ascii.dart';
import 'package:postgres_fork/src/timezone_settings.dart';

import 'server_messages.dart';
import 'shared_messages.dart';

const int _headerByteSize = 5;
final _emptyData = Uint8List(0);

typedef _ServerMessageFn = ServerMessage Function(Uint8List data);

class MessageFramer {
  final _reader = ByteDataReader();
  final messageQueue = Queue<ServerMessage>();
  final Encoding encoding;
  TimeZoneSettings timeZone;
  //,
  MessageFramer(this.encoding, this.timeZone);

  _ServerMessageFn? _messageTypeMap(int? msgType) {
    switch (msgType) {
      case 49:
        return (d) => ParseCompleteMessage();
      case 50:
        return (d) => BindCompleteMessage();
      case 65:
        return (bytes) => NotificationResponseMessage(bytes, encoding);
      case 67:
        return (bytes) => CommandCompleteMessage(bytes, encoding);
      case 68:
        return DataRowMessage.new;
      case 69:
        return (bytes) => ErrorResponseMessage(bytes, encoding);
      case 75:
        return BackendKeyMessage.new;
      case 82:
        return AuthenticationMessage.new;
      case 83:
        //_handle_PARAMETER_STATUS
        return (bytes) => ParameterStatusMessage(bytes, encoding, timeZone);
      case 84:
        return (bytes) => RowDescriptionMessage(bytes, encoding, timeZone);
      case 87:
        return CopyBothResponseMessage.new;
      case 90:
        return (bytes) => ReadyForQueryMessage(bytes, encoding);
      case 100:
        return CopyDataMessage.new;
      case 110:
        return (d) => NoDataMessage();
      case 116:
        return ParameterDescriptionMessage.new;
      //0x33
      case $3:
        return (d) => CloseCompleteMessage();
      default:
        return null;
      //throw PostgreSQLException('ServerMessage type unknown');
    }
  }

  int? _type;
  int _expectedLength = 0;

  bool get _hasReadHeader => _type != null;
  bool get _canReadHeader => _reader.remainingLength >= _headerByteSize;

  bool get _isComplete =>
      _expectedLength == 0 || _expectedLength <= _reader.remainingLength;

  void addBytes(Uint8List bytes) {
    _reader.add(bytes);

    var evaluateNextMessage = true;
    while (evaluateNextMessage) {
      evaluateNextMessage = false;

      if (!_hasReadHeader && _canReadHeader) {
        _type = _reader.readUint8();
        _expectedLength = _reader.readUint32() - 4;
      }

      // special case
      if (_type == SharedMessages.copyDoneIdentifier) {
        // unlike other messages, CopyDoneMessage only takes the length as an
        // argument (must be the full length including the length bytes)
        final msg = CopyDoneMessage(_expectedLength + 4);
        _addMsg(msg);
        evaluateNextMessage = true;
      } else if (_hasReadHeader && _isComplete) {
        final data =
            _expectedLength == 0 ? _emptyData : _reader.read(_expectedLength);
        final msgMaker = _messageTypeMap(_type); //_messageTypeMap[_type];
        var msg =
            msgMaker == null ? UnknownMessage(_type, data) : msgMaker(data);

        // Copy Data message is a wrapper around data stream messages
        // such as replication messages.
        if (msg is CopyDataMessage) {
          // checks if it's a replication message, otherwise returns given msg
          msg = _extractReplicationMessageIfAny(msg);
        }

        _addMsg(msg);
        evaluateNextMessage = true;
      }
    }
  }

  void _addMsg(ServerMessage msg) {
    messageQueue.add(msg);
    _type = null;
    _expectedLength = 0;
  }

  /// Returns a [ReplicationMessage] if the [CopyDataMessage] contains such message.
  /// Otherwise, it'll just return the provided [copyData].
  ServerMessage _extractReplicationMessageIfAny(CopyDataMessage copyData) {
    final bytes = copyData.bytes;
    final code = bytes.first;
    final data = bytes.sublist(1);
    if (code == ReplicationMessage.primaryKeepAliveIdentifier) {
      return PrimaryKeepAliveMessage(data);
    } else if (code == ReplicationMessage.xLogDataIdentifier) {
      return XLogDataMessage.parse(data, encoding);
    } else {
      return copyData;
    }
  }

  bool get hasMessage => messageQueue.isNotEmpty;

  ServerMessage popMessage() {
    return messageQueue.removeFirst();
  }
}
