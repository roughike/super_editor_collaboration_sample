import 'dart:async';

import 'package:client/document_channel.dart';
import 'package:client/document_selection_transformer.dart';
import 'package:client/document_sync_engine.dart';
import 'package:client/editor_document_to_quill_delta_converter.dart';
import 'package:flutter/material.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:quill_delta/quill_delta.dart';
import 'package:super_editor/super_editor.dart';

const _documentId = 'vikings2';

void main() async {
  final socket =
      await PhoenixSocket('ws://localhost:4000/socket/websocket')
          .connect();
  runApp(MyApp(socket: socket!));
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key, required this.socket}) : super(key: key);
  final PhoenixSocket socket;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(socket: socket),
    );
  }
}

const _converter = EditorDocumentToQuillDeltaConverter();
const _selectionTransformer = DocumentSelectionTransformer();

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.socket}) : super(key: key);
  final PhoenixSocket socket;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final FocusNode _editorFocusNode;
  late final DocumentComposer _documentComposer;
  late final DocumentEditor _documentEditor;
  late final DocumentSyncEngine _documentSyncEngine;
  late final StreamSubscription<int> _presentUsersSubscription;

  final _presentUsersCount = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _editorFocusNode = FocusNode();
    _documentComposer = DocumentComposer();
    _documentEditor = DocumentEditor(document: MutableDocument());
    final channel = DocumentChannel(widget.socket);
    _documentSyncEngine = DocumentSyncEngine(channel)
      ..openDocument(
        documentId: _documentId,
        onDocumentOpened: _handleRemoteDocumentOpened,
        onDocumentChanged: _handleRemoteDocumentChanged,
      );
    _presentUsersSubscription = channel
        .watchPresentUserCount(documentId: _documentId)
        .listen((count) => _presentUsersCount.value = count);
  }

  @override
  void dispose() {
    _editorFocusNode.dispose();
    _documentComposer.dispose();
    _documentSyncEngine.dispose();
    _presentUsersSubscription.cancel();
    super.dispose();
  }

  void _handleLocalDocumentChanged() {
    final document = _converter.editorDocumentToDelta(_documentEditor.document);
    _documentSyncEngine.onLocalDocumentChanged(document);
  }

  /// Replaces the nodes in the [MutableDocument] managed by the
  /// [RealtimeDocumentEditor] with the contents of [document].
  void _handleRemoteDocumentOpened(Delta document) {
    final newDocument = _converter.deltaToEditorDocument(document);
    _documentEditor.executeCommand(
      EditorCommandFunction((document, documentTransaction) {
        // Replace the document contents completely with a new document.
        List.of(document.nodes).forEach(documentTransaction.deleteNode);
        final newNodes = List.of(newDocument.nodes);
        for (var i = 0; i < newNodes.length; i++) {
          final node = newNodes[i];
          documentTransaction.insertNodeAt(i, node);
        }
      }),
    );

    _documentEditor.document.addListener(_handleLocalDocumentChanged);
  }

  /// Replaces the nodes in the [MutableDocument] managed by the
  /// [RealtimeDocumentEditor] with the contents of [document].
  ///
  /// Also transforms the user selection if needed (using [change] as a reference),
  /// so that if other users are typing before our selection, our selection will
  /// be placed where we were typing.
  ///
  /// See also [DocumentSelectionTransformer] and the related documentation.
  void _handleRemoteDocumentChanged(Delta document, Delta? change) {
    final newDocument = _converter.deltaToEditorDocument(document);
    final oldDocument =
        MutableDocument(nodes: List.of(_documentEditor.document.nodes));
    _documentEditor.document.removeListener(_handleLocalDocumentChanged);
    _documentEditor.executeCommand(
      EditorCommandFunction((document, documentTransaction) {
        final oldSelection = _documentComposer.selection;
        if (change != null && oldSelection != null) {
          _documentComposer.clearSelection();
        }

        // Transform the selection so that the cursor doesn't jump due to other
        // users' recent change.
        //
        // We have to do it at this point before we modify the nodes of the old
        // document in any way, otherwise the selection transformation is done
        // on old and new documents that don't really reflect the reality.
        final transformedSelection =
            change != null && oldSelection != null && _editorFocusNode.hasFocus
                ? _selectionTransformer.transform(
                    oldDocument: oldDocument,
                    newDocument: newDocument,
                    oldSelection: oldSelection,
                    delta: change,
                  )
                : null;

        // Delete every node from the old document and replace them with the nodes
        // from the new document.
        List.of(document.nodes).forEach(documentTransaction.deleteNode);
        final newNodes = List.of(newDocument.nodes);
        for (var i = 0; i < newNodes.length; i++) {
          final newNode = newNodes[i];
          documentTransaction.insertNodeAt(i, newNode);
        }

        if (transformedSelection != null) {
          // If we have a non-null transformed selection, this is the perfect
          // moment to apply it to the current document.
          _documentComposer.selection = transformedSelection;
        }
      }),
    );
    _documentEditor.document.addListener(_handleLocalDocumentChanged);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<int>(
          valueListenable: _presentUsersCount,
          builder: (context, count, child) => Text('Users online: $count'),
        ),
        actions: [
          IconButton(
            onPressed: _documentSyncEngine.undo,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            onPressed: _documentSyncEngine.redo,
            icon: const Icon(Icons.redo),
          ),
        ],
      ),
      body: SuperEditor(
        editor: _documentEditor,
        composer: _documentComposer,
        focusNode: _editorFocusNode,
      ),
    );
  }
}
