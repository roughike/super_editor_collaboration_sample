import 'dart:ui';

import 'package:client/document_position_to_delta_position_converter.dart';
import 'package:quill_delta/quill_delta.dart';
import 'package:super_editor/super_editor.dart';

const _converter = DocumentPositionToDeltaPositionConverter();

/// A class that knows how to transform an existing [DocumentSelection] with a
/// given [Delta].
///
/// Proper selection transformation is the backbone of realtime collaborative
/// editing. We'll see why with a simple example.
///
/// Let's assume that you're editing a document with someone else. Let's also
/// assume that "|" in the following example represents your collapsed I-beam
/// selection cursor.
///
/// Given current document of:
///
///     abc|de
///
/// Someone else inserts "XXX" at the very start, WITHOUT selection transformation,
/// your document would look like this:
///
///     XXX|abcde
///
/// But WITH selection transformation, your document will look like this:
///
///     XXXabc|de
///
/// As your cursor started between the "c" and "d" characters, and you didn't
/// edit the document, but someone else did, your cursor should stay between "c"
/// and "d". Your cursor should only move when you make edits.
///
/// Without transforming your selection, proper collaboration becomes impossible.
/// If you were typing at the same time with the other person, your text would
/// be inserted at random places due to the other person moving your document
/// selection, and vice versa.
///
/// Even though the above sample was very simple, this selection transformer
/// knows how to handle all of the complex edge cases as well. That includes
/// multi-paragraph insertions, edits, deletions, inserting a newline inside an
/// existing selection, and all that jazz.
class DocumentSelectionTransformer {
  const DocumentSelectionTransformer();

  /// Transforms [oldSelection] into a new [DocumentSelection] where the base and
  /// extent positions are shifted according to the changes in the given [delta].
  ///
  /// The [oldDocument] should be the state of the document before [delta] was
  /// applied. The [newDocument] is the state of the document after applying the
  /// [delta].
  ///
  /// The [oldSelection] is the [DocumentSelection] in the [oldDocument] before
  /// applying the [delta].
  DocumentSelection transform({
    required Document oldDocument,
    required Document newDocument,
    required DocumentSelection oldSelection,
    required Delta delta,
  }) {
    // First, we'll convert the node-relative base and extent positions to
    // absolute positions compatible with the QuillJS Delta format...
    final oldBaseOffset = _converter.documentPositionToDeltaPosition(
      document: oldDocument,
      position: oldSelection.base,
    );
    final oldExtentOffset = _converter.documentPositionToDeltaPosition(
      document: oldDocument,
      position: oldSelection.extent,
    );

    // ...then, we use the utility method in the delta library to transform those
    // absolute positions based on the changes made in the given delta...
    final newBaseOffset = delta.transformPosition(oldBaseOffset);
    final newExtentOffset = delta.transformPosition(oldExtentOffset);

    // ...and finally, we'll convert the absolute delta positions back to relative,
    // node-local positions and return a new DocumentSelection based on them.
    if (newBaseOffset == newExtentOffset) {
      return DocumentSelection.collapsed(
        position: _converter.deltaPositionToDocumentPosition(
          document: newDocument,
          absolutePosition: newBaseOffset,
          textAffinity: TextAffinity.downstream,
        ),
      );
    }

    return DocumentSelection(
      base: _converter.deltaPositionToDocumentPosition(
        document: newDocument,
        absolutePosition: newBaseOffset,
        textAffinity: _textAffinity(oldSelection.base),
      ),
      extent: _converter.deltaPositionToDocumentPosition(
        document: newDocument,
        absolutePosition: newExtentOffset,
        textAffinity: _textAffinity(oldSelection.extent),
      ),
    );
  }
}

TextAffinity _textAffinity(DocumentPosition position) {
  final nodePosition = position.nodePosition;
  return nodePosition is TextNodePosition
      ? nodePosition.affinity
      : TextAffinity.downstream;
}
