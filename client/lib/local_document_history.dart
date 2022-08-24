import 'package:clock/clock.dart';
import 'package:quill_delta/quill_delta.dart';

/// Stores all the changes for a given [Delta] document, and knows how to undo
/// and redo those changes.
class LocalDocumentHistory {
  /// Creates a new undo/redo history.
  ///
  /// The [initialDocument] is the initial state of the document that we're
  /// tracking. Whenever the user changes anything in the document, that change
  /// should be tracked with [composeLocalChange]. Likewise, whenever the remote
  /// document changes, that change should be tracked with [composeRemoteChange].
  ///
  /// The [mergeThreshold] parameter controls the limit where incoming
  /// changes should be split into a new change in the undo stack. For example,
  /// if the user types "a", "b", and "c" faster than the [mergeThreshold] is,
  /// those three changes will be composed together into "abc".
  ///
  /// The [maximumHistoryLength] parameter limits the size of the undo stack. If
  /// the user types "a", "b", and "c", and [maximumHistoryLength] is 2, then
  /// only the insertions of "b" and "c" can be undone.
  LocalDocumentHistory({
    required Delta initialDocument,
    this.mergeThreshold = const Duration(seconds: 1),
    this.maximumHistoryLength = 100,
  }) : _document = initialDocument;

  Delta _document;
  DateTime? _lastModification;

  final Duration mergeThreshold;
  final int maximumHistoryLength;

  final _undoStack = <Delta>[];
  final _redoStack = <Delta>[];

  /// Composes [change] against the current [_document] and returns an updated
  /// document that includes that change. Records the inverted version of [change]
  /// in the [_undoStack] so that the change can be reverted (by calling [undo])
  /// in the future.
  ///
  /// Multiple subsequent changes happening faster than [mergeThreshold] will be
  /// composed together as a single change that will be a single entry in [_undoStack].
  ///
  /// If the [_undoStack] becomes larger than [maximumHistoryLength] as a result
  /// of calling this method, the least recent entry from the [_undoStack] will
  /// be removed.
  ///
  /// The [_redoStack] will be cleared on each call of this method.
  Delta composeLocalChange(Delta change) {
    if (change.isEmpty) return _document;

    var invertedChange = _invertChange(change);
    if (invertedChange.isNotEmpty) {
      // Add the inverted version of the change into the undo stack, so that the
      // change can be reverted on demand by calling `_document.compose(invertedChange)`.
      _undoStack.add(invertedChange);
    }

    if (_undoStack.length > maximumHistoryLength) {
      // The undo stack is larger than the limit we have set for it. Remove the
      // least recent entry to make space for new ones.
      _undoStack.removeAt(0);
    }

    // Since redo is only available after the user undoes operations, we should
    // clear the redo stack every time the user changes the document manually.
    _redoStack.clear();

    _document = _document.compose(change);
    return _document;
  }

  Delta _invertChange(Delta change) {
    // Invert the change using the current state of the document as a base, so
    // that we can later undo it by just doing `_document.compose(invertedChange)`.
    var invertedChange = change.invert(_document);

    final now = clock.now();
    final lastModification = _lastModification;
    final canMergeWithPreviousUndoOperation = lastModification != null &&
        _undoStack.isNotEmpty &&
        now.difference(lastModification) <= mergeThreshold;

    if (canMergeWithPreviousUndoOperation) {
      // Compose the inverted version of current change on top of the last change
      // in the undo stack, effectively merging the two.
      final lastInvertedChange = _undoStack.removeLast();
      invertedChange = invertedChange.compose(lastInvertedChange);
    } else {
      _lastModification = now;
    }

    return invertedChange;
  }

  /// Composes [change] against the current [_document] and returns an updated
  /// document that includes that change.
  ///
  /// Additionally, transforms the current [_undoStack] and [_redoStack] so that
  /// both of them are up-to-date with the remote [change]. Without this, when
  /// trying to undo or redo changes, the operations in undo and redo stacks
  /// would be pointing to old locations in the document and wouldn't result in
  /// a wanted state.
  ///
  /// As this is not a local change, it will not be stored in [_undoStack].
  Delta composeRemoteChange(Delta delta) {
    _transformHistory(_undoStack, delta);
    _transformHistory(_redoStack, delta);
    _document = _document.compose(delta);
    return _document;
  }

  void _transformHistory(List<Delta> history, Delta delta) {
    var acc = delta;

    for (var i = history.length - 1; i >= 0; i--) {
      final change = history[i];
      final transformedChange = acc.transform(change, true);
      acc = change.transform(acc, false);

      if (transformedChange.isNotEmpty) {
        history[i] = transformedChange;
      } else {
        // Transforming the remote delta against this stack resulted in an empty
        // change at this position. There's no need to keep this around anymore.
        history.removeAt(i);
      }
    }
  }

  /// Removes the most recent operation in [_undoStack], composes that on top of
  /// [_document] and updates it, and returns the change that consumers should
  /// compose on their current document.
  ///
  /// Also adds the inverted version of the reverted change to [_redoStack], so
  /// that the operation can be reverted on demand by calling [redo].
  ///
  /// If there's nothing to undo, returns an empty [Delta].
  Delta undo() => _applyChange(_undoStack, _redoStack);

  /// Removes the most recent operation in [_redoStack], composes that on top of
  /// [_document] and updates it, and returns the change that consumers should
  /// compose on their current document.
  ///
  /// Also adds the inverted version of the reverted change to [_undoStack], so
  /// that the operation can be reverted on demand by calling [undo].
  ///
  /// If there's nothing to redo, returns an empty [Delta].
  Delta redo() => _applyChange(_redoStack, _undoStack);

  Delta _applyChange(List<Delta> source, List<Delta> destination) {
    if (source.isEmpty) return Delta();

    final change = source.removeLast();
    final invertedChange = change.invert(_document);
    _document = _document.compose(change);
    _lastModification = null;

    final effectiveInvertedChange =
        invertedChange.isNotEmpty ? invertedChange : change.invert(_document);
    destination.add(effectiveInvertedChange);

    return change;
  }
}
