//
//  ScratchStoreLock.swift
//  chessTests
//
//  One test at a time may keep a scratch store swapped in across a wait.
//

import Foundation
@testable import chess

/// `LocalStore.defaults` is one global. A synchronous test swaps its scratch
/// store in and back within a single turn of the main actor, so no other test
/// ever sees it. A test that waits on the engine keeps its store swapped in
/// across the wait, and suites run in parallel: two such tests, each resumed
/// inside the other's store, read and wrote each other's data — a mistake
/// puzzle's entry was gone the moment another suite's wait ended.
///
/// The files the large stores live in (`LocalStore.files`) follow the
/// defaults: a scratch suite swapped in brings a scratch directory of its own
/// with it, and swapping the old suite back brings back the old directory. So
/// the swap is all a test needs for both — and `FileStore.discard` is how it
/// clears the directory away afterwards, as `removePersistentDomain` clears
/// the suite.
///
/// Every async scratch-store helper takes this first and gives it back last.
@MainActor
enum ScratchStoreLock {
    private static var isHeld = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the lock straight to the next test waiting, if there is one.
    static func release() {
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension FileStore {
    /// Deletes the scratch directory with everything in it. Only ever for one
    /// a test swapped in — never `FileStore.standard`, the app's own.
    func discard() {
        precondition(self !== FileStore.standard, "the app's own store")
        try? FileManager.default.removeItem(at: directory)
    }
}
