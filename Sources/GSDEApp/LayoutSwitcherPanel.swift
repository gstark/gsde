import AppKit

final class LayoutSwitcherPanel: NSPanel {
    init(
        layoutIDs: [String],
        activeLayoutID: String,
        anchorFrameInScreen: NSRect,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let width: CGFloat = 560
        let rowHeight: CGFloat = 54
        let height = min(CGFloat(layoutIDs.count) * rowHeight + 112, 620)
        let screenFrame = Self.screenFrame(containing: anchorFrameInScreen)
        let frame = NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = LayoutSwitcherView(
            frame: NSRect(origin: .zero, size: frame.size),
            layoutIDs: layoutIDs,
            activeLayoutID: activeLayoutID,
            onSelect: onSelect,
            onCancel: onCancel
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private static func screenFrame(containing frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { NSPointInRect(center, $0.frame) }
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? frame
    }
}

private final class LayoutSwitcherView: NSView {
    private let layoutIDs: [String]
    private let activeLayoutID: String
    private let onSelect: (String) -> Void
    private let onCancel: () -> Void
    private var selectedIndex: Int

    private let titleHeight: CGFloat = 72
    private let footerHeight: CGFloat = 40
    private let rowHeight: CGFloat = 54
    private let horizontalInset: CGFloat = 18

    init(
        frame frameRect: NSRect,
        layoutIDs: [String],
        activeLayoutID: String,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.layoutIDs = layoutIDs
        self.activeLayoutID = activeLayoutID
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.selectedIndex = max(0, layoutIDs.firstIndex(of: activeLayoutID) ?? 0)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        preconditionFailure("LayoutSwitcherView requires layout IDs")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, key) {
        case (53, _), (_, "\u{1b}"):
            onCancel()
        case (36, _), (76, _), (_, "\r"), (_, "\n"):
            onSelect(layoutIDs[selectedIndex])
        case (125, _), (_, "j"):
            moveSelection(1)
        case (126, _), (_, "k"):
            moveSelection(-1)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point) else { return }
        selectedIndex = index
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point), index == selectedIndex else { return }
        onSelect(layoutIDs[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.08, alpha: 0.95).setFill()
        backgroundPath.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()

        drawTitle()
        drawRows()
        drawFooter()
    }

    private func drawTitle() {
        let title = "Switch Layout"
        title.draw(
            in: NSRect(x: horizontalInset, y: 18, width: bounds.width - horizontalInset * 2, height: 30),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )

        let subtitle = "⌃⌥⌘L · ↑/↓ or j/k · Return to activate · Esc to close"
        subtitle.draw(
            in: NSRect(x: horizontalInset, y: 48, width: bounds.width - horizontalInset * 2, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(white: 0.74, alpha: 1.0)
            ]
        )
    }

    private func drawRows() {
        for (index, layoutID) in layoutIDs.enumerated() {
            let y = titleHeight + CGFloat(index) * rowHeight
            guard y + rowHeight <= bounds.height - footerHeight + 1 else { break }
            let rowRect = NSRect(
                x: horizontalInset,
                y: y + 4,
                width: bounds.width - horizontalInset * 2,
                height: rowHeight - 8
            )

            if index == selectedIndex {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 10, yRadius: 10).fill()
            } else if layoutID == activeLayoutID {
                NSColor(calibratedWhite: 1.0, alpha: 0.10).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 10, yRadius: 10).fill()
            }

            let isSelected = index == selectedIndex
            let marker = layoutID == activeLayoutID ? "✓" : " "
            let text = "\(marker)  \(layoutID)"
            text.draw(
                in: rowRect.insetBy(dx: 18, dy: 12),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 20, weight: layoutID == activeLayoutID ? .semibold : .regular),
                    .foregroundColor: isSelected ? NSColor.white : NSColor(white: 0.92, alpha: 1.0)
                ]
            )
        }
    }

    private func drawFooter() {
        let footer = "Current layout is marked with ✓"
        footer.draw(
            in: NSRect(x: horizontalInset, y: bounds.height - 30, width: bounds.width - horizontalInset * 2, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor(white: 0.62, alpha: 1.0)
            ]
        )
    }

    private func moveSelection(_ offset: Int) {
        guard !layoutIDs.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + layoutIDs.count) % layoutIDs.count
        needsDisplay = true
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        let index = Int((point.y - titleHeight) / rowHeight)
        guard layoutIDs.indices.contains(index) else { return nil }
        return index
    }
}

final class LayoutFlashPanel: NSPanel {
    init(layoutID: String, screen: NSScreen) {
        let width: CGFloat = 460
        let height: CGFloat = 148
        let screenFrame = screen.visibleFrame
        let frame = NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alphaValue = 0
        contentView = LayoutFlashView(frame: NSRect(origin: .zero, size: frame.size), layoutID: layoutID)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LayoutFlashView: NSView {
    private let layoutID: String

    init(frame frameRect: NSRect, layoutID: String) {
        self.layoutID = layoutID
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        preconditionFailure("LayoutFlashView requires a layout ID")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.08, alpha: 0.95).setFill()
        backgroundPath.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        backgroundPath.lineWidth = 2
        backgroundPath.stroke()

        "Layout".draw(
            in: NSRect(x: 24, y: 26, width: bounds.width - 48, height: 20),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor(white: 0.72, alpha: 1.0)
            ]
        )

        layoutID.draw(
            in: NSRect(x: 24, y: 55, width: bounds.width - 48, height: 48),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )

        "Ctrl-Option-Command-Left/Right".draw(
            in: NSRect(x: 24, y: 108, width: bounds.width - 48, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor(white: 0.62, alpha: 1.0)
            ]
        )
    }
}
