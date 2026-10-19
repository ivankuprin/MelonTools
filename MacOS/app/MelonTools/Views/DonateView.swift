import AppKit
import CoreImage
import SwiftUI

/// Donate page: USDT (TRC20) wallet QR + copyable address.
/// The QR is generated on the fly with CoreImage — no binary asset to rot.
struct DonateView: View {
    /// USDT wallet (TRON / TRC20).
    private static let walletAddress = "TXtXMdkwKt2Nnxwo7ST9h4otFp3WYWjpfw"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "app",
                    title: L("Donate"),
                    subtitle: L("Donate subtitle")
                )

                MTCard(title: L("USDT · TRON (TRC20)"), systemImage: "qrcode") {
                    VStack(alignment: .leading, spacing: MTTheme.s4) {
                        HStack(alignment: .top, spacing: MTTheme.s5) {
                            qrCard
                                .frame(width: 240, height: 240)
                            VStack(alignment: .leading, spacing: MTTheme.s3) {
                                Text(L("Wallet address"))
                                    .font(MTTheme.mono(10, weight: .semibold))
                                    .tracking(0.8)
                                    .textCase(.uppercase)
                                    .foregroundStyle(MTTheme.textTertiary)
                                Text(Self.walletAddress)
                                    .font(MTTheme.mono(12, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.7)
                                MTSecondaryButton(title: L("Copy address"), systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(Self.walletAddress, forType: .string)
                                }
                                Text(L("Scan the code or paste the address into any wallet that supports USDT TRC20."))
                                    .font(MTTheme.mono(10))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }
                        Text(L("Thank you for supporting Melon Tools! 🍉"))
                            .font(MTTheme.body(13, weight: .medium))
                            .foregroundStyle(MTTheme.gold)
                    }
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.donate")
        }
        .background(MTTheme.background)
    }

    // MARK: - QR

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .fill(Color.white)
            if let qr = Self.qrImage(Self.walletAddress) {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(12)
            }
            // Center badge — the TRON token mark.
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                Circle()
                    .fill(Self.usdtGreen)
                    .frame(width: 36, height: 36)
                Text("₮")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
        )
    }

    private static let usdtGreen = Color(hex: 0x26A17B)

    /// Black-on-transparent QR: the white card supplies the background.
    private static func qrImage(_ string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let base = filter.outputImage else { return nil }
        let scale: CGFloat = 10
        let sized = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(sized, from: sized.extent) else { return nil }
        let size = NSSize(width: sized.extent.width, height: sized.extent.height)
        return NSImage(cgImage: cg, size: size)
    }
}
