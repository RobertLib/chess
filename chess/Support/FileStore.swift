//
//  FileStore.swift
//  chess
//
//  The stores too large for UserDefaults — the archive, the review cache,
//  the puzzle progress and the player's mistakes — each kept in a file of
//  its own, and the copies set aside of whatever stored data did not read.
//

import Foundation
import Synchronization
import UIKit

// MARK: - Files

/// A directory of JSON files, one per store.
///
/// Up to 1.0.1 everything the app kept lived in UserDefaults, and the archive
/// alone came to a megabyte or two. That is the wrong place for it: every
/// write has cfprefsd write the whole domain out again — and the unfinished
/// game is saved after every move — the whole domain is read into memory at
/// launch, and some platforms refuse a domain of four megabytes or more
/// outright. The settings, the unfinished game and the other small things
/// stay where they were; what grows lives here, where a write costs only the
/// store it is for.
///
/// The files are the player's games and progress, so they live in
/// Application Support and go into backups with the rest of the app's data;
/// none of them is excluded. The review cache could be rebuilt, but only by
/// searching every review again, which costs far more than its few hundred
/// kilobytes of backup do.
///
/// Nonisolated, so that the background writer can carry it. The directory
/// never changes; what the store has learnt about its files — which did not
/// read, and which were not written — is kept behind a lock, because the
/// main actor reads them and the writer writes them.
nonisolated final class FileStore: Sendable {
    let directory: URL

    /// What the store knows of its files beyond what is in them.
    private struct Status {
        /// Files that were there but did not read, the last time they were
        /// read (see `contents(of:)`).
        var unread: Set<String> = []
        /// Files whose latest write did not land (see `lastWriteLanded`).
        var unsaved: Set<String> = []
    }

    private let status = Mutex(Status())

    /// Why a write or a removal was turned away: the file is there, but did
    /// not read the last time it was read.
    struct UnreadFile: Error {
        let name: String
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// The app's own.
    static let standard = FileStore(
        directory: URL.applicationSupportDirectory.appending(path: "LocalStore", directoryHint: .isDirectory)
    )

    func url(for name: String) -> URL {
        directory.appending(path: name + ".json", directoryHint: .notDirectory)
    }

    /// The file `name`, or nil when there is no such file. Anything else that
    /// keeps it from reading is thrown, not taken for "no file": read with
    /// `try?`, a file that was there all along — kept from the app for a
    /// moment by data protection, or by an error reading the disk — read as
    /// a store that had never been written, and the next save wrote one game
    /// over an archive of six hundred.
    ///
    /// A file that does not read is noted, and is not written over or removed
    /// until it has read again (see `write`): whatever is in it is still the
    /// player's, and a later read — the next access, or the next launch —
    /// may well get it back. A store that read it as nothing holds nothing of
    /// what it would be writing over.
    func contents(of name: String) throws -> Data? {
        do {
            let data = try Data(contentsOf: url(for: name))
            status.withLock { _ = $0.unread.remove(name) }
            return data
        } catch where Self.isNoSuchFile(error) {
            status.withLock { _ = $0.unread.remove(name) }
            return nil
        } catch {
            status.withLock { _ = $0.unread.insert(name) }
            throw error
        }
    }

    /// The file `name`, or nil when it is not there or did not read — for
    /// whoever has nothing to do about the difference. It is noted all the
    /// same (see `contents(of:)`).
    func read(_ name: String) -> Data? {
        (try? contents(of: name)) ?? nil
    }

    /// Whether the file `name` was there but did not read, the last time it
    /// was read.
    func isUnread(_ name: String) -> Bool {
        status.withLock { $0.unread.contains(name) }
    }

    /// Writes the file whole: to one beside it first, which then takes its
    /// place. A write cut short — the app ended half way through — leaves
    /// the file as it was, rather than the start of one store and none of
    /// the rest. The directory is made on the way, the first time.
    ///
    /// Turned away for a file that did not read (see `contents(of:)`). A
    /// write that does not land, for that or any other reason — a full disk —
    /// is noted until one does.
    func write(_ data: Data, as name: String) throws {
        do {
            guard !isUnread(name) else { throw UnreadFile(name: name) }
            let url = url(for: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            status.withLock { _ = $0.unsaved.remove(name) }
        } catch {
            status.withLock { _ = $0.unsaved.insert(name) }
            throw error
        }
    }

    /// `value` encoded and written as the file `name`. A value that does not
    /// encode — a number JSON has no way to write, say — is a write that did
    /// not land, as one the disk turned away is.
    func save(_ value: some Encodable, as name: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            status.withLock { _ = $0.unsaved.insert(name) }
            throw error
        }
        try write(data, as: name)
    }

    /// Whether the latest write of the file `name` landed — or none has been
    /// asked for. What waits on a store being safely written asks this, on
    /// the writer, once the write is behind it (see `LocalStore.remove(_:onceFiled:)`).
    func lastWriteLanded(_ name: String) -> Bool {
        status.withLock { !$0.unsaved.contains(name) }
    }

    /// Removes the file, unless it did not read (see `contents(of:)`).
    func remove(_ name: String) {
        guard !isUnread(name) else { return }
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Whether `error` says only that the file is not there: the one failure
    /// that means there is no store to read, rather than one that could not
    /// be read just now.
    private static func isNoSuchFile(_ error: any Error) -> Bool {
        if let error = error as? CocoaError { return error.code == .fileReadNoSuchFile }
        if let error = error as? POSIXError { return error.code == .ENOENT }
        return false
    }
}

extension FileStore {
    /// The files that go with `defaults`, which is what `LocalStore.defaults`
    /// hands its files on to when it is swapped: the app's own for the
    /// standard defaults, and for any other suite — which only a test swaps
    /// in — a directory of its own in the temporary directory. The same
    /// suite swapped in again finds the same directory, so a test that puts
    /// its store away while it waits picks up where it left off.
    ///
    /// Paired rather than swapped on their own so that a test cannot swap one
    /// store and forget the other: the scratch suites came long before the
    /// files did, and every helper that swaps one in now takes a scratch
    /// directory along with it without having to be told.
    @MainActor static func paired(with defaults: UserDefaults) -> FileStore {
        if defaults === UserDefaults.standard { return .standard }
        if let paired = scratchStores.object(forKey: defaults) { return paired }
        let scratch = FileStore(directory: FileManager.default.temporaryDirectory.appending(
            path: "LocalStore-" + UUID().uuidString, directoryHint: .isDirectory
        ))
        scratchStores.setObject(scratch, forKey: defaults)
        return scratch
    }

    /// Held only as long as the suite is: a suite that has gone cannot be
    /// swapped in again, and a new one with the same name starts afresh, as
    /// its defaults do.
    @MainActor private static let scratchStores = NSMapTable<UserDefaults, FileStore>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory
    )
}

// MARK: - The stores in files

extension LocalStore {

    /// The stored data of the store kept in the file `name`, or nil when
    /// there is none. Read after every write asked for has landed, so that it
    /// is never older than what was last saved.
    ///
    /// Each file is named after the key its store was kept under in
    /// UserDefaults up to 1.0.1. The first time a store is read and its file
    /// is not there, the key is looked for instead, and what is under it
    /// moved across — written to the file, then dropped from UserDefaults —
    /// so that nothing is lost by updating. It moves as it was stored, not
    /// read and written out again, so whatever in it this build cannot read
    /// is still there for the reader to leave out and set aside.
    ///
    /// A file that is there but does not read is nil as well, and nothing
    /// stands in for it: not the key, which a move cut short may have left
    /// behind and would be moved across over it, and not a save, which the
    /// file turns away until it has read again (see `FileStore.contents(of:)`).
    /// It is tried again at the next read.
    static func data(inFile name: String) -> Data? {
        flush()
        moveLegacySetAsideCopies()
        let stored: Data?
        do {
            stored = try files.contents(of: name)
        } catch {
            return nil
        }
        if let stored {
            // A move cut short between the two steps; the file is the store.
            if defaults.object(forKey: name) != nil { defaults.removeObject(forKey: name) }
            return stored
        }
        guard let data = defaults.data(forKey: name) else { return nil }
        let files = files
        let destination = Destination(store: defaults)
        enqueue {
            // Should the file not be written, the key stays to be moved the
            // next time, and the data in hand is what the store reads now.
            guard (try? files.write(data, as: name)) != nil else { return }
            destination.store.removeObject(forKey: name)
        }
        return data
    }

    /// Encodes `value` and writes it to the file `name`, off the main thread,
    /// one write after another in the order they were asked for. The caller
    /// keeps its own copy in memory and reads that rather than the file.
    ///
    /// Nobody is waiting to be told when a write fails, but the file store
    /// remembers that it did (see `FileStore.lastWriteLanded`), for whatever
    /// must not go ahead unless it has — the unfinished game, which goes only
    /// once the archive holds it.
    static func saveInBackground<Value: Encodable & Sendable>(_ value: Value, toFile name: String) {
        let files = files
        enqueue { try? files.save(value, as: name) }
    }

    /// `list(of:inFile:)`, with the file read and decoded on the writer
    /// rather than on the main actor — in its turn among the writes, so that,
    /// like a read after `flush()`, it is never older than what was last
    /// saved. For a store large enough to be felt: the archive, six hundred
    /// games, held the menu up at every launch while it decoded.
    ///
    /// What is left to the main actor costs next to nothing: dropping a key
    /// left beside the file, and setting aside a list that did not read in
    /// full. A file that is not there, or did not read, is handed to
    /// `list(of:inFile:)`, which moves a store still kept under its old key
    /// across, once, and answers a file that did not read with nothing.
    static func listInBackground<Element: Decodable & Sendable>(
        of type: Element.Type, inFile name: String
    ) async -> [Element] {
        moveLegacySetAsideCopies()
        let store = defaults
        let source = files
        let stored: (data: Data, entries: [Element], isComplete: Bool)? = await withCheckedContinuation { continuation in
            writer.async(qos: .userInitiated) {
                guard let data = source.read(name) else { return continuation.resume(returning: nil) }
                let decoded = LocalStore.entries(of: type, in: data)
                continuation.resume(returning: (data, decoded.read, decoded.isComplete))
            }
        }
        // Swapped for another store meanwhile, which only a test does: that
        // one is read the ordinary way.
        guard let stored, store === defaults, source === files else {
            return list(of: type, inFile: name)
        }
        if defaults.object(forKey: name) != nil { defaults.removeObject(forKey: name) }
        if !stored.isComplete { setAside(stored.data, forKey: name) }
        return stored.entries
    }

    // MARK: Dropping what has been filed elsewhere

    /// A key given up by `remove(_:onceFiled:)`, and not set since. Held
    /// with its store, which only the tests ever swap: a game saved in one
    /// test's store must not call off the clear waiting in another's.
    private struct Withdrawal {
        let store: UserDefaults
        let key: String
        let id: Int
    }

    private static var withdrawals: [Withdrawal] = []
    private static var lastWithdrawal = 0

    /// Drops `key` from the defaults, but only once the file `name` holds
    /// what it is being dropped for. The unfinished game is cleared when the
    /// game ends, and the game is filed in the archive at the same moment —
    /// but the archive is written in the background, and the clear was
    /// immediate. Ended by the system in between, or with the archive's write
    /// turned away by a full disk, the app had lost the game from both.
    ///
    /// So the key waits its turn on the writer, behind the write of `name`
    /// asked for in this same turn, and goes only if that write landed. It
    /// joins the writer at the end of the turn rather than now, because the
    /// game is cleared before it is filed (`GameViewModel.persist` comes
    /// before `recordResult`). Should the write not land, the key is left
    /// where it is, for the next launch to find: an unfinished game a move
    /// short of its end beats no game at all.
    ///
    /// From now on the key reads as gone, whether or not it has gone yet (see
    /// `isWithdrawn`), and setting it again (`set(_:forKey:)`) calls the drop
    /// off — a new game begun before the archive had been written must not
    /// be cleared with the old one.
    static func remove(_ key: String, onceFiled name: String) {
        let destination = Destination(store: defaults)
        let files = files
        lastWithdrawal += 1
        let id = lastWithdrawal
        withdrawals.removeAll { $0.store === destination.store && $0.key == key }
        withdrawals.append(Withdrawal(store: destination.store, key: key, id: id))
        Task { @MainActor in
            enqueue {
                let landed = files.lastWriteLanded(name)
                Task { @MainActor in
                    guard landed, let index = withdrawals.firstIndex(where: { $0.id == id }) else { return }
                    destination.store.removeObject(forKey: key)
                    withdrawals.remove(at: index)
                }
            }
        }
    }

    /// Whether `key` has been given up by `remove(_:onceFiled:)` in this
    /// store, and not set since — whether it has gone from the defaults yet
    /// or been kept for the next launch.
    static func isWithdrawn(_ key: String) -> Bool {
        withdrawals.contains { $0.store === defaults && $0.key == key }
    }

    /// Sets `data` under `key`, calling off a drop of it still on its way.
    static func set(_ data: Data, forKey key: String) {
        withdrawals.removeAll { $0.store === defaults && $0.key == key }
        defaults.set(data, forKey: key)
    }

    /// Removes the file `name`, in its turn among the writes, together with
    /// the key the store may still be waiting under in UserDefaults — left
    /// there, it would be moved across again by the next read and bring
    /// back what was removed.
    static func removeInBackground(file name: String) {
        defaults.removeObject(forKey: name)
        let files = files
        enqueue { files.remove(name) }
    }

    // MARK: Set aside

    /// Where the copy of a store that did not read is kept.
    private static func setAsideName(forKey key: String) -> String {
        "Unreadable/" + key
    }

    /// Keeps stored data this build could not read in full as a file of its
    /// own, so that a save replacing it does not lose it for good — a later
    /// build may be able to read what this one could not.
    ///
    /// One copy per store, each replacing the one before. Kept in
    /// UserDefaults, as they were, the copies were read into memory at every
    /// launch, as large as the stores they were taken of, and kept for ever.
    /// The latest is the one kept because a store is copied aside only once
    /// for each thing that goes wrong with it: once read, what did not read
    /// is left out of the next save, and the store reads in full again until
    /// something new goes wrong — which is then what the next build to look
    /// at the copy has to put right. The same data set aside again, from a
    /// store read again before it was saved, is not written a second time.
    static func setAside(_ data: Data, forKey key: String) {
        let files = files
        let name = setAsideName(forKey: key)
        enqueue {
            guard files.read(name) != data else { return }
            try? files.write(data, as: name)
        }
    }

    /// The copy last set aside of the store `key`, once every write asked
    /// for has landed. Nil when nothing of it has been.
    static func setAsideCopy(forKey key: String) -> Data? {
        moveLegacySetAsideCopies()
        flush()
        return files.read(setAsideName(forKey: key))
    }

    /// Every store that kept what it could not read in UserDefaults, under
    /// `<key>.unreadable`.
    private static let legacySetAsideKeys = [
        "gameArchive", "mistakes", "mistakeGames", "puzzleProgress", "openingProgress",
        "achievements", "savedGame", "finishedGame",
    ]

    /// The defaults whose old copies have been moved out already.
    private static var tidiedDefaults: UserDefaults?

    /// Moves the copies earlier builds set aside in UserDefaults out into
    /// files, once for each store swapped in. A copy only goes where no
    /// newer one has been set aside since, and the key is dropped once its
    /// copy has been written.
    private static func moveLegacySetAsideCopies() {
        guard tidiedDefaults !== defaults else { return }
        tidiedDefaults = defaults
        let files = files
        let destination = Destination(store: defaults)
        for key in legacySetAsideKeys {
            let legacyKey = key + ".unreadable"
            guard let data = defaults.data(forKey: legacyKey) else { continue }
            let name = setAsideName(forKey: key)
            enqueue {
                if files.read(name) == nil {
                    guard (try? files.write(data, as: name)) != nil else { return }
                }
                destination.store.removeObject(forKey: legacyKey)
            }
        }
    }

    // MARK: Writing in the background

    /// Runs `work` on the writer, after everything asked for before it.
    ///
    /// The app is kept running until it is done. Suspended in the middle of
    /// a write — the player has just finished a game and gone straight to
    /// the home screen — the app could be ended by the system before it ever
    /// ran again, and the game it was filing with it.
    static func enqueue(_ work: @escaping @Sendable () -> Void) {
        let assertion = BackgroundAssertion()
        writer.async {
            work()
            Task { @MainActor in assertion.end() }
        }
    }
}

/// Background time asked of the system for one write, and handed back as
/// soon as it has landed — or when the system wants it back, the write being
/// atomic either way.
@MainActor
private final class BackgroundAssertion {
    private var task = UIBackgroundTaskIdentifier.invalid

    init() {
        task = UIApplication.shared.beginBackgroundTask(withName: "LocalStore") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
