// Generates AppIcon.icns by rendering the SF Symbol "tray.fill" over a dark
// rounded-square background at every size macOS asks for, then packing the
// PNGs with iconutil. Same glyph as the menu-bar icon so the dock/Finder/
// command-tab icon matches.
//
// Usage: swift make_icon.swift <output.icns>

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make_icon.swift <output.icns>\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let iconset = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    bg.addClip()
    NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
    rect.fill()

    let symbolPointSize = s * 0.55
    var cfg = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
    cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = symbol.size
        let drawRect = NSRect(
            x: (s - sz.width) / 2,
            y: (s - sz.height) / 2,
            width: sz.width,
            height: sz.height
        )
        symbol.draw(in: drawRect)
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("PNG encode failed at size \(size)\n".utf8))
        exit(1)
    }
    return png
}

for (size, name) in variants {
    try render(size).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", outputPath]
try task.run()
task.waitUntilExit()
if task.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(Int32(task.terminationStatus))
}

try? FileManager.default.removeItem(atPath: iconset)
