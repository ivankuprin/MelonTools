import AppKit

/// App artwork: the bundle logo, sized for each surface.
enum MelonAssets {
    /// Full-resolution logo from the app bundle (`Logo.png`).
    static let logo: NSImage = {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(size: NSSize(width: 64, height: 64))
    }()

    /// Small logo pre-rendered at menu-bar height.
    static let menuBarLogo: NSImage = {
        let height: CGFloat = 18
        let ratio = logo.size.height > 0 ? logo.size.width / logo.size.height : 1
        let size = NSSize(width: (height * ratio).rounded(), height: height)
        return NSImage(size: size, flipped: false) { rect in
            logo.draw(in: rect)
            return true
        }
    }()
}
