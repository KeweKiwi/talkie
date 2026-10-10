import AppKit

/// AX uses top-left display coordinates; AppKit windows use bottom-left ones.
enum DictationOverlayPlacement {
    static func appKitRect(_ rect: CGRect, primaryScreen: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func frame(size: CGSize, anchor: CGRect?, visibleScreens: [CGRect]) -> CGRect {
        let screen = anchor.flatMap { anchor in
            visibleScreens.first { $0.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
                ?? visibleScreens.max { $0.intersection(anchor).area < $1.intersection(anchor).area }
        } ?? visibleScreens.first ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let safe = screen.insetBy(dx: 8, dy: 8)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        var x = anchor?.minX ?? (safe.midX - width / 2)
        var y = anchor.map { $0.minY - height - 8 } ?? (safe.minY + 28)
        if let anchor, y < safe.minY { y = anchor.maxY + 8 }
        x = min(max(x, safe.minX), safe.maxX - width)
        y = min(max(y, safe.minY), safe.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}
