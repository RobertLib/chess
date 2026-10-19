//
//  AchievementPresenter.swift
//  chess
//
//  Shows the banner for an achievement just earned above everything else on
//  screen. Achievements are earned on full-screen pages — a puzzle, a review,
//  the archive — and an overlay on the root view would be drawn underneath
//  them, timing out unseen. A window of its own sits above every presentation.
//

import SwiftUI
import UIKit

@MainActor
final class AchievementPresenter {
    static let shared = AchievementPresenter()

    private var window: UIWindow?
    /// Takes the window down once the last banner has slid away.
    private var hideTask: Task<Void, Never>?
    /// Where the banner is on screen, in window coordinates, while one is
    /// up. The window takes the touches inside it and no others.
    fileprivate var bannerFrame: CGRect?

    /// How long a banner stays up untouched. Longer in a UI test that asks
    /// for it, which needs time to tap around the banner before tapping it;
    /// at three seconds that race was lost about one run in two.
    static var bannerDuration: Duration {
#if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--banner-seconds=") }),
           let seconds = Int(argument.dropFirst("--banner-seconds=".count)) {
            return .seconds(seconds)
        }
#endif
        return .seconds(3)
    }

    private init() {}

    /// Sets the banner window up over the app's scene. Safe to call more than
    /// once; only the first call does anything.
    ///
    /// The window is only on screen while there is a banner in it. UIKit asks
    /// the topmost full-screen window whether the status bar and the home
    /// indicator should show, and one left up for good above everything
    /// answered for every page underneath it — the chess clock asked for both
    /// to be hidden and was never heard.
    func install() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AchievementBannerHost())
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.isHidden = true
        self.window = window
        followQueue()
    }

    /// Shows the window when an achievement joins the queue, and hides it
    /// again when the queue runs out.
    private func followQueue() {
        let hasBanner = withObservationTracking {
            !Achievements.shared.justUnlocked.isEmpty
        } onChange: {
            Task { @MainActor in self.followQueue() }
        }
        hideTask?.cancel()
        if hasBanner {
            window?.isHidden = false
        } else {
            // Cleared here rather than as the banner leaves the screen: the
            // next one in the queue arrives as this one goes, and a frame
            // cleared on the way out would have left it untappable.
            bannerFrame = nil
            guard window?.isHidden == false else { return }
            // Long enough for the banner's way out to finish on screen.
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.window?.isHidden = true
            }
        }
    }
}

/// A window that only takes the touches that land on the banner: taps on the
/// empty space around it fall through to the app underneath.
///
/// Decided by the banner's frame rather than by which view the hit test
/// finds. SwiftUI content need not be a view of its own — from iOS 18 a
/// touch on it can come back as the hosting view itself, the same answer as
/// for the empty space around it — and treating that answer as "nothing here"
/// let a tap on the banner fall through to whatever lay under it, the Back
/// button of the page it was earned on among them.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let frame = AchievementPresenter.shared.bannerFrame, frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The banner itself, taking the earned achievements one at a time.
private struct AchievementBannerHost: View {
    var body: some View {
        VStack {
            if let achievement = Achievements.shared.justUnlocked.first {
                AchievementBanner(achievement: achievement)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        AchievementPresenter.shared.bannerFrame = frame
                    }
                    .padding(.top, 8)
                    .transition(Motion.transition(.move(edge: .top).combined(with: .opacity)))
                    .id(achievement.id)
                    .task(id: achievement.id) {
                        AccessibilityNotification.Announcement(
                            String(localized: "announce.achievement",
                                   defaultValue: "Achievement earned: \(String(localized: achievement.title))",
                                   comment: "Spoken when an achievement is earned")
                        ).post()
                        try? await Task.sleep(for: AchievementPresenter.bannerDuration)
                        dismiss(achievement.id)
                    }
                    .onTapGesture { dismiss(achievement.id) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.meaningful(.spring(duration: 0.4)), value: Achievements.shared.justUnlocked.first?.id)
    }

    /// Takes this achievement off the queue — by identity, so a tap and the
    /// timer racing each other cannot take off the one behind it as well.
    private func dismiss(_ id: Achievement.ID) {
        withAnimation(Motion.meaningful(.easeInOut(duration: 0.3))) {
            if Achievements.shared.justUnlocked.first?.id == id {
                Achievements.shared.justUnlocked.removeFirst()
            }
        }
    }
}
