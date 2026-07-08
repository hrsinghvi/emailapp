import AppKit

/// Floating selection chrome for an inline image attachment in the compose
/// body: a border box matching the image's glyph rect, a bottom-right drag
/// handle for freeform resize, and a small preset toolbar below it — mirrors
/// Gmail's own image-selected state. Positioned/sized entirely by its owner
/// (`RichTextEditorController`); this view just renders chrome and reports
/// gestures back through closures.
final class ImageResizeOverlay: NSView {
    enum ImagePreset { case small, bestFit, original }

    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onPreset: ((ImagePreset) -> Void)?
    var onRemove: (() -> Void)?

    private let handle = NSView()
    private let toolbar = NSStackView()
    private var dragging = false
    private var dragStartX: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        handle.frame = NSRect(x: bounds.maxX - 5, y: bounds.maxY - 5, width: 10, height: 10)
        let size = toolbar.fittingSize
        toolbar.frame = NSRect(x: 0, y: bounds.maxY + 6, width: size.width, height: size.height)
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
