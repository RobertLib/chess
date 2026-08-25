//
//  Motion.swift
//  chess
//
//  Honours the system "Reduce Motion" setting. Movement that carries meaning —
//  a piece travelling to its square — is kept but flattened; movement that is
//  only decoration — pulsing, drifting, confetti — is switched off.
//

import SwiftUI

/// Live mirror of the system setting. It is observable rather than a plain
/// read of `UIAccessibility` so that turning Reduce Motion on or off while the
/// app is open reaches views that have already been drawn: a body that asks
/// `Motion` anything is re-evaluated when the answer changes.
@Observable
@MainActor
final class MotionSettings {
    static let shared = MotionSettings()

    private(set) var isReduced: Bool

    private init() {
        isReduced = UIAccessibility.isReduceMotionEnabled
        // Never removed: this object lives as long as the app does.
        _ = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is delivered on the main queue, which is where
            // this object lives.
            MainActor.assumeIsolated {
                self?.isReduced = UIAccessibility.isReduceMotionEnabled
            }
        }
    }
}

@MainActor
enum Motion {

    static var isReduced: Bool { MotionSettings.shared.isReduced }

    /// An animation that conveys something (a piece moving, a panel arriving).
    /// Under Reduce Motion the spring is replaced by a short, flat fade rather
    /// than removed, so the board is still followable.
    static func meaningful(
        _ animation: Animation,
        reduced: Animation = .easeInOut(duration: 0.15)
    ) -> Animation {
        isReduced ? reduced : animation
    }

    /// A purely decorative animation — nil under Reduce Motion, which makes
    /// `withAnimation` apply the change instantly.
    static func decorative(_ animation: Animation) -> Animation? {
        isReduced ? nil : animation
    }

    /// Whether an endlessly repeating decoration should run at all.
    static var allowsRepeatingDecoration: Bool { !isReduced }

    /// A transition for whole screens: sliding and scaling become a plain fade.
    static func transition(_ transition: AnyTransition) -> AnyTransition {
        isReduced ? .opacity : transition
    }
}
