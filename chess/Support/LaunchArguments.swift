//
//  LaunchArguments.swift
//  chess
//
//  The development switches a launch can carry — `--puzzles`, `--auto-game`
//  and the rest — acted on once per launch.
//

#if DEBUG
import Foundation

@MainActor
enum LaunchArguments {
    private static var handled: Set<String> = []

    /// The switches, the first time `site` asks for them; none after that.
    ///
    /// The pages that read them do it in `onAppear`, which runs again every
    /// time a full-screen page over them closes. `--puzzles` then opened
    /// Puzzles again the moment it was closed, and `--demo-achievement` put
    /// up another banner, in the middle of the UI tests that launch with them.
    static func once(for site: String) -> [String] {
        handled.insert(site).inserted ? ProcessInfo.processInfo.arguments : []
    }
}
#endif
