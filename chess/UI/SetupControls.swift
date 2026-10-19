//
//  SetupControls.swift
//  chess
//
//  The pieces the setup screens are built from: section titles, the card a
//  choice sits on, the starting-position picker and the time-control sheet.
//

import SwiftUI

// MARK: - Small pieces

struct SetupSectionTitle: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(.tertiaryText)
            .kerning(1.2)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The card a setup choice sits on, lit when it is the one chosen.
    func setupCard(selected: Bool, cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.12 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            selected ? Design.gold.opacity(0.5) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }
}

/// A short labelled choice in a row of them.
struct OptionChip<Icon: View>: View {
    let title: String
    let isSelected: Bool
    var accessibilityName: String?
    @ViewBuilder var icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button {
            action()
            Haptics.pieceSelected()
        } label: {
            VStack(spacing: 4) {
                icon()
                Text(title)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .frame(minHeight: Design.minimumTouchTarget)
            .setupCard(selected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension OptionChip where Icon == EmptyView {
    init(title: String, isSelected: Bool, accessibilityName: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.accessibilityName = accessibilityName
        self.icon = { EmptyView() }
        self.action = action
    }
}

// MARK: - Starting position

/// The starting position a setup screen is about to use.
struct StartChoice: Equatable, Codable {
    enum Kind: String, CaseIterable, Codable {
        case standard, chess960, odds

        var title: String {
            switch self {
            case .standard: return String(localized: "Standard", comment: "Starting position choice")
            case .chess960: return String(localized: "Chess960", comment: "Starting position choice")
            case .odds: return String(localized: "Odds", comment: "Starting position choice: one side plays without a piece")
            }
        }

        var systemImage: String {
            switch self {
            case .standard: return "square.grid.3x3.fill"
            case .chess960: return "shuffle"
            case .odds: return "gift.fill"
            }
        }
    }

    var kind: Kind = .standard
    var handicap: Handicap = .knight
    /// Who plays without the piece, in a two-player game.
    var giver: PieceColor = .white

    /// The position to start from. Against the computer it is always the
    /// computer that gives the odds — that is what odds are for.
    func position(computerColor: PieceColor?) -> StartPosition {
        switch kind {
        case .standard: return .standard
        case .chess960: return .chess960(number: Chess960.randomNumber())
        case .odds: return .handicap(handicap, giver: computerColor ?? giver)
        }
    }

    init() {}

    /// Field by field, each falling back to its default: a choice saved by a
    /// later version, or one no longer offered, costs only itself.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .standard
        handicap = (try? container.decodeIfPresent(Handicap.self, forKey: .handicap)) ?? .knight
        giver = (try? container.decodeIfPresent(PieceColor.self, forKey: .giver)) ?? .white
    }
}

/// The new-game setup the menu was last left with, besides the clock, which
/// `AppSettings` keeps on its own. The menu leaves the screen for every game,
/// and its choices went with it: the clock came back as it was left, and the
/// level, the side, the starting position and the rules beside it were back
/// at Medium, White, standard chess after every single game.
struct MenuSetup: Equatable, Codable {
    var difficulty: AIDifficulty = .medium
    /// "white", "random" or "black".
    var side = "white"
    var aiStart = StartChoice()
    var twoPlayerStart = StartChoice()
    var aiVariant: ChessVariant = .standard
    var twoPlayerVariant: ChessVariant = .standard

    init() {}

    /// Lenient for the reason `StartChoice` is.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MenuSetup()
        func field<Value: Decodable>(_ key: CodingKeys, _ value: Value) -> Value {
            (try? container.decodeIfPresent(Value.self, forKey: key)) ?? value
        }
        difficulty = field(.difficulty, fallback.difficulty)
        side = field(.side, fallback.side)
        aiStart = field(.aiStart, fallback.aiStart)
        twoPlayerStart = field(.twoPlayerStart, fallback.twoPlayerStart)
        aiVariant = field(.aiVariant, fallback.aiVariant)
        twoPlayerVariant = field(.twoPlayerVariant, fallback.twoPlayerVariant)
    }
}

struct StartPositionPicker: View {
    @Binding var choice: StartChoice
    let oddsGiverIsComputer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupSectionTitle("STARTING POSITION")
            HStack(spacing: 8) {
                ForEach(StartChoice.Kind.allCases, id: \.self) { kind in
                    OptionChip(title: kind.title, isSelected: choice.kind == kind) {
                        Image(systemName: kind.systemImage)
                            .scaledFont(15, relativeTo: .subheadline, weight: .semibold)
                            .foregroundStyle(choice.kind == kind ? Design.gold : .white.opacity(0.6))
                    } action: {
                        withAnimation(Motion.meaningful(.spring(duration: 0.3))) { choice.kind = kind }
                    }
                }
            }

            switch choice.kind {
            case .standard:
                EmptyView()
            case .chess960:
                caption("The pieces behind the pawns are shuffled — the same way for both sides — so opening theory is no help. Castling still works.")
            case .odds:
                caption(oddsGiverIsComputer
                        ? "The computer plays without:"
                        : "One side plays without a piece:")
                HStack(spacing: 8) {
                    ForEach(Handicap.allCases) { handicap in
                        OptionChip(
                            // The spoken name is a word for the middle of a
                            // sentence; as a chip title beside capitalised
                            // ones it read "knight" next to "White".
                            title: handicap.piece.spokenName.localizedCapitalized,
                            isSelected: choice.handicap == handicap,
                            accessibilityName: handicap.displayName
                        ) {
                            PieceView(piece: Piece(.white, handicap.piece), shadow: false)
                                .scaledFrame(26, relativeTo: .subheadline)
                        } action: {
                            choice.handicap = handicap
                        }
                    }
                }
                if !oddsGiverIsComputer {
                    HStack(spacing: 8) {
                        ForEach([PieceColor.white, .black], id: \.self) { color in
                            OptionChip(
                                title: String(localized: "\(color.spokenName) gives odds",
                                              comment: "Which side plays without the piece"),
                                isSelected: choice.giver == color
                            ) {
                                choice.giver = color
                            }
                        }
                    }
                }
            }
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

// MARK: - Variant

struct VariantPicker: View {
    @Binding var variant: ChessVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupSectionTitle("RULES")
            HStack(spacing: 8) {
                ForEach(ChessVariant.allCases, id: \.self) { option in
                    OptionChip(title: option.shortName, isSelected: variant == option,
                               accessibilityName: option.displayName) {
                        Image(systemName: option.systemImage)
                            .scaledFont(15, relativeTo: .subheadline, weight: .semibold)
                            .foregroundStyle(variant == option ? Design.gold : .white.opacity(0.6))
                    } action: {
                        withAnimation(Motion.meaningful(.spring(duration: 0.3))) { variant = option }
                    }
                }
            }
            Text(variant.rule)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Time control picker

/// Choosing a clock: the presets by category, or one made to measure.
struct TimeControlPicker: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: TimeControl?
    /// Whether "no clock" is on offer — it is for games, not for the clock.
    var allowsNone = false
    /// Delay and Bronstein, and different times per side: the stand-alone
    /// clock offers them, a game in the app keeps to the plain increment.
    var allowsAdvanced = false

    @State private var customMinutes: Double = 10
    @State private var customIncrement: Double = 5
    @State private var customKind: TimeControl.Bonus = .increment
    @State private var oddsEnabled = false
    @State private var customBlackMinutes: Double = 5

    /// The steps a stepper walks through: fine at the short end, coarse at
    /// the long one, the way time controls are actually chosen.
    private static let minuteSteps: [Double] = [
        0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 7, 8, 10, 12, 15, 20, 25, 30,
        40, 45, 50, 60, 75, 90, 105, 120, 150, 180,
    ]
    private static let incrementSteps: [Double] = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 45, 60]

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if allowsNone {
                            noClockRow
                        }
                        ForEach(TimeControl.Category.allCases, id: \.self) { category in
                            presetSection(category)
                        }
                        customSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Time Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .tint(Design.gold)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadCustom)
    }

