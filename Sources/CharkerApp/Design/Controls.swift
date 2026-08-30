import CharkerCore
import SwiftUI

/// A segment in ``CharkerSegmentedControl``. Keeping the title beside its value
/// lets the control own localization, selection semantics, and equal sizing.
struct CharkerSegment<Value: Hashable>: Identifiable {
    let title: String
    let value: Value

    var id: Value { value }

    init(_ title: String, value: Value) {
        self.title = title
        self.value = value
    }
}

/// Charker's compact alternative to the stock macOS segmented picker.
///
/// The outer well belongs to the same slate system as cards and sliders. A
/// single capsule marks the choice, so the control reads as one setting rather
/// than three unrelated buttons. The individual buttons retain native keyboard
/// focus and accessibility traits.
///
/// Selection deliberately has no cross-segment geometry animation. This binding
/// can synchronously change `NSApp.appearance`; carrying a matched-geometry
/// transaction across that AppKit layout invalidation crashes on a pointer click.
struct CharkerSegmentedControl<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let segments: [CharkerSegment<Value>]

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(segments) { segment in
                let selected = selection == segment.value
                Button {
                    selection = segment.value
                } label: {
                    Text(L10n.text(segment.title))
                        .font(Typo.label)
                        .foregroundStyle(selected ? Palette.accentText : Palette.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, Space.m)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(CharkerSegmentButtonStyle(
                    selected: selected
                ))
                .accessibilityLabel(Text(L10n.text(segment.title)))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous).fill(Palette.well)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.text(label)))
        .onMoveCommand(perform: moveSelection)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard let current = segments.firstIndex(where: { $0.value == selection }) else { return }

        let next: Int
        switch direction {
        case .left, .up:
            next = max(segments.startIndex, current - 1)
        case .right, .down:
            next = min(segments.index(before: segments.endIndex), current + 1)
        default:
            return
        }

        guard next != current else { return }
        selection = segments[next].value
    }
}

private struct CharkerSegmentButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        CharkerSegmentButtonBody(
            configuration: configuration,
            selected: selected
        )
    }
}

private struct CharkerSegmentButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background {
                if selected {
                    Capsule(style: .continuous)
                        .fill(Palette.accentWash)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Palette.accent.opacity(0.30), lineWidth: Stroke.hairline)
                        }
                } else if hovering {
                    Capsule(style: .continuous)
                        .fill(Palette.surfaceRaised.opacity(0.72))
                }
            }
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .onHover { hovering = isEnabled && $0 }
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

enum CharkerActionEmphasis {
    case primary
    case secondary
    case quiet
    case destructive
}

/// A four-level action hierarchy for the app's designed surfaces.
///
/// Unlike `.bordered`, these buttons share Charker's typography and the same
/// flat capsule geometry as switches and segmented controls. The hierarchy is
/// intentionally quiet: only a real primary action receives the accent wash.
struct CharkerActionButtonStyle: ButtonStyle {
    var emphasis: CharkerActionEmphasis = .secondary

    func makeBody(configuration: Configuration) -> some View {
        CharkerActionButtonBody(configuration: configuration, emphasis: emphasis)
    }
}

private struct CharkerActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let emphasis: CharkerActionEmphasis

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(Typo.label)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Space.m)
            .frame(minHeight: 28)
            .background {
                Capsule(style: .continuous).fill(background)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(border, lineWidth: Stroke.hairline)
            }
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.80 : 1) : 0.42)
            .onHover { hovering = isEnabled && $0 }
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch emphasis {
        case .primary, .quiet:
            return Palette.accentText
        case .secondary:
            return Palette.textPrimary
        case .destructive:
            return Palette.dangerText
        }
    }

    private var background: Color {
        switch emphasis {
        case .primary:
            return Palette.accentWash
        case .secondary:
            return hovering ? Palette.accentWash.opacity(0.52) : Palette.surfaceRaised
        case .quiet:
            return hovering ? Palette.surfaceRaised : .clear
        case .destructive:
            return hovering ? Palette.danger.opacity(0.12) : Palette.danger.opacity(0.07)
        }
    }

    private var border: Color {
        switch emphasis {
        case .primary:
            return Palette.accent.opacity(hovering ? 0.55 : 0.36)
        case .secondary:
            return hovering ? Palette.accent.opacity(0.28) : Palette.stroke
        case .quiet:
            return hovering ? Palette.stroke : .clear
        case .destructive:
            return Palette.danger.opacity(hovering ? 0.48 : 0.30)
        }
    }
}
