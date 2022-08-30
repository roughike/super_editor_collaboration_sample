import 'dart:math';

import 'package:collection/collection.dart';
import 'package:quill_delta/quill_delta.dart';
import 'package:super_editor/super_editor.dart';

final _trailingNewline = RegExp(r'\n$');

/// A converter that knows how to convert a SuperEditor [Document] into a QuillJS
/// document [Delta] and back.
class EditorDocumentToQuillDeltaConverter {
  const EditorDocumentToQuillDeltaConverter();

  /// Converts a SuperEditor [Document] into a QuillJS document [Delta].
  ///
  /// Iterates over each node in [document] and converts them to QuillJS documents
  /// consisting of only insert operations.
  ///
  /// Block-level attributes are deduplicated.
  Delta editorDocumentToDelta(Document document) {
    var result = Delta();

    for (final node in document.nodes) {
      if (node is ParagraphNode) {
        result = _convertParagraphNodeToDelta(node).compose(result);
      } else if (node is ListItemNode) {
        result = _convertListItemNodeToDelta(node).compose(result);
      } else {
        throw UnsupportedDocumentNodeTypeError(node);
      }
    }

    return result;
  }

  /// Converts a document [delta] to a SuperEditor document.
  ///
  /// The [delta] must end with a newline character, and each newline character
  /// has to contain a `node_id` attribute, which will be used as a `nodeId` for
  /// each SuperEditor [DocumentNode].
  ///
  /// The given [delta] must be a "document delta", meaning that only
  /// [Operation.insert] is supported. If the document contains any other operation
  /// type, calling this method will throw [UnsupportedOperationsError].
  Document deltaToEditorDocument(Delta delta) {
    final nodes = <DocumentNode>[];
    final operations = delta.toList();

    for (var i = 0; i < operations.length; i++) {
      var operation = operations[i];
      var nodeId = operation.attributes?['node_id'] as String?;
      final parts = <Operation>[];

      // In the QuillJS Delta format, we'll represent a paragraph with inline
      // attributes (such as bold, italics, strike-through) as multiple "insert"
      // operations as follows:
      //
      // ```
      // Delta()
      //   ..insert('I am a paragraph with ')
      //   ..insert('bold', {'bold': true})
      //   ..insert(' text!\n', {'node_id': 'id1'})
      //   ..insert('I am another (but unrelated) paragraph!\n', {'node_id': 'id2'})
      //   ..insert('I am yet another unrelated paragraph!\n', {'node_id': 'id3'});
      // ```
      //
      // After this while loop is completed, with the above example, we'll have
      // the following:
      //
      // ```
      // var operation = Operation.insert(' text!\n', {'node_id': 'id1'});
      // var nodeId = 'id1';
      // final parts = [
      //   Operation.insert('I am a paragraph with ')
      //   Operation.insert('bold', {'bold': true})
      //   Operation.insert(' text!\n', {'node_id': 'id1'}),
      // ];
      // ```
      //
      // Because in Delta format, attributes applied to a line separator ("\n")
      // will apply to the whole preceding line, we need to find the `node_id`
      // from the closest possible "insert" operation.
      //
      // In SuperEditor terms, that paragraph will be merged into a single
      // `ParagraphNode` with a `nodeId` of `id1`.
      while (nodeId == null) {
        parts.add(operation);
        i++;

        if (i >= operations.length) {
          // We reached the end of the document without finding a `node_id`
          // attributed.
          //
          // Since every document has to end with a newline and a `node_id`
          // attribute, this is an unresolvable error. So we halt by throwing an
          // error.
          throw OrphanedOperationsError(operations: parts);
        }

        operation = operations[i];
        nodeId = operation.attributes?['node_id'] as String?;
      }

      parts.add(operation);

      for (final part in parts) {
        final data = part.data;

        if (data is String) {
          // In SuperEditor, we don't have explicit newlines between each block
          // level element, so we should remove the trailing newline character.
          final text = data.replaceFirst(_trailingNewline, '');

          if (operation.hasAttribute('list_item')) {
            final attributes = operation.attributes ?? {};

            // Contrary to the name, this also adds items to the "nodes" list.
            _convertDeltaToListItemNode(nodeId, text, part, attributes, nodes);
          } else {
            // Contrary to the name, this also adds items to the "nodes" list.
            _convertDeltaToParagraphNode(nodeId, text, part, nodes);
          }
        }
      }
    }

    return MutableDocument(nodes: nodes);
  }
}

// TODO(roughike): Some of this logic should be extracted to
// `DeltaDocumentNode.paragraph` constructor. We didn't do this yet because it
// requires some thinking about what would be a nice API for that.
Delta _convertParagraphNodeToDelta(ParagraphNode node) {
  final text = '${node.text.text}\n';
  var nodeDelta = Delta()
    ..insert(
      text,
      {
        'node_id': node.id,
        ..._blockTypeToDeltaAttribute(node.metadata['blockType']),
      },
    );

  nodeDelta = _convertAttributedSpansToDeltaAttributes(text, node, nodeDelta);
  return _deduplicateAttributes(nodeDelta, attributes: {'node_id'});
}

