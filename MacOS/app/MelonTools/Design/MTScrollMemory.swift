import AppKit
import SwiftUI

/// Remembers the vertical scroll offset of the page's NSScrollView per key, so
/// switching sidebar sections returns you where you left off. Attach it INSIDE
/// the ScrollView content — the tracker walks up to the enclosing NSScrollView:
///
///     ScrollView { VStack { … }.mtScrollMemory("scroll.accounts") }
///
/// Restoring is best-effort: before the content is laid out the offset is
/// clamped, so the tracker retries once after the first layout pass. Nothing
/// happens when no NSScrollView encloses the tracker.
struct MTScrollMemory: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView { Tracker(key: key) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Tracker: NSView {
        private let key: String
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var lastSave = Date.distantPast

        init(key: String) {
            self.key = key
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { detach() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach()
            } else {
                attach()
            }
        }

        private func attach() {
            detach()
            var parent: NSView? = superview
            while let current = parent, !(current is NSScrollView) {
                parent = current.superview
            }
            guard let scroll = parent as? NSScrollView else { return }
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.persist(throttled: true)
            }
            restore(on: scroll)
        }

        private func detach() {
            persist(throttled: false)
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            scrollView = nil
        }

        private func restore(on scroll: NSScrollView) {
            let saved = UserDefaults.standard.double(forKey: "scroll.\(key)")
            guard saved > 1 else { return }
            // First pass right after the move, second one after layout — the
            // document height is only known once SwiftUI laid the page out.
            for delay in [0.0, 0.18] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak scroll] in
                    guard let scroll, let document = scroll.documentView else { return }
                    let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
                    guard maxY > 1 else { return }
                    let target = min(CGFloat(saved), maxY)
                    scroll.contentView.scroll(
                        to: NSPoint(x: scroll.contentView.bounds.origin.x, y: target)
                    )
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        private func persist(throttled: Bool) {
            guard let scrollView else { return }
            if throttled {
                let now = Date()
                guard now.timeIntervalSince(lastSave) > 0.3 else { return }
                lastSave = now
            }
            UserDefaults.standard.set(
                Double(scrollView.contentView.bounds.origin.y),
                forKey: "scroll.\(key)"
            )
        }
    }
}

extension View {
    /// See `MTScrollMemory`.
    func mtScrollMemory(_ key: String) -> some View {
        background(MTScrollMemory(key: key))
    }
}
