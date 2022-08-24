import 'package:client/document_channel.dart';
import 'package:client/local_document_history.dart';
import 'package:quill_delta/quill_delta.dart';

/// A callback for telling any document editor (such as SuperEditor) that a
/// remote document was just opened.
typedef RemoteDocumentOpenedCallback = void Function(Delta document);

/// A callback for telling any document editor (such as SuperEditor) that a
/// remote document was just updated.
///
/// The [document] will be the [Delta] containing the full document and not just
/// the diff.
///
/// If [change] is null, it means that a remote document was just opened.
///
/// If non-null, [change] contains what changed from the previous document.
/// This can be used by the document editor transform its selection.
///
/// For transforming the selection for SuperEditor, use the
/// `DocumentSelectionTransformer` class.
typedef RemoteDocumentChangedCallback = void Function(
  Delta document,
  Delta change,
);

/// Makes it sure that the local document and the remote document are properly
/// in sync.
///
/// Resolves conflicts and ensures that both the remote document and the local
/// document are eventually consistent together.
class DocumentSyncEngine {
  DocumentSyncEngine(this._documentChannel);
  final DocumentChannel _documentChannel;

  late final String _documentId;
  late final RemoteDocumentOpenedCallback _onDocumentOpened;
  late final RemoteDocumentChangedCallback _onDocumentChanged;

  int? _version;
  LocalDocumentHistory? _history;
  Delta? _currentDocument;
  Delta? _changesBeingCurrentlyPushed;
  Delta? _queuedChanges;

  /// Opens a document with the given [documentId] and starts listening to
  /// changes in it.
  void openDocument({
    required String documentId,
    required RemoteDocumentOpenedCallback onDocumentOpened,
    required RemoteDocumentChangedCallback onDocumentChanged,
  }) {
    _documentId = documentId;
    _onDocumentOpened = onDocumentOpened;
    _onDocumentChanged = onDocumentChanged;
    _documentChannel.join(
      documentId: _documentId,
      onDocumentOpened: _handleRemoteDocumentOpened,
      onDocumentUpdated: _handleRemoteDocumentChanged,
    );
  }

  /// Leaves the document that has been previously opened.
  void dispose() {
    _documentChannel.leave(documentId: _documentId);
  }

  /// Informs the sync engine that the local document has changed.
  ///
  /// This will do a diff against the current state of the document and push the
  /// resulting diff delta to the server.
  Future<void> onLocalDocumentChanged(Delta document) async {
    _ensureContainsOnlyInserts(document);

    final delta = Delta.from(document);
    final change = _currentDocument!.diff(delta);

    if (change.isNotEmpty) {
      _currentDocument = _history!.composeLocalChange(change);
      await _pushLocalUpdate(change);
    }
  }

  /// Undoes the last local change to the document and pushes that change to
  /// the server.
  ///
  /// Returns true if the document changed, false otherwise.
  bool undo() => _applyChanges(_history!.undo());

  /// Redoes the last undone change to the document and pushes that change to
  /// the server.
  ///
  /// Returns true if the document changed, false otherwise.
  bool redo() => _applyChanges(_history!.redo());

  bool _applyChanges(Delta change) {
    if (change.isNotEmpty) {
      final updatedDocument = _currentDocument!.compose(change);
      _currentDocument = updatedDocument;
      _onDocumentChanged(updatedDocument, change);
      _pushLocalUpdate(change);
      return true;
    }

    return false;
  }

  Future<void> _pushLocalUpdate(Delta change) async {
    if (_changesBeingCurrentlyPushed != null) {
      // We're currently waiting an acknowledgement from the server.
      //
      // Per the Google Docs Operational Transform protocol, we don't want to
      // push changes until the server has handled the previous change. So we
      // compose the new change on top of the existing queued changes.
      _queuedChanges ??= Delta();
      _queuedChanges = _queuedChanges!.compose(change);
    } else {
      final version = _version;
      _version = version! + 1;
      _changesBeingCurrentlyPushed = change;

      final response = await _documentChannel.sendUpdate(
        documentId: _documentId,
        version: version,
        change: change,
      );

      if (response.isError) {
        final reason = response.response['reason'];
        if (reason == 'document_corrupted') {
          _version = version;
          _changesBeingCurrentlyPushed = null;
          throw DocumentCorruptedException(topic: _documentId);
        }
      }

      _changesBeingCurrentlyPushed = null;

      if (_queuedChanges != null) {
        // While we were pushing the change to the server, there were one or more
        // local document changes that were queued. Now that the server acknowledged
        // our current change, it's the perfect time to push the queued changes.
        //
        // This will call the same function we're currently in. So it's recursive.
        // If we get queued changes when pushing the next change, the same logic
        // will kick in and the changes are pushed after the change is pushed.
        _pushLocalUpdate(_queuedChanges!);
        _queuedChanges = null;
      }
    }
  }

  void _handleRemoteDocumentOpened(int version, Delta contents) {
    _version = version;
    _history = LocalDocumentHistory(initialDocument: contents);
    _currentDocument = contents;
    _onDocumentOpened(contents);
  }

  void _handleRemoteDocumentChanged(int version, Delta change) {
    var remoteDelta = Delta.from(change);

    if (_changesBeingCurrentlyPushed != null) {
      // Transform remote delta against the local changes we're currently pushing
      // to the server. Otherwise the resulting local document would not be up to
      // date, as the server doesn't know about the local changes yet.
      remoteDelta = _changesBeingCurrentlyPushed!.transform(remoteDelta, false);

      if (_queuedChanges != null) {
        // There are more queued changes the server hasn't seen yet. So we transform
        // both remote delta and queued changes on each other to make the document
        // consistent with server.
        final remotePending = _queuedChanges!.transform(remoteDelta, false);
        _queuedChanges = remoteDelta.transform(_queuedChanges!, true);
        remoteDelta = remotePending;
      }
    }

    _currentDocument = _history!.composeRemoteChange(remoteDelta);
    // This logic here is correct - we DON'T want `_version = version` here.
    _version = _version! + 1;
    _onDocumentChanged(_currentDocument!, Delta.from(remoteDelta));
  }
}

void _ensureContainsOnlyInserts(Delta delta) {
  for (final operation in delta.toList()) {
    if (!operation.isInsert) {
      throw ArgumentError.value(
        delta,
        'contents',
        'The given delta to pushLocalUpdate should be the entire document, and as such, only contain inserts.',
      );
    }
  }
}

class DocumentCorruptedException implements Exception {
  const DocumentCorruptedException({required this.topic});
  final String topic;

  @override
  String toString() {
    return 'Document "$topic" corrupted.';
  }
}
