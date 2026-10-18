import SwiftUI

// MARK: - Page scaffold

/// Apple-style page header: mono kicker in the melon accent, SF Pro title, secondary subtitle.
struct MTPageHeader: View {
    let kicker: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s1) {
            Text(kicker.uppercased())
                .font(MTTheme.mono(10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(MTTheme.gold)
            Text(title)
                .font(MTTheme.display(27))
                .foregroundStyle(MTTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
        .padding(.bottom, MTTheme.s4)
    }
}

// MARK: - Card (solid surface)

struct MTCard<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            if let title {
                HStack(spacing: MTTheme.s2) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MTTheme.gold)
                    }
                    Text(title)
                        .font(MTTheme.body(13, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Spacer()
                }
            }
            content
        }
        .padding(MTTheme.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mtCardSurface()
    }
}

// MARK: - Status dot + pill

struct MTStatusDot: View {
    let status: MTStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

struct MTStatusPill: View {
    let text: String
    let status: MTStatus

    var body: some View {
        HStack(spacing: 5) {
            MTStatusDot(status: status, size: 6)
            Text(text)
                .font(MTTheme.mono(10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.14))
        .clipShape(Capsule())
        .foregroundStyle(status.color)
    }
}

// MARK: - Key/Value row (doctor-style table)

struct MTKeyValueRow: View {
    let key: String
    let value: String
    var status: MTStatus? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MTTheme.s3) {
            Text(key)
                .font(MTTheme.mono(11))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 120, alignment: .leading)
            if let status {
                MTStatusDot(status: status, size: 6)
            }
            Text(value)
                .font(MTTheme.mono(11))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Buttons

struct MTPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MTTheme.onGold)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(MTSolidButtonStyle(prominent: true))
        .disabled(isLoading)
    }
}

struct MTSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(MTSolidButtonStyle())
        .disabled(isLoading)
    }
}

// MARK: - Quota ring

struct MTQuotaRing: View {
    /// 0...1, nil = unknown
    let fraction: Double?
    var label: String? = nil
    var size: CGFloat = 44

    private var color: Color {
        guard let f = fraction else { return MTTheme.textTertiary }
        if f > 0.5 { return MTTheme.gold }
        if f > 0.15 { return MTTheme.warn }
        return MTTheme.danger
    }

    var body: some View {
        let text: String = {
            if let label { return label }
            if let fraction { return "\(Int((fraction * 100).rounded()))%" }
            return "—"
        }()
        ZStack {
            Circle()
                .stroke(MTTheme.borderColor, lineWidth: 4)
            if let f = fraction {
                Circle()
                    .trim(from: 0, to: max(0.01, min(1, f)))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(text)
                .font(MTTheme.mono(9, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Meter + bento stat tile

/// Horizontal meter: a pure-SwiftUI capsule bar. ProgressView hosted an
/// AppKit control per instance (and there are many on every page) — hosting
/// churn during scroll showed up as jank. The fill is scaled with
/// `scaleEffect` (a render-transform, no layout pass), so the meter works
/// without a GeometryReader inside scrolling content.
struct MTMeter: View {
    /// 0...1, nil = unknown.
    let fraction: Double?
    var tint: Color = MTTheme.gold
    var height: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(MTTheme.borderColor.opacity(0.6))
            if let fraction {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: min(1, max(0.02, fraction)), y: 1, anchor: .leading)
            }
        }
        .frame(height: height)
    }
}

/// A bento stat tile: mono caption, large value, optional meter and footnote.
struct MTMetricTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var fraction: Double? = nil
    var tint: Color = MTTheme.gold

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            Text(title.uppercased())
                .font(MTTheme.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(MTTheme.textTertiary)
            Text(value)
                .font(MTTheme.display(20, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let fraction {
                MTMeter(fraction: fraction, tint: tint)
            }
            if let caption {
                Text(caption)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
        .padding(MTTheme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MTTheme.cardSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
    }
}

// MARK: - Empty state

struct MTEmptyState: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: MTTheme.s2) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(MTTheme.gold.opacity(0.75))
            Text(title)
                .font(MTTheme.body(13, weight: .medium))
                .foregroundStyle(MTTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MTTheme.s6)
    }
}
