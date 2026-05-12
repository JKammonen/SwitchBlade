#!/usr/bin/env swift
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.temporaryDirectory.appendingPathComponent("SwitchBlade.icns").path

func makeIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        // Clip to rounded rect background
        let radius = s * 0.22
        let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                            cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(bgPath)
        ctx.clip()

        // Dark navy gradient background
        let cs = CGColorSpaceCreateDeviceRGB()
        let bgColors = [CGColor(red: 0.09, green: 0.12, blue: 0.24, alpha: 1),
                        CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1)] as CFArray
        let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
        ctx.drawLinearGradient(bgGradient,
            start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

        // Helper: draw a window rectangle
        func drawWindow(_ rect: CGRect, fillAlpha: CGFloat, strokeAlpha: CGFloat, accentR: CGFloat, accentG: CGFloat, accentB: CGFloat) {
            let cr = s * 0.065
            let lw = max(1, s * 0.024)
            let wp = CGPath(roundedRect: rect, cornerWidth: cr, cornerHeight: cr, transform: nil)

            // Window body
            ctx.addPath(wp)
            ctx.setFillColor(CGColor(red: accentR * 0.5, green: accentG * 0.5, blue: accentB * 0.9, alpha: fillAlpha))
            ctx.fillPath()

            // Title bar strip
            let tbH = rect.height * 0.20
            let tbRect = CGRect(x: rect.minX, y: rect.maxY - tbH, width: rect.width, height: tbH)
            let tbPath = CGPath(roundedRect: tbRect,
                                cornerWidth: cr, cornerHeight: cr, transform: nil)
            ctx.addPath(tbPath)
            ctx.setFillColor(CGColor(red: accentR, green: accentG, blue: accentB, alpha: strokeAlpha * 0.7))
            ctx.fillPath()

            // Outline
            ctx.addPath(wp)
            ctx.setStrokeColor(CGColor(red: accentR, green: accentG, blue: accentB, alpha: strokeAlpha))
            ctx.setLineWidth(lw)
            ctx.strokePath()
        }

        let pad  = s * 0.13
        let ww   = s * 0.55
        let wh   = s * 0.42

        // Back window — offset top-right, muted blue
        drawWindow(CGRect(x: s * 0.30, y: s * 0.24, width: ww, height: wh),
                   fillAlpha: 0.45, strokeAlpha: 0.65,
                   accentR: 0.38, accentG: 0.58, accentB: 1.0)

        // Front window — offset bottom-left, vivid blue
        drawWindow(CGRect(x: pad, y: s * 0.34, width: ww, height: wh),
                   fillAlpha: 0.80, strokeAlpha: 1.0,
                   accentR: 0.38, accentG: 0.70, accentB: 1.0)

        return true
    }
}

// Build .iconset directory
let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("SwitchBlade_\(Int.random(in: 1000...9999)).iconset")
try? FileManager.default.removeItem(at: tmpDir)
try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16,   "icon_16x16"),
    (32,   "icon_16x16@2x"),
    (32,   "icon_32x32"),
    (64,   "icon_32x32@2x"),
    (128,  "icon_128x128"),
    (256,  "icon_128x128@2x"),
    (256,  "icon_256x256"),
    (512,  "icon_256x256@2x"),
    (512,  "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

for (px, name) in sizes {
    let img = makeIcon(size: px)
    let url = tmpDir.appendingPathComponent("\(name).png")
    guard let tiff = img.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:])
    else { fatalError("Failed to render PNG at \(px)") }
    try! png.write(to: url)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", outputPath, tmpDir.path]
try! proc.run()
proc.waitUntilExit()

try? FileManager.default.removeItem(at: tmpDir)
print("Icon written to \(outputPath)")
