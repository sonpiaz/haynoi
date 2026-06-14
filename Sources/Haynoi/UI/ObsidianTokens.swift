import SwiftUI

// MARK: - Obsidian Design Tokens (Light-First — "Obsidian Instrument")
//
// Single source of truth for the Obsidian aesthetic.
// Derived from: /haynoi/redesign/02-DESIGN-SYSTEM.md (locked 2026-06-14)
//
// LIGHT is the PRIMARY theme. Cool neutral, architectural — NOT warm cream.
// The dark obsidian orb popping on a cool-light surface is the signature moment.
//
// Surface ladder  — cool off-white canvas, white cards, hairline-only elevation
// Ink ramp        — deep cool graphite primary → disabled
// Signal Cyan     — SINGLE accent: #38E1C6 (glow/fill) + #119C9A (text/CTA/border)
// Type            — Be Vietnam Pro (UI) + JetBrains Mono (numerals, tabular)
// Orb / HUD       — ALWAYS dark obsidian (#0B0D1A / #161B32), never adapts
// Dark-mode       — near-black ground, near-white ink (secondary; system-adaptive)
//
// API: `Color.obsidianXxx(for: scheme)`, adaptive static colors, 8pt spacing enum.

// MARK: - Hex Initialiser (shared by all token files — defined ONCE here)

extension Color {
    /// Create a Color from a 6-digit hex string (with or without the `#` prefix).
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

// MARK: - Surface Ladder

extension Color {

    // ── Canvas / Ground — cool off-white (light) / near-black (dark) ──
    static let obsidianCanvas     = Color(hex: "F6F7F9")  // light window ground
    static let obsidianDarkCanvas = Color(hex: "0A0B0D")  // dark window ground

    // ── Surface — white card (light) / deep card (dark) ──
    static let obsidianSurface     = Color(hex: "FFFFFF")
    static let obsidianDarkSurface = Color(hex: "0F1012")

    // ── Elevated — white + hairline (light) / raised card (dark) ──
    static let obsidianElevated     = Color(hex: "FFFFFF")
    static let obsidianDarkElevated = Color(hex: "131416")

    // ── Hover — cool blue-grey wash ──
    static let obsidianHover     = Color(hex: "EEF0F3")
    static let obsidianDarkHover = Color(hex: "17181B")

    // ── Hairlines ──
    static let hairlineSolid     = Color(hex: "E3E6EA")   // light
    static let hairlineDarkSolid = Color(hex: "242628")   // dark

    // ── Ink ramp — cool graphite (light) / near-white (dark) ──
    static let inkPrimary      = Color(hex: "16181C")  // deep graphite
    static let inkBody         = Color(hex: "3C4046")  // graphite body
    static let inkMute         = Color(hex: "71757C")  // muted metadata
    static let inkDisabled     = Color(hex: "A6AAB1")  // disabled

    static let inkDarkPrimary   = Color(hex: "F4F5F7")
    static let inkDarkBody      = Color(hex: "C9CBCF")
    static let inkDarkMute      = Color(hex: "8A8D93")
    static let inkDarkDisabled  = Color(hex: "5A5D63")

    // ── Signal Cyan — the SINGLE accent ──
    // On light: #38E1C6 fails WCAG AA on white. Use #119C9A for text/CTA/borders.
    // #38E1C6 is decorative only: orb glow, heatmap fill, etc.
    static let accent          = Color(hex: "38E1C6")   // glow / fill / heatmap peak
    static let accentOnLight   = Color(hex: "119C9A")   // WCAG AA on white — text/CTA/border
    static let accentDeep      = Color(hex: "119C9A")   // gradient endpoint / hover
    static let accentEmber     = Color(hex: "E6F8F5")   // pale cyan tint (idle bg cells, light)
    static let accentDarkEmber = Color(hex: "1C3A38")   // dark teal for idle orb (dark)

