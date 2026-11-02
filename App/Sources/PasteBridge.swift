import AppKit
import LoomKit
import ObjectiveC
import UniformTypeIdentifiers

/// Lets the composer take an image from a paste.
///
/// A focused text field is an `NSTextView` field editor, and its `paste:` reads
/// text only, so an image on the pasteboard is dropped before SwiftUI's paste
/// handler can see it. There is no public hook between the menu's Paste and the
/// field editor, so this exchanges the one method. The replacement keeps every
/// text paste as it was: it intervenes only when the pasteboard holds an image
/// or image files and no text, and only while a composer is registered.
@MainActor
enum PasteBridge {
    /// The composer that currently has the keyboard.
    static weak var target: ComposerModel?
    private static var isInstalled = false

    static func install() {
        guard !isInstalled,
              let original = class_getInstanceMethod(NSTextView.self, #selector(NSTextView.paste(_:))),
              let replacement = class_getInstanceMethod(NSTextView.self, #selector(NSTextView.loomPaste(_:)))
        else { return }
        isInstalled = true
        method_exchangeImplementations(original, replacement)
    }

    /// Takes the pasteboard's images for the composer. Returns whether it did.
    static func take(from board: NSPasteboard) -> Bool {
        guard let target, board.availableType(from: [.string]) == nil else { return false }
        let types = [UTType.image.identifier]
        if let urls = board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: types]
        ) as? [URL], !urls.isEmpty {
            for url in urls {
                if let data = try? Data(contentsOf: url) { target.attach(data, name: url.lastPathComponent) }
            }
            return true
        }
        if let image = board.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            target.attach(png, name: "Pasted image")
            return true
        }
        return false
    }
}

extension NSTextView {
    /// After the exchange this name runs the original text paste.
    @objc func loomPaste(_ sender: Any?) {
        if PasteBridge.take(from: .general) { return }
        loomPaste(sender)
    }
}
