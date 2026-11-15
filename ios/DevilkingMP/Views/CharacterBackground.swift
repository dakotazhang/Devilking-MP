import SwiftUI

enum DKPageCharacter: String, CaseIterable {
    case rem, emilia, ram, beatrice, echidna

    var assetName: String {
        switch self {
        case .rem: return "PageRem"
        case .emilia: return "PageEmilia"
        case .ram: return "PageRam"
        case .beatrice: return "PageBeatrice"
        case .echidna: return "PageEchidna"
        }
    }

    /// These two pages contain posters. Their decoration fades out before the
    /// main poster grid and is never rendered as a foreground overlay.
    var protectsPosters: Bool { self == .ram || self == .beatrice }
}

private struct DKPageCharacterKey: EnvironmentKey {
    static let defaultValue: DKPageCharacter? = nil
}

extension EnvironmentValues {
    var dkPageCharacter: DKPageCharacter? {
        get { self[DKPageCharacterKey.self] }
        set { self[DKPageCharacterKey.self] = newValue }
    }
}

/// A lightweight, static background. Artwork is local and decorative; it has
/// no network requests, animation, touch target, or accessibility announcement.
struct DKCharacterBackdrop: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let character: DKPageCharacter?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                DKTheme.background
                if preferences.characterBackgroundsEnabled, !reduceTransparency, let character {
                    Image(character.assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
                        .opacity(colorScheme == .dark ? 0.22 : 0.34)
                        .mask {
                            LinearGradient(stops: character.protectsPosters ? [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.72), location: 0.20),
                                .init(color: .clear, location: 0.58)
                            ] : [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.82), location: 0.36),
                                .init(color: .clear, location: 0.95)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
