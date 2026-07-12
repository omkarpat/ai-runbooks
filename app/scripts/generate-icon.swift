// Generates a 1024×1024 PNG app icon (a record-button motif on an indigo
// gradient) with no external assets. Run: swift app/scripts/generate-icon.swift <out.png>
// The Makefile `icon` target turns it into Runbooks.icns via sips + iconutil.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-rect gradient background (macOS "squircle"-ish corner).
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.225
NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
let colors = [
    NSColor(srgbRed: 0.45, green: 0.34, blue: 0.90, alpha: 1).cgColor,
    NSColor(srgbRed: 0.22, green: 0.18, blue: 0.52, alpha: 1).cgColor,
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0),
                       options: [])

// Record button: white ring + filled inner dot, centered.
let c = size / 2
let outerR = size * 0.30
let ringWidth = size * 0.05
NSColor.white.setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: c - outerR, y: c - outerR, width: outerR * 2, height: outerR * 2))
ring.lineWidth = ringWidth
ring.stroke()

let innerR = outerR * 0.52
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: c - innerR, y: c - innerR, width: innerR * 2, height: innerR * 2)).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