// TODO(roughike): Some of this logic should be extracted to
// `DeltaDocumentNode.paragraph` constructor. We didn't do this yet because it
// requires some thinking about what would be a nice API for that.
Delta _convertListItemNodeToDelta(ListItemNode node) {
  final text = '${node.text.text}\n';
  var delta = Delta()
    ..insert(
      text,
      {
        'node_id': node.id,
        'list_item':
            node.type == ListItemType.ordered ? 'ordered' : 'unordered',
        'indent': node.indent,
      },
    );

  delta = _convertAttributedSpansToDeltaAttributes(text, node, delta);
  return _deduplicateAttributes(
    delta,
    attributes: {'node_id', 'list_item', 'indent'},
  );
}

/// Converts [AttributedSpans] in the given [node] into attributes in the QuillJS
/// delta format.
Delta _convertAttributedSpansToDeltaAttributes(
  String text,
  TextNode node,
  Delta nodeDelta,
) {
  var result = Delta.from(nodeDelta);

  // Iterates through every character in the text, checks if that character has
  // any SuperEditor attributions applied, and then applies all those attributions
  // to that character in the Delta format. Finally composes each character into
  // the resulting delta.
  //
  // TODO(roughike): This is certainly not the most efficient way. If the document
  // persistence is debounced or throttled, this might work just fine, but
  // eventually, we should have a different approach than going character by
  // character.
  for (var i = 0; i < text.length; i++) {
    final attributions = node.text.spans.getAllAttributionsAt(i);
    if (attributions.isNotEmpty) {
      result = result.compose(
        Delta()
          ..retain(i)
          ..retain(
            1,
            {
              'node_id': node.id,
              ..._attributionsToDeltaAttributes(attributions),
            },
          ),
      );
    }
  }

  return result;
}

/// Converts a set of [Attribution]s into a [Map] suitable for the QuillJS Delta
/// format.
///
/// For example, given [attributions] of `{boldAttribution, italicsAttribution}`,
/// the result will be:
///
/// ```
/// {
///   'bold': true,
///   'italic': true,
/// }
/// ```
Map<String, dynamic> _attributionsToDeltaAttributes(
  Set<Attribution> attributions,
) {
  final result = <String, dynamic>{};
  for (final attribution in attributions) {
    if (attribution == boldAttribution) {
      result['bold'] = true;
    } else if (attribution == italicsAttribution) {
      result['italic'] = true;
    } else if (attribution == strikethroughAttribution) {
      result['strike'] = true;
    } else if (attribution is LinkAttribution) {
      result['link'] = attribution.url.toString();
    }
  }

  return result;
}

/// Deduplicates attributes on the given [delta], moving all attributes that
/// have matching keys in the [attributes] Set to the last operation of the
/// given [delta].
///
/// For example, given the following delta:
///
/// ```
/// Delta()
///   ..insert('I am a paragraph with ', {'node_id': 'id1'})
///   ..insert('bold', {'node_id': 'id1', 'bold': true})
///   ..insert(' text!\n', {'node_id': 'id1'});
/// ```
///
/// and the [attributes] set containing `{'node_id'}`, the resulting delta will
/// look like this:
///
/// ```
/// Delta()
///   ..insert('I am a paragraph with ')
///   ..insert('bold', {'bold': true})
///   ..insert(' text!\n', {'node_id': 'id1'});
/// ```
///
/// The difference is that `node_id` attribute now only exists on the last
/// `insert` operation of this delta. We could have the same attribute on all of
/// the insert operations, but it would be redundant bloat.
Delta _deduplicateAttributes(Delta delta, {required Set<String> attributes}) {
  if (delta.length == 1) {
    // This Delta is a block element containing just a single operation. There's
    // nothing to deduplicate as all the attributes apply to the whole element.
    return delta;
  }

  String? previousNodeId;
  var result = Delta();
  final operations = delta.toList();

  for (var i = 0; i < operations.length; i++) {
    final operation = operations[i];
    final nodeId = operation.attributes?['node_id'];

    if (nodeId != null) {
      if (previousNodeId != null && previousNodeId != nodeId) {
        throw StateError("Can't merge attributes of two different nodes.");
      }

      final isLastOperation = i == operations.length - 1;
      final updatedAttributes = isLastOperation
          ? operation.attributes
          : _removeMatchingKeys(
              operation.attributes ?? {},
              keysToRemove: attributes,
            );

      final updatedDelta = Delta()..insert(operation.data, updatedAttributes);
      result = updatedDelta.compose(result);
      previousNodeId = nodeId;
    }
  }

  return result;
}

Map<String, dynamic> _blockTypeToDeltaAttribute(dynamic metadata) {
  if (metadata == header1Attribution) return {'heading': 1};
  if (metadata == header2Attribution) return {'heading': 2};
  return {};
}

