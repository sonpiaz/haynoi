import SwiftUI

// MARK: - Calm Design Tokens (Lens C — Granola Calm)
//
// Single source of truth for the "Calm" white-gray aesthetic that replaces
// Mercury's warm-parchment serif look on the daily surfaces.
// Derived from the founder-approved board: /tmp/haynoi-ui2-calm/style.css
//
// Ground       — cool off-white (#FCFCFD), pure-white surfaces, hairline dividers
// Ink          — near-black primary (#1A1D21), cool gray secondary/tertiary
// Accent       — a SINGLE restrained indigo (#4F5DDB) for selection + primary CTA
// Aurora       — cyan→violet→pink, the ONLY saturated color, used sparingly:
//                app icon, recording orb, menubar status dot, credit-balance bar
// Type         — system .default (no serif). DM Sans is the brand face on the web;
//                here we use the system UI font so the app never ships an unbundled
//                font fallback that breaks the rhythm.
// Dark-mode    — cool charcoal ground, soft light ink (never pure #000 / #FFF).
//
// API mirrors MercuryTokens' surface (Color.calmXxx(for:), Font.calmXxx, the
// `C` spacing enum) so call sites migrate Mercury → Calm with minimal churn.

// MARK: - Color Tokens

extension Color {

    // ── Ground (light mode — cool off-white) ──
    static let calmGround   = Color(hex: "#FCFCFD")   // window ground (--bg-app)
    static let calmSurface  = Color(hex: "#FFFFFF")   // cards, rows, popover body (--bg-card)
    static let calmSidebar  = Color(hex: "#F4F5F7")   // sidebar, titlebar tint, footers (--bg-sidebar)
    static let calmHover    = Color(hex: "#F0F1F4")   // row hover (--bg-hover)
    static let calmActive   = Color(hex: "#EEF0FD")   // selected-row wash (--bg-active)

    // ── Ink ──
    static let calmInk      = Color(hex: "#1A1D21")   // primary text (--text-primary)
    static let calmInk2     = Color(hex: "#3A3E45")   // body text (between primary and secondary)
    static let calmInk3     = Color(hex: "#71757C")   // secondary labels (--text-secondary)
    static let calmInk4     = Color(hex: "#A0A4AB")   // tertiary, timestamps (--text-tertiary)
    static let calmInk5     = Color(hex: "#B8BCC2")   // quinary — placeholders, faint dots

    // ── Accent — the single restrained indigo ──
    static let calmAccent      = Color(hex: "#4F5DDB")   // --accent
    static let calmAccentHover = Color(hex: "#3E4CB8")   // --accent-hover
    static let calmAccentLight = Color(hex: "#EEF0FC")   // --accent-light (chips, light wash)

    // ── Aurora spectrum (the ONLY saturated color, jewel dosage) ──
    static let calmAuroraCyan   = Color(hex: "#5BCDD6")   // --aurora-a
    static let calmAuroraViolet = Color(hex: "#7B6CF4")   // --aurora-b
    static let calmAuroraPink   = Color(hex: "#E879B0")   // --aurora-c

    // ── Semantic states ──
    static let calmSuccess   = Color(hex: "#2EA66B")   // --success
    static let calmSuccessBg = Color(hex: "#EFF9F4")   // --success-bg
    static let calmWarn      = Color(hex: "#D97B35")   // --warn
    static let calmWarnBg    = Color(hex: "#FFF5ED")   // --warn-bg

    // ── Hairlines ──
    static let calmBorder       = Color(hex: "#ECEDF0")   // --border (hairline)
    static let calmBorderMed    = Color(hex: "#DDE0E5")   // --border-med
    static let calmBorderStrong = Color(hex: "#C8CCD4")   // --border-strong

    // ── Dark mode — cool charcoal ground (never pure black) ──
    static let calmDarkGround   = Color(hex: "#16181C")   // window ground
    static let calmDarkSurface  = Color(hex: "#1E2127")   // cards, rows, popover body
    static let calmDarkSidebar  = Color(hex: "#1A1D22")   // sidebar / footers
    static let calmDarkHover    = Color(hex: "#24272E")   // row hover
    static let calmDarkActive   = Color(hex: "#262A3C")   // selected-row wash (cool indigo-charcoal)

    // ── Dark mode — soft light ink (never pure white) ──
    static let calmDarkInk   = Color(hex: "#E9EAED")
    static let calmDarkInk2  = Color(hex: "#CDD0D6")
    static let calmDarkInk3  = Color(hex: "#9A9EA6")
    static let calmDarkInk4  = Color(hex: "#6C707A")
    static let calmDarkInk5  = Color(hex: "#4C5059")

    // ── Dark mode accent (slightly lifted for contrast on charcoal) ──
    static let calmDarkAccent      = Color(hex: "#7B86EF")
    static let calmDarkAccentLight = Color(hex: "#2A2E48")

    // MARK: - Adaptive helpers (mirror Mercury's API)