    // ── Orb / HUD — ALWAYS dark obsidian, never adapts to app theme ──
    static let orbBodyTop    = Color(hex: "0B0D1A")   // capsule fill gradient top
    static let orbBodyBottom = Color(hex: "161B32")   // capsule fill gradient bottom
    static let orbLightTop   = Color(hex: "38E1C6")   // = accent (glow on dark surface)
    static let orbLightBottom = Color(hex: "119C9A")  // = accentDeep

    // ── Semantic ──
    static let obsidianSuccess   = Color(hex: "2A9668")
    static let obsidianSuccessBg = Color(hex: "E8F7F2")
    static let obsidianWarn      = Color(hex: "B07C25")
    static let obsidianWarnBg    = Color(hex: "FDF5E4")
    static let obsidianError     = Color(hex: "C94232")

    // Dark semantic
    static let obsidianDarkSuccess = Color(hex: "3FB984")
    static let obsidianDarkError   = Color(hex: "E5614C")
    static let obsidianDarkWarn    = Color(hex: "D9A441")

    // MARK: - Adaptive Helpers (scheme-aware)

    /// Window ground (Canvas).
    static func obsidianBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .obsidianDarkCanvas : .obsidianCanvas
    }

    /// Pure white card surface.
    static func obsidianSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .obsidianDarkSurface : .obsidianSurface
    }

    /// Quiet tinted surface — sidebar, titlebar, footers, chips.
    static func obsidianSubtle(for scheme: ColorScheme) -> Color {
        // Light uses a slightly tinted layer; dark uses near-black base
        scheme == .dark ? Color(hex: "0A0B0D") : Color(hex: "F1F2F4")
    }

    /// Row hover wash.
    static func obsidianHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .obsidianDarkHover : .obsidianHover
    }

    /// Selected-row / active wash (cyan-tinted on light, dim on dark).
    static func obsidianActive(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.accent.opacity(0.08)
            : Color.accent.opacity(0.07)
    }

    /// 1px hairline divider.
    static func obsidianDivider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .hairlineDarkSolid : .hairlineSolid
    }

    /// Medium hairline (card edges, key badges).
    static func obsidianHairline(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.14)
    }

    /// The Signal Cyan accent — functional (text/CTA) on any surface.
    static func obsidianAccent(for scheme: ColorScheme) -> Color {
        // On dark surfaces, #38E1C6 has great contrast; on light we need the deep variant
        scheme == .dark ? .accent : .accentOnLight
    }

    /// Accent wash — subtle fill behind accent text/chips.
    static func obsidianAccentWash(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.accent.opacity(0.10) : Color.accent.opacity(0.07)
    }

    /// Primary label — deep graphite / near-white.
    static func obsidianLabel(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .inkDarkPrimary : .inkPrimary
    }

    /// Body label.
    static func obsidianLabel2(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .inkDarkBody : .inkBody
    }

    /// Secondary label — muted metadata.
    static func obsidianLabel3(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .inkDarkMute : .inkMute
    }

    /// Tertiary label.
    static func obsidianLabel4(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .inkDarkDisabled : .inkDisabled
    }

    /// Quinary label (placeholders, faint dots).
    static func obsidianLabel5(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "444750") : Color(hex: "BEC1C7")
    }

    /// Semantic success.
    static func obsidianSuccess(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .obsidianDarkSuccess : .obsidianSuccess
    }

    /// Semantic warn.
    static func obsidianWarn(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .obsidianDarkWarn : .obsidianWarn
    }
}

// MARK: - Backward-compatible `calm*` aliases
//
// All `calm*` call sites throughout the codebase map here so the app builds
// without churning every view file in phase 1. A follow-up phase renames
// call sites to `obsidian*`.

extension Color {
    // Ground / surface
    static let calmGround   = Color.obsidianCanvas
    static let calmSurface  = Color.obsidianSurface
    static let calmSidebar  = Color(hex: "F1F2F4")
    static let calmHover    = Color.obsidianHover
    static let calmActive   = Color(hex: "EEF0F3")   // subtle cyan wash, light mode