    private func loadCustom() {
        guard let selection else { return }
        customMinutes = Self.nearest(selection.initial / 60, in: Self.minuteSteps)
        customIncrement = Self.nearest(selection.bonus, in: Self.incrementSteps)
        customKind = selection.bonusKind
        if let black = selection.initialBlack {
            oddsEnabled = true
            customBlackMinutes = Self.nearest(black / 60, in: Self.minuteSteps)
        }
    }

    private static func nearest(_ value: Double, in steps: [Double]) -> Double {
        steps.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    private var noClockRow: some View {
        Button {
            selection = nil
            Haptics.pieceSelected()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "infinity")
                    .scaledFont(16, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(Design.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("No clock")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Undo and hints stay available.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondaryText)
                }
                Spacer()
                if selection == nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.gold)
                }
            }
            .padding(14)
            .setupCard(selected: selection == nil)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == nil ? .isSelected : [])
    }

    private func presetSection(_ category: TimeControl.Category) -> some View {
        let presets = TimeControl.presets.filter { $0.category == category }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: category.systemImage)
                    .foregroundStyle(Design.gold)
                    .accessibilityHidden(true)
                Text(category.displayName.uppercased())
                    .kerning(1.2)
            }
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(presets) { preset in
                    let isSelected = selection == preset
                    Button {
                        selection = preset
                        Haptics.pieceSelected()
                        dismiss()
                    } label: {
                        Text(verbatim: preset.label)
                            .scaledFont(17, relativeTo: .headline, weight: .bold, design: .rounded)
                            .foregroundStyle(isSelected ? Design.gold : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .setupCard(selected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.spokenName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var customControl: TimeControl {
        TimeControl(
            initial: customMinutes * 60,
            bonus: customIncrement,
            bonusKind: allowsAdvanced ? customKind : .increment,
            initialBlack: allowsAdvanced && oddsEnabled ? customBlackMinutes * 60 : nil
        )
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupSectionTitle("CUSTOM")
            VStack(spacing: 12) {
                stepRow(
                    title: oddsEnabled && allowsAdvanced
                        ? String(localized: "White's minutes", comment: "Custom time: White's starting time")
                        : String(localized: "Minutes per player", comment: "Custom time: starting time"),
                    value: TimeControl.minutesText(customMinutes * 60),
                    spoken: ClockFormat.spoken(customMinutes * 60),
                    values: Self.minuteSteps, current: $customMinutes
                )
                if allowsAdvanced, oddsEnabled {
                    stepRow(
                        title: String(localized: "Black's minutes", comment: "Custom time: Black's starting time"),
                        value: TimeControl.minutesText(customBlackMinutes * 60),
                        spoken: ClockFormat.spoken(customBlackMinutes * 60),
                        values: Self.minuteSteps, current: $customBlackMinutes
                    )
                }
                stepRow(
                    title: customKind == .increment || !allowsAdvanced
                        ? String(localized: "Increment, seconds", comment: "Custom time: seconds added per move")
                        : String(localized: "Delay, seconds", comment: "Custom time: seconds of delay per move"),
                    value: "\(Int(customIncrement))",
                    spoken: ClockFormat.spoken(customIncrement),
                    values: Self.incrementSteps, current: $customIncrement
                )
                if allowsAdvanced {
                    Picker("Bonus", selection: $customKind) {
                        ForEach(TimeControl.Bonus.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(bonusExplanation)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $oddsEnabled.animation()) {
                        Text("Different time for each player")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .tint(Design.gold)
                }
                Button {
                    selection = customControl
                    Haptics.pieceSelected()
                    dismiss()
                } label: {
                    Text("Use \(customControl.label)", comment: "Button that picks the custom time control")
                        .font(.system(.body, design: .rounded, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Design.gold))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .setupCard(selected: false, cornerRadius: 16)
        }
    }

    private var bonusExplanation: String {
        switch customKind {
        case .increment:
            return String(localized: "The seconds are added after every move, so quick moves bank time.")
        case .delay:
            return String(localized: "The clock waits that many seconds before it starts to run. Nothing is ever added.")
        case .bronstein:
            return String(localized: "The time a move took is given back afterwards, up to that many seconds.")
        }
    }

    private func stepRow(
        title: String, value: String, spoken: String,
        values: [Double], current: Binding<Double>
    ) -> some View {
        let index = values.firstIndex(of: current.wrappedValue) ?? 0
        return HStack {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button {
                if index > 0 { current.wrappedValue = values[index - 1] }
            } label: {
                Image(systemName: "minus")
                    .frame(width: Design.minimumTouchTarget, height: Design.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .accessibilityHidden(true)
            Text(verbatim: value)
                .scaledFont(17, relativeTo: .headline, weight: .bold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 44)
            Button {
                if index < values.count - 1 { current.wrappedValue = values[index + 1] }
            } label: {
                Image(systemName: "plus")
                    .frame(width: Design.minimumTouchTarget, height: Design.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(index == values.count - 1)
            .accessibilityHidden(true)
        }
        .foregroundStyle(Design.gold)
        // One adjustable element for VoiceOver rather than two unlabelled
        // buttons either side of a number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index < values.count - 1 { current.wrappedValue = values[index + 1] }
            case .decrement: if index > 0 { current.wrappedValue = values[index - 1] }
            @unknown default: break
            }
        }
    }
}
