import AppKit

/// One monitor in the menu bar: circular icon, name, and a status line.
struct TBMenuMonitorSpec {
    let symbol: String
    let title: String
    /// Under the title — "60 fps · lossless" while streaming, "Available" when
    /// idle, or the failure reason.
    let subtitle: String
    let isStreaming: Bool
    /// Draws the subtitle in red. A connect that failed must say so where the
    /// user clicked, not only in a window they would have to go and open.
    let isError: Bool
    let onTap: () -> Void
}

/// A clickable monitor row, laid out like Control Center's device list.
///
/// This is what makes the menu bar useful on its own: before it existed there was
/// no way to start streaming without opening the main window, which defeats the
/// point of a menu bar item.
///
/// Built as a custom menu-item view for the same reason `TBMenuToggleRowView` is:
/// an `NSMenuItem` renders a title and little else, and this row needs an icon
/// that reflects state plus two lines of text. Menus do not lay out subviews, so
/// all geometry here is explicit — and `NSMenuItem` sizes its row from the view's
/// frame, so the frame must be set or the item is present at zero height and
/// therefore invisible.
final class TBMenuMonitorRowView: NSView {

    private enum Metrics {
        static let icon: CGFloat = 30
        static let iconGap: CGFloat = 10        // icon -> text
        static let titleHeight: CGFloat = 16
        static let subtitleHeight: CGFloat = 13
        static let verticalPadding: CGFloat = 6
        static var height: CGFloat {
            verticalPadding * 2 + titleHeight + subtitleHeight
        }
    }

    static var preferredHeight: CGFloat { Metrics.height }

    private let spec: TBMenuMonitorSpec
    private var iconView: NSImageView?
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false

    init(spec: TBMenuMonitorSpec, width: CGFloat, leadingInset: CGFloat) {
        self.spec = spec
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.height))
        build(width: width, leadingInset: leadingInset)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(width: CGFloat, leadingInset: CGFloat) {
        wantsLayer = true

        let iconY = (Metrics.height - Metrics.icon) / 2
        let icon = NSImageView(frame: NSRect(x: leadingInset, y: iconY,
                                            width: Metrics.icon, height: Metrics.icon))
        icon.wantsLayer = true
        icon.layer?.cornerRadius = Metrics.icon / 2
        icon.layer?.backgroundColor = spec.isStreaming
            ? NSColor.controlAccentColor.cgColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: spec.symbol,
                             accessibilityDescription: spec.title)?
            .withSymbolConfiguration(config)
        // A template image tinted by contentTintColor: the glyph must read against
        // both the accent-filled circle and the muted one.
        icon.image?.isTemplate = true
        icon.contentTintColor = spec.isStreaming ? .white : .labelColor
        icon.imageAlignment = .alignCenter
        addSubview(icon)
        iconView = icon

        let textX = leadingInset + Metrics.icon + Metrics.iconGap
        let textWidth = width - textX - leadingInset

        let titleY = Metrics.height - Metrics.verticalPadding - Metrics.titleHeight
        let title = Self.label(frame: NSRect(x: textX, y: titleY,
                                            width: textWidth, height: Metrics.titleHeight),
                               text: spec.title,
                               font: .systemFont(ofSize: 13),
                               colour: .labelColor)
        addSubview(title)

        let subtitle = Self.label(
            frame: NSRect(x: textX, y: Metrics.verticalPadding,
                          width: textWidth, height: Metrics.subtitleHeight),
            text: spec.subtitle,
            font: .systemFont(ofSize: 11),
            colour: spec.isError ? .systemRed : .secondaryLabelColor)
        addSubview(subtitle)

        setAccessibilityLabel("\(spec.title). \(spec.subtitle)")
        setAccessibilityRole(.button)
    }

    private static func label(frame: NSRect, text: String,
                              font: NSFont, colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = font
        // Dynamic system colours, never literals: the menu is drawn in whichever
        // appearance the menu bar is using, and a fixed colour is wrong in one of
        // them. This is the bug that made the status item unreadable.
        field.textColor = colour
        field.lineBreakMode = .byTruncatingTail
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        return field
    }

    // MARK: Highlight — menus do not do this for custom views

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        // selectedContentBackgroundColor is the same highlight AppKit paints for
        // ordinary menu items, so a custom row does not look foreign next to them.
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
        let inset = bounds.insetBy(dx: 5, dy: 1)
        NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5).fill()
    }

    override func mouseUp(with event: NSEvent) {
        // Dismiss first: the action opens windows or starts a stream, and a menu
        // left tracking over that is both wrong and hard to get rid of.
        enclosingMenuItem?.menu?.cancelTracking()
        spec.onTap()
    }
}