    // Ink
    static let calmInk      = Color.inkPrimary
    static let calmInk2     = Color.inkBody
    static let calmInk3     = Color.inkMute
    static let calmInk4     = Color.inkDisabled
    static let calmInk5     = Color(hex: "BEC1C7")

    // Accent — Signal Cyan replacing indigo
    static let calmAccent      = Color.accentOnLight   // deep teal for light-mode text/CTA
    static let calmAccentHover = Color(hex: "0D7C7A")
    static let calmAccentLight = Color(hex: "E6F8F5")  // pale cyan tint

    // Aurora compat — collapse to Signal Cyan (the 3-color sweep is retired)
    static let calmAuroraCyan   = Color.accent         // #38E1C6
    static let calmAuroraViolet = Color.accentDeep     // #119C9A (deep)
    static let calmAuroraPink   = Color.accent         // collapsed — no more 3-stop

    // Semantic
    static let calmSuccess   = Color.obsidianSuccess
    static let calmSuccessBg = Color.obsidianSuccessBg
    static let calmWarn      = Color.obsidianWarn
    static let calmWarnBg    = Color.obsidianWarnBg

    // Hairlines
    static let calmBorder       = Color.hairlineSolid
    static let calmBorderMed    = Color(hex: "D8DBE0")
    static let calmBorderStrong = Color(hex: "BCC0C6")

    // Dark surfaces (backward compat for InsightsView heatmap etc.)
    static let calmDarkGround   = Color.obsidianDarkCanvas
    static let calmDarkSurface  = Color.obsidianDarkSurface
    static let calmDarkSidebar  = Color(hex: "0D0E10")
    static let calmDarkHover    = Color.obsidianDarkHover
    static let calmDarkActive   = Color(hex: "17181B")

    static let calmDarkInk      = Color.inkDarkPrimary
    static let calmDarkInk2     = Color.inkDarkBody
    static let calmDarkInk3     = Color.inkDarkMute
    static let calmDarkInk4     = Color.inkDarkDisabled
    static let calmDarkInk5     = Color(hex: "444750")

    static let calmDarkAccent      = Color.accent
    static let calmDarkAccentLight = Color(hex: "1C3A38")

    // MARK: - calm* adaptive helpers (call-site backward compat)

    static func calmBackground(for scheme: ColorScheme) -> Color {
        obsidianBackground(for: scheme)
    }

    static func calmSurface(for scheme: ColorScheme) -> Color {
        obsidianSurface(for: scheme)
    }

    static func calmSubtle(for scheme: ColorScheme) -> Color {
        obsidianSubtle(for: scheme)
    }

    static func calmHover(for scheme: ColorScheme) -> Color {
        obsidianHover(for: scheme)
    }

    static func calmActive(for scheme: ColorScheme) -> Color {
        obsidianActive(for: scheme)
    }

    static func calmDivider(for scheme: ColorScheme) -> Color {
        obsidianDivider(for: scheme)
    }

    static func calmHairline(for scheme: ColorScheme) -> Color {
        obsidianHairline(for: scheme)
    }

    static func calmAccent(for scheme: ColorScheme) -> Color {
        obsidianAccent(for: scheme)
    }

    static func calmAccentWash(for scheme: ColorScheme) -> Color {
        obsidianAccentWash(for: scheme)
    }

    static func calmLabel(for scheme: ColorScheme) -> Color {
        obsidianLabel(for: scheme)
    }

    static func calmLabel2(for scheme: ColorScheme) -> Color {
        obsidianLabel2(for: scheme)
    }

    static func calmLabel3(for scheme: ColorScheme) -> Color {
        obsidianLabel3(for: scheme)
    }