    /// Window ground.
    static func calmBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkGround : .calmGround
    }

    /// Pure surface — cards, rows, popover body.
    static func calmSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkSurface : .calmSurface
    }

    /// Quiet tinted surface — sidebar, titlebar, footers, chips.
    static func calmSubtle(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkSidebar : .calmSidebar
    }

    /// Row hover wash.
    static func calmHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkHover : .calmHover
    }

    /// Selected-row / active wash (indigo-tinted).
    static func calmActive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkActive : .calmActive
    }

    /// Hairline divider.
    static func calmDivider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkInk.opacity(0.08) : .calmBorder
    }

    /// Medium hairline (card edges, key badges).
    static func calmHairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkInk.opacity(0.12) : .calmBorderMed
    }

    /// The single indigo accent.
    static func calmAccent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkAccent : .calmAccent
    }

    /// Light indigo wash behind accent text/chips.
    static func calmAccentWash(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkAccentLight : .calmAccentLight
    }

    /// Primary label.
    static func calmLabel(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkInk : .calmInk
    }

    /// Body label.
    static func calmLabel2(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkInk2 : .calmInk2
    }

    /// Secondary label.
    static func calmLabel3(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkInk3 : .calmInk3
    }

    /// Tertiary label.
    static func calmLabel4(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkInk4 : .calmInk4
    }

    /// Quinary label (placeholders, timestamps).
    static func calmLabel5(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .calmDarkInk5 : .calmInk5
    }
}

// MARK: - Status Dot Color Language
//
// Shared by the recording orb (FloatingBar), the menubar status dot, and the
// popover status row so the same state always reads as the same color.
// Idle is quiet gray; recording/transcribing are indigo; success/error are
// semantic. The aurora gradient stays reserved for the orb body itself.

enum CalmStatus {
    case idle
    case recording
    case transcribing
    case success
    case error

    /// Solid dot color for a small status indicator.
    func dotColor(for scheme: ColorScheme) -> Color {
        switch self {
        case .idle:         return Color.calmLabel4(for: scheme)
        case .recording:    return Color.calmAccent(for: scheme)
        case .transcribing: return Color.calmAccent(for: scheme).opacity(0.7)
        case .success:      return .calmSuccess
        case .error:        return .calmWarn
        }
    }

    /// One-word human label.
    var label: String {
        switch self {
        case .idle:         return "Ready to record"
        case .recording:    return "Recording"
        case .transcribing: return "Transcribing"
        case .success:      return "Inserted"
        case .error:        return "Something went wrong"
        }
    }

    /// Short status word for the compact orb caption.
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

// MARK: - Aurora gradients (jewel dosage only)

extension LinearGradient {
    /// The aurora sweep — credit-balance bar fill, orb body. Cyan → violet → pink.
    static let calmAurora = LinearGradient(
        colors: [.calmAuroraCyan, .calmAuroraViolet, .calmAuroraPink],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Two-stop aurora for compact bars (balance mini-bar).
    static let calmAuroraBar = LinearGradient(
        colors: [.calmAuroraCyan, .calmAuroraViolet],
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension RadialGradient {
    /// Aurora orb core — small saturated jewel for app-icon / orb dot moments.
    static let calmAuroraOrb = RadialGradient(
        colors: [.calmAuroraCyan, .calmAuroraViolet, .calmAuroraPink],
        center: .topLeading,
        startRadius: 0,
        endRadius: 14
    )
}

// MARK: - Typography helpers (system .default — no serif)

extension Font {
    /// 22pt — calm greeting / hero sentence.
    static var calmHeading: Font { Font.system(size: 22, weight: .semibold) }

    /// 19pt — onboarding / section title.
    static var calmTitle: Font { Font.system(size: 19, weight: .semibold) }

    /// 24pt semibold — stat-card value.
    static var calmStatValue: Font { Font.system(size: 24, weight: .semibold) }

    /// 28pt medium — credit balance dollar figure (main window).
    static var calmBalance: Font { Font.system(size: 28, weight: .semibold) }

    /// 16pt semibold — popover balance figure.
    static var calmPopoverBalance: Font { Font.system(size: 16, weight: .semibold) }

    /// 15pt semibold — popover app name.
    static var calmPopoverName: Font { Font.system(size: 15, weight: .semibold) }

    /// 10pt bold — uppercase section labels (kerned by call site).
    static var calmSectionLabel: Font { Font.system(size: 10, weight: .bold) }
}

// MARK: - Spacing rhythm (matches the calm board's generous gaps)

enum C {
    static let s1: CGFloat =  4
    static let s2: CGFloat =  8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 22
    static let s6: CGFloat = 28
    static let s7: CGFloat = 40

    // Corner radii (mirror the board's --r-* tokens)
    static let rXS:  CGFloat = 4
    static let rSM:  CGFloat = 6
    static let rMD:  CGFloat = 10
    static let rLG:  CGFloat = 14
    static let rXL:  CGFloat = 18
}

// MARK: - Calm hairline view (replaces the Mercury aurora hairline)

/// A single quiet hairline. Calm has no aurora top-edge; dividers do the work.
struct CalmHairline: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle()
            .fill(Color.calmDivider(for: scheme))
            .frame(height: 1)
    }
}

// MARK: - Aurora status dot (shared menubar / popover / orb language)

/// Small dot that renders the aurora gradient for "live" states and a quiet
/// gray for idle — the same visual language the menubar icon uses.
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
        case .recording, .transcribing: return Color.calmAccent(for: scheme)
        case .success:                  return .calmSuccess
        case .error:                    return .calmWarn
        case .idle:                     return .clear
        }
    }
}
