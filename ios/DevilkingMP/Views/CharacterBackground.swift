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

/// A small reserved area in each main page's scroll content keeps the face
/// visible. It scrolls away normally and never overlaps controls or posters.
struct DKCharacterHeader: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dkPageCharacter) private var character
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if preferences.characterBackgroundsEnabled, !reduceTransparency, let character {
            GeometryReader { geometry in
                let artworkWidth = min(224, max(196, geometry.size.width * 0.58))
                ZStack(alignment: .topTrailing) {
                    DKTheme.background
                    Image(character.assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: artworkWidth, height: artworkWidth * 1672 / 941)
                        .opacity(colorScheme == .dark ? 0.90 : 1)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.42),
                                .init(color: .black, location: 1)
                            ], startPoint: .leading, endPoint: .trailing)
                        }
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.88),
                        .init(color: DKTheme.background, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .frame(height: 128)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("页面角色装饰")
            .accessibilityIdentifier("character.header." + character.rawValue)
            .accessibilityHidden(!uiFixtureActive)
        }
    }

    private var uiFixtureActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-fixture")
        #else
        return false
        #endif
    }
}
