import AppKit

/// Floating selection chrome for an inline image attachment in the compose
/// body: a border box matching the image's glyph rect, a bottom-right drag
/// handle for freeform resize, and a small preset toolbar below it — mirrors
/// Gmail's own image-selected state.
///
/// The view's own `frame` is deliberately bigger than the image's glyph
/// rect — it has to extend far enough to cover the handle's overshoot and
/// the toolbar sitting below the image, otherwise those controls render
/// outside this view's hit-testable bounds: a click there never reaches
/// this view or its subviews at all (AppKit hit-tests by walking frames,
/// unaffected by what's merely drawn outside them), so it falls straight
/// through to the `NSTextView` underneath — which is exactly the "clicking
/// the toolbar/handle just clicks into the document instead" bug this
/// fixes.
final class ImageResizeOverlay: NSView {
    enum ImagePreset { case small, bestFit, original }

    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onPreset: ((ImagePreset) -> Void)?
    var onRemove: (() -> Void)?

    private let imageBox = NSView()
    private let handle = NSView()
    private let toolbar = NSStackView()
    private var dragging = false
    private var dragStartX: CGFloat = 0

    override var isFlipped: Bool { true }

    init(imageRect: NSRect) {
        super.init(frame: .zero)

        imageBox.wantsLayer = true
        imageBox.layer?.borderColor = NSColor.controlAccentColor.cgColor
        imageBox.layer?.borderWidth = 2
        addSubview(imageBox)

        handle.wantsLayer = true
        handle.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        handle.layer?.cornerRadius = 5
        addSubview(handle)

        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        toolbar.layer?.cornerRadius = 6
        for (title, tag) in [("Small", 0), ("Best fit", 1), ("Original size", 2)] {
            let button = NSButton(title: title, target: self, action: #selector(presetTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = tag
            toolbar.addArrangedSubview(button)
        }
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeTapped))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        toolbar.addArrangedSubview(remove)
        addSubview(toolbar)

        reposition(imageRect: imageRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Recomputes this view's own (expanded) frame and every child's frame
    /// from the attachment's current glyph rect — called on first show and
    /// again after every resize/preset change since the image's size (and
    /// so the space needed for the handle/toolbar) just changed.
    func reposition(imageRect: NSRect) {
        let toolbarSize = toolbar.fittingSize
        let handleOvershoot: CGFloat = 6
        let gap: CGFloat = 6
        let totalWidth = max(imageRect.width + handleOvershoot, toolbarSize.width)
        let totalHeight = imageRect.height + handleOvershoot + gap + toolbarSize.height
        frame = NSRect(x: imageRect.minX, y: imageRect.minY, width: totalWidth, height: totalHeight)

        imageBox.frame = NSRect(x: 0, y: 0, width: imageRect.width, height: imageRect.height)
        handle.frame = NSRect(x: imageRect.width - 5, y: imageRect.height - 5, width: 10, height: 10)
        toolbar.frame = NSRect(x: 0, y: imageRect.height + gap, width: toolbarSize.width, height: toolbarSize.height)
    }

    @objc private func presetTapped(_ sender: NSButton) {
        onPreset?(sender.tag == 0 ? .small : (sender.tag == 1 ? .bestFit : .original))
    }

    @objc private func removeTapped() { onRemove?() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard handle.frame.insetBy(dx: -6, dy: -6).contains(point) else { return }
        dragging = true
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onDrag?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDragEnd?()
    }
}
