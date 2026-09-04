import Foundation
import AppKit

/// Transparent stats overlay drawn over the video layer.
final class HudOverlay {
    private let view: NSTextView

    init(parent: NSView) {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55)
        tv.textColor = NSColor(calibratedWhite: 1, alpha: 0.95)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isVerticallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        view = tv
        parent.addSubview(tv)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.topAnchor.constraint(equalTo: parent.topAnchor, constant: 8).isActive = true
        tv.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8).isActive = true
        tv.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
    }

    func update(lines: [String]) {
        view.string = lines.joined(separator: "\n")
        view.sizeToFit()
    }
}
