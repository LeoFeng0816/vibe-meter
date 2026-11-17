import SwiftUI
import VibeMeterCore

/// 少量、協調的顏色：每個 agent 一個品牌色（只用於細節點綴），用量只用三段狀態色。
enum Theme {
    static func accent(_ p: ProviderID) -> Color {
        switch p {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)   // Claude 陶土橘
        case .codex: Color(red: 0.36, green: 0.39, blue: 0.95)        // Codex 靛藍
        case .cursor: Color(red: 0.55, green: 0.56, blue: 0.60)
        case .antigravity: Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }

    static let ok = Color(red: 0.16, green: 0.68, blue: 0.53)
    static let warn = Color(red: 0.95, green: 0.62, blue: 0.20)
    static let critical = Color(red: 0.90, green: 0.29, blue: 0.30)
    static let info = Color(red: 0.25, green: 0.52, blue: 0.95)

    /// 依「已使用」百分比決定顏色。
    static func level(_ used: Double) -> Color {
        used >= 95 ? critical : used >= 80 ? warn : ok
    }

    static func planColor(_ state: ResumePlan.State) -> Color {
        switch state {
        case .waiting: warn
        case .needsConfirmation: Color(red: 0.62, green: 0.45, blue: 0.85)
        case .ready, .launching, .launched: info
        case .resumed: ok
        case .failed: critical
        case .skipped, .cancelled: .secondary
        }
    }

    static func planSymbol(_ state: ResumePlan.State) -> String {
        switch state {
        case .waiting: "hourglass"
        case .needsConfirmation: "questionmark.circle.fill"
        case .ready: "checkmark.circle"
        case .launching: "paperplane"
        case .launched: "paperplane.fill"
        case .resumed: "checkmark.circle.fill"
        case .skipped: "forward.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.opacity(0.55))
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct UsageBar: View {
    /// 剩餘百分比 0–100。
    var remaining: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(remaining > 0 ? 4 : 0, geo.size.width * remaining / 100))
            }
        }
        .frame(height: 6)
    }
}
