//
//  ShotMarker.swift
//  chess
//
//  A file the app drops once a screen has finished settling, so the App Store
//  media script can wait for the thing it wants to photograph instead of
//  sleeping for a guess. See AppStore/screenshots.md.
//
//  Only the game review needs it. Every other pose is drawn on the first frame
//  and a fixed second or two covers it, but the review has to run the engine
//  over every ply of the game before it can grade anything — twenty seconds for
//  a seven-move game, longer for a real one, and longer again on a slower
//  machine. A guessed wait there photographs a progress bar.
//
//  `#if DEBUG` in full: nothing here reaches an App Store build.
//

#if DEBUG
import Foundation

enum ShotMarker {
    /// `Documents/shot-ready` inside the app container. The script reads the
    /// container path from `simctl get_app_container`, so nothing has to agree
    /// on a location beyond the name.
    private static var url: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("shot-ready")
    }

    /// Says the screen is ready. Writing the file is best-effort: a pose that
    /// cannot write it falls back to the script's timeout, which is the same
    /// behaviour as not having the marker at all.
    static func markReady() {
        guard let url else { return }
        try? Data().write(to: url)
    }
}
#endif
