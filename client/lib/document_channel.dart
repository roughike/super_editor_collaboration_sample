import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:quill_delta/quill_delta.dart';

String _topic(String documentId) => 'document:$documentId';

class DocumentChannel {
  DocumentChannel(this._socket);
  final PhoenixSocket _socket;

  final _subscriptionsByDocumentId = <String, StreamSubscription>{};

  void join({
    required String documentId,
    required void Function(int version, Delta contents) onDocumentOpened,
    required void Function(int version, Delta change) onDocumentUpdated,
  }) async {
    final channel = _socket.addChannel(topic: _topic(documentId));
    _subscriptionsByDocumentId[documentId] = channel.messages.listen((message) {
      switch (message.event.value) {
        case 'open':
          onDocumentOpened(
            message.payload!['version'],
            Delta.fromJson(message.payload!['contents']),
          );
          break;
        case 'update':
          onDocumentUpdated(
            message.payload!['version'],
            Delta.fromJson(message.payload!['change']),
          );
          break;
      }
    });

    channel.join();
  }

  void leave({required String documentId}) {
    _socket.addChannel(topic: _topic(documentId)).leave();
    _subscriptionsByDocumentId[documentId]?.cancel();
  }

  Future<PushResponse> sendUpdate({
    required String documentId,
    required int version,
    required Delta change,
  }) async {
    final channel = _socket.addChannel(topic: _topic(documentId));
    return channel.push(
      'update',
      {
        'version': version,
        'change': change
            .toJson(),
      },
    ).future;
  }
}