    static func calmLabel4(for scheme: ColorScheme) -> Color {
        obsidianLabel4(for: scheme)
    }

    static func calmLabel5(for scheme: ColorScheme) -> Color {
        obsidianLabel5(for: scheme)
    }
}

// MARK: - Orb Status (formerly CalmStatus — kept for call-site compat)

/// Drives the visual state of the floating orb, menubar dot, and status row.
/// Idle is quiet; recording/transcribing signal Signal Cyan; semantic states use green/amber.
enum CalmStatus {
    case idle
    case recording
    case transcribing
    case success
    case error

    /// Solid dot color for a small status indicator.
    func dotColor(for scheme: ColorScheme) -> Color {
        switch self {
        case .idle:         return Color.obsidianLabel4(for: scheme)
        case .recording:    return Color.obsidianAccent(for: scheme)
        case .transcribing: return Color.obsidianAccent(for: scheme).opacity(0.7)
        case .success:      return Color.obsidianSuccess(for: scheme)
        case .error:        return Color.obsidianWarn(for: scheme)
        }
    }

    var label: String {
        switch self {
        case .idle:         return "Ready to record"
        case .recording:    return "Recording"
        case .transcribing: return "Transcribing"
        case .success:      return "Inserted"
        case .error:        return "Something went wrong"
        }
    }

    var shortLabel: String {
        switch self {
        case .idle:         return "ready"
        case .recording:    return "recording"
        case .transcribing: return "thinking"
        case .success:      return "done"
        case .error:        return "error"
        }
    }
}

// MARK: - Gradients

extension LinearGradient {
    /// Signal Cyan sweep for the credit bar and orb trail (replaces aurora 3-stop).
    static let calmAurora = LinearGradient(
        colors: [.accent, .accentDeep],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Two-stop cyan sweep for compact bars.
    static let calmAuroraBar = LinearGradient(
        colors: [.accent, .accentDeep],
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension RadialGradient {
    /// Signal Cyan orb core — glow dot in icon / orb moments.
    static let calmAuroraOrb = RadialGradient(
        colors: [.accent, .accentDeep],
        center: .topLeading,
        startRadius: 0,
        endRadius: 14
    )
}

// MARK: - Typography

extension Font {
    // ── Be Vietnam Pro — UI face (with SF Pro fallback) ──
    // "BeVietnamPro-*" postscript names; SF Pro Text fallback if not bundled yet.
    static let obsidianDisplay  = Font.custom("BeVietnamPro-SemiBold", size: 30)
    static let obsidianTitle    = Font.custom("BeVietnamPro-SemiBold", size: 18)
    static let obsidianHeading  = Font.custom("BeVietnamPro-Medium",   size: 16)
    static let obsidianBody     = Font.custom("BeVietnamPro-Regular",  size: 14)
    static let obsidianCaption  = Font.custom("BeVietnamPro-Medium",   size: 11)
    static let obsidianLabel    = Font.custom("BeVietnamPro-SemiBold", size: 10)

    // ── JetBrains Mono — numerals and metrics ONLY ──
    // Tabular figures. Fallback: SF Mono.
    static let obsidianMonoLG = Font.custom("JetBrainsMono-Regular", size: 24).monospacedDigit()
    static let obsidianMonoMD = Font.custom("JetBrainsMono-Regular", size: 14).monospacedDigit()
    static let obsidianMonoSM = Font.custom("JetBrainsMono-Regular", size: 11).monospacedDigit()

    // ── calm* compat aliases — call sites don't need to change yet ──
    static var calmHeading:        Font { Font.system(size: 22, weight: .semibold) }
    static var calmTitle:          Font { Font.system(size: 19, weight: .semibold) }
    static var calmStatValue:      Font { Font.system(size: 24, weight: .semibold) }
    static var calmBalance:        Font { Font.system(size: 28, weight: .semibold) }
    static var calmPopoverBalance: Font { Font.system(size: 16, weight: .semibold) }
    static var calmPopoverName:    Font { Font.system(size: 15, weight: .semibold) }
    static var calmSectionLabel:   Font { Font.system(size: 10, weight: .bold) }
}

// MARK: - Spacing (8pt rhythm)
//
// `C` is kept as the short-form enum used by all existing call sites.
// `ObsidianSpacing` is the spec name for new code.

enum C {
    static let s1: CGFloat =  4
    static let s2: CGFloat =  8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 22
    static let s6: CGFloat = 28
    static let s7: CGFloat = 40

    // Corner radii
    static let rXS: CGFloat =  4
    static let rSM: CGFloat =  6
    static let rMD: CGFloat = 10
    static let rLG: CGFloat = 14
    static let rXL: CGFloat = 18
}

// MARK: - Radius Scale

enum ObsidianRadius: CGFloat {
    case xs   =   4
    case sm   =   6
    case md   =  10
    case lg   =  14
    case xl   =  18
    case pill = 999
}

// MARK: - Motion

extension Animation {
    static let obsidianSnap    = Animation.spring(response: 0.18, dampingFraction: 0.86, blendDuration: 0)
    static let obsidianSettle  = Animation.spring(response: 0.32, dampingFraction: 0.62, blendDuration: 0)
    static let obsidianLift    = Animation.spring(response: 0.38, dampingFraction: 0.80, blendDuration: 0)
    static let obsidianChrome  = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.22)
    static let obsidianFade    = Animation.easeOut(duration: 0.16)
    static let obsidianMilestone = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.40)
    static let obsidianBreathAttack  = Animation.easeOut(duration: 0.06)
    static let obsidianBreathRelease = Animation.easeOut(duration: 0.80)
}

// MARK: - Hairline View (replaces CalmHairline)

/// A single 1px quiet hairline. Used as a structural divider.
struct CalmHairline: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle()
            .fill(Color.obsidianDivider(for: scheme))
            .frame(height: 1)
    }
}

