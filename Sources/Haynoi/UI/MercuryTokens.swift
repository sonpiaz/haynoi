import SwiftUI

// MARK: - Mercury Design Tokens
//
// Single source of truth for the Mercury "private ledger" aesthetic.
// Derived from /tmp/haynoi-ui-mock-mercury/style.css
//
// Paper palette  — warm parchment ground, ink text
// Aurora spectrum — jewel dosage only (hairline + accent moments)
// Serif moments  — .fontDesign(.serif) = New York / Georgia fallback
// Dark-mode      — deep warm charcoal paper, soft ivory ink (never pure #000/#FFF)

// MARK: - Color Tokens

extension Color {

    // Paper (light-mode warm parchment)
    static let mercuryPaper      = Color(hex: "#FAFAF7")   // main ground
    static let mercuryPaperWarm  = Color(hex: "#F4F3EE")   // titlebar, stats strip, context panel
    static let mercuryPaperMid   = Color(hex: "#EAE8E0")   // dividers, tag chips, key badges
    static let mercuryPaperDeep  = Color(hex: "#D8D5C9")   // toggle track off

    // Ink
    static let mercuryInk        = Color(hex: "#1C1917")   // primary text
    static let mercuryInk2       = Color(hex: "#3D3830")   // body text
    static let mercuryInk3       = Color(hex: "#6B6456")   // secondary labels, section titles
    static let mercuryInk4       = Color(hex: "#9C9487")   // tertiary, word counts
    static let mercuryInk5       = Color(hex: "#C2BBAD")   // placeholder, timestamps, dots

    // Aurora spectrum (jewel dosage only)
    static let auroraCyan        = Color(hex: "#3ADCF5")
    static let auroraBlue        = Color(hex: "#6B7FFF")
    static let auroraViolet      = Color(hex: "#9B5CF6")
    static let auroraPink        = Color(hex: "#E040B8")

    // Warm accent (golden amber — for balance bar, entry highlight)
    static let mercuryAccent     = Color(hex: "#C97D3A")
    static let mercuryAccentLight = Color(hex: "#F5E6D3")

    // Semantic states
    static let mercuryGreen      = Color(hex: "#2D9B6F")
    static let mercuryOrange     = Color(hex: "#D4700A")

    // Dark-mode paper (warm charcoal, not pure black)
    static let mercuryDarkPaper      = Color(hex: "#1A1815")
    static let mercuryDarkPaperWarm  = Color(hex: "#211F1C")
    static let mercuryDarkPaperMid   = Color(hex: "#2C2A25")
    static let mercuryDarkPaperDeep  = Color(hex: "#3A3730")

    // Dark-mode ink (ivory, not pure white)
    static let mercuryDarkInk        = Color(hex: "#F0EDE6")
    static let mercuryDarkInk2       = Color(hex: "#D4CEC4")
    static let mercuryDarkInk3       = Color(hex: "#A09890")
    static let mercuryDarkInk4       = Color(hex: "#706A62")
    static let mercuryDarkInk5       = Color(hex: "#4A4640")

    // MARK: - Adaptive helpers

    /// Window ground
    static func mercuryBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkPaper : .mercuryPaper
    }

    /// Titlebar / warm surface
    static func mercuryWarm(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkPaperWarm : .mercuryPaperWarm
    }

    /// Mid surface (chips, keys)
    static func mercuryMid(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkPaperMid : .mercuryPaperMid
    }

    /// Divider line
    static func mercuryDivider(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.mercuryDarkInk.opacity(0.06)   // ivory-based, no pure white
            : Color(hex: "#1C1917").opacity(0.07)
    }

    /// Primary label
    static func mercuryLabel(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkInk : .mercuryInk
    }

    /// Secondary label
    static func mercuryLabel2(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkInk2 : .mercuryInk2
    }

    /// Tertiary label
    static func mercuryLabel3(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkInk3 : .mercuryInk3
    }

    /// Quaternary label
    static func mercuryLabel4(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkInk4 : .mercuryInk4
    }

    /// Quinary label (placeholder, timestamps)
    static func mercuryLabel5(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .mercuryDarkInk5 : .mercuryInk5
    }
}

// MARK: - Hex initialiser

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let scanner = Scanner(string: h)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >>  8) & 0xFF) / 255.0
        let b = Double( rgb        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Aurora hairline gradient

extension LinearGradient {
    /// The Mercury signature: 2pt hairline at window top.
    static let auroraHairline = LinearGradient(
        stops: [
            .init(color: Color.auroraCyan.opacity(0),      location: 0),
            .init(color: Color.auroraBlue.opacity(0.7),    location: 0.30),
            .init(color: Color.auroraViolet.opacity(0.9),  location: 0.60),
            .init(color: Color.auroraPink.opacity(0.5),    location: 0.80),
            .init(color: Color.auroraCyan.opacity(0),      location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Aurora gradient for stat text (words total) and balance bar fill.
    static let auroraWords = LinearGradient(
        colors: [.auroraBlue, .auroraViolet],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Typography helpers

extension Font {
    /// 24pt serif italic — "Chào buổi sáng, Son."
    static let mercuryGreeting = Font.system(size: 24, design: .serif).italic()

    /// 13pt serif regular — stat sentence beneath greeting
    static let mercuryGreetingStat = Font.system(size: 13, design: .serif)

    /// 20pt serif — stat values in the strip
    static var mercuryStatValue: Font { Font.system(size: 20, weight: .semibold, design: .serif) }

    /// 11pt small-caps serif — group date headers
    static var mercuryGroupLabel: Font { Font.system(size: 11, weight: .semibold, design: .serif).smallCaps() }

    /// 28pt serif — credit balance dollar figure
    static var mercuryBalance: Font { Font.system(size: 28, weight: .medium, design: .serif) }

    /// 17pt serif — popover balance figure
    static var mercuryPopoverBalance: Font { Font.system(size: 17, weight: .medium, design: .serif) }

    /// 15pt serif semibold — popover app name
    static var mercuryPopoverName: Font { Font.system(size: 15, weight: .semibold, design: .serif) }

    /// 13pt serif small-caps — settings section titles
    static var mercurySectionTitle: Font { Font.system(size: 13, weight: .semibold, design: .serif).smallCaps() }
}

// MARK: - Spacing rhythm (8pt base matching CSS)

enum R {
    static let r1: CGFloat =  4
    static let r2: CGFloat =  8
    static let r3: CGFloat = 12
    static let r4: CGFloat = 16
    static let r5: CGFloat = 24
    static let r6: CGFloat = 32
    static let r7: CGFloat = 48
}

// MARK: - Aurora hairline view

struct AuroraHairline: View {
    var body: some View {
        LinearGradient.auroraHairline
            .frame(height: 2)
    }
}
