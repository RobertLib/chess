//
//  Haptics.swift
//  chess
//

import UIKit

@MainActor
enum Haptics {
    static var isEnabled = true

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()

    /// Warms the Taptic Engine so the first tap of a game is as crisp as the
    /// rest. Cheap to call; the system winds down again on its own.
    static func prepare() {
        guard isEnabled else { return }
        light.prepare()
        medium.prepare()
        rigid.prepare()
        notification.prepare()
    }

    static func pieceSelected() {
        guard isEnabled else { return }
        light.impactOccurred(intensity: 0.7)
    }

    static func pieceMoved() {
        guard isEnabled else { return }
        rigid.impactOccurred(intensity: 0.8)
    }

    static func capture() {
        guard isEnabled else { return }
        medium.impactOccurred(intensity: 1.0)
    }

    static func check() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }

    static func illegal() {
        guard isEnabled else { return }
        notification.notificationOccurred(.error)
    }

    static func gameEnded(win: Bool) {
        guard isEnabled else { return }
        notification.notificationOccurred(win ? .success : .error)
    }
}
