//
//  ChessClockView.swift
//  chess
//
//  A chess clock for a game on a real board: the phone lies between the two
//  players, each taps their own half to end their turn. The far half is
//  turned towards the player sitting on that side.
//

import SwiftUI

// MARK: - Model

@Observable
@MainActor
final class ChessClockModel {
    private(set) var clock: ChessClock
    /// The side whose flag has fallen, once one has.
    private(set) var flagged: PieceColor?
    private let timeSource: () -> TimeInterval
    private var watchTask: Task<Void, Never>?
    private var warned: Set<PieceColor> = []

    init(control: TimeControl, timeSource: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = ChessClock(control: control)
        self.timeSource = timeSource
    }

    var now: TimeInterval { timeSource() }

    func remaining(for color: PieceColor) -> TimeInterval {
        clock.remaining(for: color, at: now)
    }

    var isRunning: Bool { clock.isRunning }
    var isPaused: Bool { clock.isPaused }
    /// A flag that fell on the first turn counts: the stopped clock has no
    /// side on turn and no moves, and both halves went back to "Black taps
    /// here to start White's clock" beside "Time!", to taps that do nothing.
    var hasStarted: Bool { clock.hasStarted || flagged != nil }

    /// The player on `color`'s side has tapped their half: their turn is
    /// over. The very first tap starts the other side's clock — the way a
    /// real clock is started, by the player who does not move first.
    func tap(_ color: PieceColor) {
        guard flagged == nil else { return }
        let time = now
        if clock.active == nil {
            clock.start(color.opponent, at: time)
        } else if clock.active == color {
            if clock.isPaused { clock.resume(at: time) }
            // A tap in the moment between the flag falling and the watch
            // noticing comes too late, and must not press: the press would
            // hand the increment back to a side already out of time.
            if let side = clock.flagged(at: time) {
                flagFell(side, at: time)
                return
            }
            clock.press(at: time)
        } else {
            // Tapping the half that is not running does nothing on a real
            // clock either; a paused clock is resumed by the pause button.
            return
        }
        SoundManager.shared.play(.clockTap)
        Haptics.clockTap()
        if let mover = clock.active?.opponent,
           clock.remaining(for: mover, at: time) > lowTimeThreshold(for: mover) * 1.5 {
            warned.remove(mover)
        }
        watch()
    }

    func pause() {
        clock.pause(at: now)
        watchTask?.cancel()
    }

    func resume() {
        clock.resume(at: now)
        watch()
    }

    func reset(to control: TimeControl) {
        watchTask?.cancel()
        clock = ChessClock(control: control)
        flagged = nil
        warned = []
    }

    func lowTimeThreshold(for color: PieceColor) -> TimeInterval {
        min(10, clock.control.initialTime(for: color) / 6)
    }

    private func watch() {
        watchTask?.cancel()
        guard clock.isRunning else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.clock.isRunning else { return }
                let time = self.now
                if let side = self.clock.flagged(at: time) {
                    self.flagFell(side, at: time)
                    return
                }
                if let side = self.clock.active, !self.warned.contains(side),
                   self.clock.remaining(for: side, at: time) <= self.lowTimeThreshold(for: side),
                   self.clock.control.initialTime(for: side) > self.lowTimeThreshold(for: side) * 2 {
                    self.warned.insert(side)
                    SoundManager.shared.play(.lowTime)
                    Haptics.lowTime()
                }
                let wait = min(0.25, max(0.01, self.clock.timeUntilFlag(at: time) ?? 0.25))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func flagFell(_ side: PieceColor, at time: TimeInterval) {
        watchTask?.cancel()
        clock.stop(at: time)
        flagged = side
        SoundManager.shared.play(.lowTime)
        Haptics.gameEnded(win: false)
        AccessibilityNotification.Announcement(
            String(localized: "announce.flag",
                   defaultValue: "\(side.spokenName)'s time is up",
                   comment: "Spoken when a flag falls on the chess clock")
        ).post()
    }

    func teardown() {
        watchTask?.cancel()
    }
}

// MARK: - View

struct ChessClockView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    let onClose: () -> Void

