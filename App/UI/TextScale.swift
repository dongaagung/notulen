import SwiftUI

/// User-adjustable text size for notes, transcript and minutes.
/// macOS text styles have fixed point sizes, so views ask for
/// `Font.scaled(_:_:)` with the scale from the environment instead.
enum TextScale {
    static let standard = 1.25
    static let steps: [Double] = [0.85, 1, 1.15, 1.25, 1.4, 1.6, 1.8, 2, 2.4]

    static func bigger(than scale: Double) -> Double {
        steps.first { $0 > scale + 0.001 } ?? steps.last!
    }

    static func smaller(than scale: Double) -> Double {
        steps.last { $0 < scale - 0.001 } ?? steps.first!
    }
}

// `@Entry` would be shorter, but it's a macro whose plugin needs Xcode.
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension Font {
    /// A macOS text style's point size, multiplied by `scale`.
    static func scaled(_ style: Font.TextStyle, _ scale: Double, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat = switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        default: 13  // .body, .headline
        }
        return .system(size: size * scale, weight: style == .headline ? .semibold : weight)
    }
}

/// A− / 125% / A+ buttons bound to the text size.
struct TextSizeControl: View {
    @Binding var scale: Double

    var body: some View {
        HStack(spacing: 2) {
            Button {
                scale = TextScale.smaller(than: scale)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .help("Perkecil teks (⌘−)")
            Text(scale, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38)
            Button {
                scale = TextScale.bigger(than: scale)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .help("Perbesar teks (⌘=)")
        }
        .buttonStyle(.borderless)
    }
}