// MARK: - App Theme (System / Light / Dark)
//
// Default is LIGHT — the Obsidian design is light-first.

enum AppTheme: String, CaseIterable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "light") ?? .light
    }
}

private struct HaynoiThemeModifier: ViewModifier {
    @AppStorage("appTheme") private var appThemeRaw = "light"

    func body(content: Content) -> some View {
        content.preferredColorScheme(
            (AppTheme(rawValue: appThemeRaw) ?? .light).colorScheme
        )
    }
}

extension View {
    /// Applies the user's theme choice (System / Light / Dark) at a UI root.
    /// Light is the default — the Obsidian Instrument opens in cool-neutral white.
    func haynoiTheme() -> some View {
        modifier(HaynoiThemeModifier())
    }

    // MARK: - View modifier helpers

    /// Obsidian card style: white surface + hairline border, md corner radius.
    func obsidianCard() -> some View {
        self
            .background(Color.obsidianSurface)
            .overlay(
                RoundedRectangle(cornerRadius: ObsidianRadius.md.rawValue)
                    .stroke(Color.hairlineSolid, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: ObsidianRadius.md.rawValue))
    }
}

// MARK: - Status Dot (shared menubar / popover / orb)

/// Small circle that renders Signal Cyan for live states, quiet gray for idle.
struct CalmStatusDot: View {
    let status: CalmStatus
    var size: CGFloat = 6
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(status.dotColor(for: scheme))
            .frame(width: size, height: size)
            .shadow(
                color: glowColor.opacity(status == .idle ? 0 : 0.5),
                radius: status == .idle ? 0 : 3
            )
    }

    private var glowColor: Color {
        switch status {
        case .recording, .transcribing: return Color.obsidianAccent(for: scheme)
        case .success:                  return Color.obsidianSuccess(for: scheme)
        case .error:                    return Color.obsidianWarn(for: scheme)
        case .idle:                     return .clear
        }
    }
}