    @State private var model: ChessClockModel?
    @State private var showPicker = false
    @State private var confirmReset = false
    @State private var pickerSelection: TimeControl?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                VStack(spacing: 0) {
                    half(.black, model: model)
                        .rotationEffect(.degrees(180))
                    controlStrip(model)
                    half(.white, model: model)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        // Each half is a little under half the screen, and the time in it
        // has to stay the biggest thing there: at the largest text sizes the
        // count of moves and the instruction under it ran out of the half.
        .boardTypeLimit()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if model == nil { model = ChessClockModel(control: settings.standaloneTimeControl) }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--chess-clock-running") {
                model?.tap(.black)
            }
#endif
            UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake
        }
        .onChange(of: keepsScreenAwake) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.teardown()
        }
        .onChange(of: scenePhase) { _, phase in
            // A clock nobody is looking at must not run: the phone locked in
            // a pocket is not a player thinking.
            if phase != .active, model?.isRunning == true { model?.pause() }
        }
        .sheet(isPresented: $showPicker, onDismiss: applyPicked) {
            TimeControlPicker(selection: $pickerSelection, allowsNone: false, allowsAdvanced: true)
                .environment(settings)
        }
        .confirmationDialog("Reset the clock?", isPresented: $confirmReset, titleVisibility: .visible) {
            // A key of its own: "Reset" is the lesson's, which Czech reads
            // as "again" — no answer to "Reset the clock?".
            Button(String(localized: "clock.reset", defaultValue: "Reset",
                          comment: "Confirms setting the chess clock back to its starting time"),
                   role: .destructive) {
                model?.reset(to: settings.standaloneTimeControl)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Whether the screen is held on. A clock waiting for its first tap or
    /// running is one the players are looking at; a paused one, or one whose
    /// flag has fallen, is not, and was kept lit until the clock was closed.
    private var keepsScreenAwake: Bool {
        guard let model else { return true }
        return model.flagged == nil && !model.isPaused
    }

    private func applyPicked() {
        guard let picked = pickerSelection, picked != settings.standaloneTimeControl else { return }
        settings.standaloneTimeControl = picked
        model?.reset(to: picked)
    }

    // MARK: Halves

    private func half(_ color: PieceColor, model: ChessClockModel) -> some View {
        let isActive = model.clock.active == color && model.flagged == nil
        let isFlagged = model.flagged == color
        let schedule = ClockFaceSchedule(
            remaining: model.isRunning && isActive ? model.remaining(for: color) : 0,
            tenthsBelow: 20,
            heldFor: model.clock.delayLeft(at: model.now)
        )
        return TimelineView(schedule) { _ in
            let remaining = model.remaining(for: color)
            let isLow = isActive && remaining <= model.lowTimeThreshold(for: color)
            let background: Color = isFlagged
                ? Color(red: 0.75, green: 0.16, blue: 0.16)
                : (isLow ? Color(red: 0.62, green: 0.18, blue: 0.16)
                   : (isActive ? settings.theme.accent : Color(white: 0.16)))
            let foreground: Color = isActive && !isLow && !isFlagged ? .black.opacity(0.88) : .white

            Button {
                model.tap(color)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(background)
                    VStack(spacing: 10) {
                        Text(verbatim: ClockFormat.text(remaining, tenths: remaining < 20))
                            .font(.system(size: 92, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.4)
                            .lineLimit(1)
                        HStack(spacing: 14) {
                            if isFlagged {
                                Label("Time!", systemImage: "flag.fill")
                            } else {
                                Text("Moves: \(model.clock.moveCount(for: color))",
                                     comment: "Moves made on the chess clock")
                            }
                        }
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .opacity(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        if !model.hasStarted {
                            (color == .black
                                ? Text("Black taps here to start White's clock")
                                : Text("White moves first"))
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .opacity(0.65)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .foregroundStyle(foreground)
                    .padding(20)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.2), value: isActive)
            .accessibilityLabel(color == .white
                ? String(localized: "White's clock", comment: "VoiceOver: one half of the chess clock")
                : String(localized: "Black's clock", comment: "VoiceOver: one half of the chess clock"))
            .accessibilityValue(isFlagged
                ? String(localized: "time is up", comment: "VoiceOver: a fallen flag")
                : ClockFormat.spoken(remaining))
            .accessibilityHint(hint(for: color, isActive: isActive, hasStarted: model.hasStarted))
        }
    }

    /// What a double tap on a half does. Before the first tap the half says
    /// so in words — "Black taps here to start White's clock" — but the half
    /// is one button with a label of its own, those words are not read under
    /// it, and the hint stayed empty until a clock ran: VoiceOver never told
    /// anyone how to start it.
    private func hint(for color: PieceColor, isActive: Bool, hasStarted: Bool) -> String {
        if isActive { return String(localized: "Double tap to end your turn") }
        guard !hasStarted else { return "" }
        return color == .black
            ? String(localized: "Double tap to start White's clock",
                     comment: "VoiceOver: Black's half of the chess clock, before the clock has started")
            : String(localized: "White moves first")
    }

    // MARK: Controls

    private func controlStrip(_ model: ChessClockModel) -> some View {
        HStack(spacing: 18) {
            CircleButton(systemName: "xmark", label: "Close the clock") {
                model.teardown()
                onClose()
            }
            CircleButton(systemName: "arrow.counterclockwise", label: "Reset the clock") {
                if model.hasStarted { confirmReset = true } else { model.reset(to: settings.standaloneTimeControl) }
            }
            Group {
                if model.isRunning {
                    CircleButton(systemName: "pause.fill", label: "Pause") { model.pause() }
                } else if model.isPaused {
                    CircleButton(systemName: "play.fill", label: "Resume") { model.resume() }
                } else {
                    Color.clear.frame(width: Design.minimumTouchTarget, height: Design.minimumTouchTarget)
                }
            }
            CircleButton(systemName: "timer", label: "Time control") {
                if model.isRunning { model.pause() }
                pickerSelection = settings.standaloneTimeControl
                showPicker = true
            }
            // The control on the clock is the button's value, in words: the
            // "5 + 3" beside it is notation for the eye, hidden so it is not
            // read twice, and VoiceOver had no way to learn the control at all.
            .accessibilityValue(spokenControl(model.clock.control))
            Text(verbatim: model.clock.control.label)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    /// The control in words. Its spoken name gives the one starting time,
    /// and a clock giving time odds — which only this clock offers — says
    /// Black's as well, as the "5 / 3 + 2" on screen does.
    private func spokenControl(_ control: TimeControl) -> String {
        guard let black = control.initialBlack, black != control.initial else { return control.spokenName }
        return String(localized: "clock.spokenOdds",
                      defaultValue: "\(control.spokenName), Black's time: \(ClockFormat.spoken(black))",
                      comment: "VoiceOver: a chess clock time control with time odds, e.g. 'Blitz, 5 minutes plus 2 seconds per move, Black's time: 3 minutes'")
    }
}