Map<String, dynamic> _removeMatchingKeys(
  Map<String, dynamic> attributes, {
  required Set<String> keysToRemove,
}) {
  final copy = <String, dynamic>{};
  for (final entry in attributes.entries) {
    if (!keysToRemove.contains(entry.key)) {
      copy[entry.key] = entry.value;
    }
  }

  return copy;
}

void _convertDeltaToListItemNode(
  String nodeId,
  String text,
  Operation operation,
  Map<String, dynamic> blockAttributes,
  List<DocumentNode> nodes,
) {
  final itemType = blockAttributes['list_item'] == 'ordered'
      ? ListItemType.ordered
      : ListItemType.unordered;
  final indent = blockAttributes['indent'] as int;
  final attributedText = AttributedText(
    text: text,
    spans: _convertAttributesToAttributedSpans(
      operation.attributes ?? {},
      text,
    ),
  );

  if (nodes.isNotEmpty && nodes.last.id == nodeId) {
    final nodeToMerge = nodes.removeLast() as ListItemNode;
    nodes.add(
      ListItemNode(
        id: nodeId,
        itemType: itemType,
        indent: indent,
        text: nodeToMerge.text.insert(
          textToInsert: attributedText,
          startOffset: nodeToMerge.text.text.length,
        ),
      ),
    );
  } else {
    final node = ListItemNode(
      id: nodeId,
      itemType: itemType,
      indent: indent,
      text: attributedText,
    );

    nodes.add(node);
  }
}

void _convertDeltaToParagraphNode(
  String nodeId,
  String text,
  Operation operation,
  List<DocumentNode> nodes,
) {
  final attributedText = AttributedText(
    text: text,
    spans: _convertAttributesToAttributedSpans(
      operation.attributes ?? {},
      text,
    ),
  );

  if (nodes.isNotEmpty && nodes.last.id == nodeId) {
    final nodeToMerge = nodes.removeLast() as ParagraphNode;
    nodes.add(
      ParagraphNode(
        id: nodeId,
        text: nodeToMerge.text.insert(
          textToInsert: attributedText,
          startOffset: nodeToMerge.text.text.length,
        ),
        metadata: nodeToMerge.metadata,
      ),
    );
  } else {
    final node = ParagraphNode(
      id: nodeId,
      metadata: {
        if (operation.attributes?['heading'] == 1)
          'blockType': header1Attribution,
        if (operation.attributes?['heading'] == 2)
          'blockType': header2Attribution,
      },
      text: attributedText,
    );

    nodes.add(node);
  }
}

AttributedSpans _convertAttributesToAttributedSpans(
  Map<String, dynamic> attributes,
  String text,
) {
  return AttributedSpans(
    attributions: [
      if (attributes['bold'] == true) ...[
        const SpanMarker(
          attribution: boldAttribution,
          offset: 0,
          markerType: SpanMarkerType.start,
        ),
        SpanMarker(
          attribution: boldAttribution,
          offset: max(0, text.length - 1),
          markerType: SpanMarkerType.end,
        ),
      ],
      if (attributes['italic'] == true) ...[
        const SpanMarker(
          attribution: italicsAttribution,
          offset: 0,
          markerType: SpanMarkerType.start,
        ),
        SpanMarker(
          attribution: italicsAttribution,
          offset: max(0, text.length - 1),
          markerType: SpanMarkerType.end,
        ),
      ],
      if (attributes['strike'] == true) ...[
        const SpanMarker(
          attribution: strikethroughAttribution,
          offset: 0,
          markerType: SpanMarkerType.start,
        ),
        SpanMarker(
          attribution: strikethroughAttribution,
          offset: max(0, text.length - 1),
          markerType: SpanMarkerType.end,
        ),
      ],
      if (attributes.containsKey('link')) ...[
        SpanMarker(
          attribution: LinkAttribution(
            url: Uri.parse(attributes['link'] as String),
          ),
          offset: 0,
          markerType: SpanMarkerType.start,
        ),
        SpanMarker(
          attribution: LinkAttribution(
            url: Uri.parse(attributes['link'] as String),
          ),
          offset: max(0, text.length - 1),
          markerType: SpanMarkerType.end,
        ),
      ],
    ],
  );
}

class UnsupportedDocumentNodeTypeError extends Error {
  UnsupportedDocumentNodeTypeError(this.node);
  final DocumentNode node;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnsupportedDocumentNodeTypeError &&
          runtimeType == other.runtimeType &&
          node == other.node;

  @override
  int get hashCode => node.hashCode;

  @override
  String toString() {
    return 'Tried to convert an unsupported DocumentNode into a Delta. Node: $node';
  }
}

class OrphanedOperationsError extends Error {
  OrphanedOperationsError({required this.operations});
  final List<Operation> operations;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrphanedOperationsError &&
          runtimeType == other.runtimeType &&
          const ListEquality().equals(operations, other.operations);

  @override
  int get hashCode => const ListEquality().hash(operations);

  @override
  String toString() {
    return 'Expected a newline and a node_id attribute, but document ended '
        'before a newline and a node_id attribute were found. Orphaned '
        'operations: ${operations.toString()}';
  }
}
