#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate Apple HIG-compliant macOS App Icons (.icns & .png) for CloneStudio
in both Light Mode and Dark Mode variants, plus a monochrome macOS Status Bar
template icon, using native macOS CoreGraphics & ImageIO.
Follows Apple macOS Sequoia / Sonoma Icon Grid:
- 1024x1024 canvas
- 824x824 squircle body (100px outer margin = 0.09765625 * size)
- 22.5% continuous corner radius (185.4px)
"""

import os
import subprocess
import tempfile

SWIFT_ICON_RENDERER = r"""
import Cocoa
import CoreGraphics
import ImageIO

func makeBitmapContext(pixelSize: Int) -> (NSBitmapImageRep, CGContext)? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    return (rep, nsCtx.cgContext)
}

func saveRepPNG(_ rep: NSBitmapImageRep, to path: String) {
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

func saveICNS(isLight: Bool, to icnsPath: String) {
    let url = URL(fileURLWithPath: icnsPath) as CFURL
    let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]
    guard let dest = CGImageDestinationCreateWithURL(url, "com.apple.icns" as CFString, icnsSizes.count, nil) else {
        return
    }
    for px in icnsSizes {
        if let rep = renderPlasmidIcon(pixelSize: px, isLight: isLight),
           let cgImg = rep.cgImage {
            CGImageDestinationAddImage(dest, cgImg, nil)
        }
    }
    CGImageDestinationFinalize(dest)
}

func renderPlasmidIcon(pixelSize: Int, isLight: Bool) -> NSBitmapImageRep? {
    guard let (rep, ctx) = makeBitmapContext(pixelSize: pixelSize) else {
        return nil
    }
    let size = CGFloat(pixelSize)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let cx = size * 0.5
    let cy = size * 0.5
    // Apple HIG standard: 824x824 squircle inside 1024x1024 canvas (100px padding)
    let pad = size * (100.0 / 1024.0)
    let sqSize = size - pad * 2.0
    let cornerRadius = sqSize * 0.225
    let sqRect = CGRect(x: pad, y: pad, width: sqSize, height: sqSize)

    // 1. Apple HIG Standard Squircle Drop Shadow (28px blur, -12px y-offset at 1024px)
    let sqPath = CGPath(roundedRect: sqRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * (12.0 / 1024.0)),
        blur: size * (28.0 / 1024.0),
        color: CGColor(gray: 0.0, alpha: isLight ? 0.20 : 0.42)
    )
    ctx.addPath(sqPath)
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip inside squircle
    ctx.saveGState()
    ctx.addPath(sqPath)
    ctx.clip()

    // 2. Background Linear Gradient (Top to Bottom)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgTop: CGColor
    let bgBot: CGColor
    if isLight {
        bgTop = CGColor(srgbRed: 0.995, green: 0.998, blue: 1.000, alpha: 1.0)
        bgBot = CGColor(srgbRed: 0.898, green: 0.935, blue: 0.985, alpha: 1.0)
    } else {
        bgTop = CGColor(srgbRed: 0.105, green: 0.148, blue: 0.245, alpha: 1.0)
        bgBot = CGColor(srgbRed: 0.045, green: 0.065, blue: 0.122, alpha: 1.0)
    }
    if let bgGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [bgTop, bgBot] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: cx, y: size - pad),
            end: CGPoint(x: cx, y: pad),
            options: []
        )
    }

    // 3. Soft Radial Ambient Glow in Center
    let glowCenterCol = isLight
        ? CGColor(srgbRed: 0.14, green: 0.58, blue: 0.96, alpha: 0.12)
        : CGColor(srgbRed: 0.18, green: 0.72, blue: 0.98, alpha: 0.22)
    let glowEdgeCol = CGColor(srgbRed: 0.14, green: 0.58, blue: 0.96, alpha: 0.0)
    if let radGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [glowCenterCol, glowEdgeCol] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            radGrad,
            startCenter: CGPoint(x: cx, y: cy),
            startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy),
            endRadius: size * 0.34,
            options: []
        )
    }

    // 4. Minimalist Subtle Guide Ring Track
    let ringRadius = size * 0.245
    let ringWidth = size * 0.074
    ctx.saveGState()
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setLineWidth(size * 0.014)
    ctx.setStrokeColor(
        isLight
            ? CGColor(srgbRed: 0.15, green: 0.35, blue: 0.72, alpha: 0.10)
            : CGColor(srgbRed: 0.58, green: 0.78, blue: 1.00, alpha: 0.12)
    )
    ctx.strokePath()
    ctx.restoreGState()

    // Helper to draw a thick rounded gradient arc with elevation shadow
    func drawGradientArc(startDeg: CGFloat, endDeg: CGFloat, c1: CGColor, c2: CGColor) {
        let sRad = startDeg * .pi / 180.0
        let eRad = endDeg * .pi / 180.0

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.011),
            blur: size * 0.020,
            color: CGColor(gray: 0.0, alpha: isLight ? 0.16 : 0.45)
        )
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringRadius, startAngle: sRad, endAngle: eRad, clockwise: false)
        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(c1)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringRadius, startAngle: sRad, endAngle: eRad, clockwise: false)
        ctx.setLineWidth(ringWidth)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()

        let pStart = CGPoint(x: cx + ringRadius * cos(sRad), y: cy + ringRadius * sin(sRad))
        let pEnd = CGPoint(x: cx + ringRadius * cos(eRad), y: cy + ringRadius * sin(eRad))
        if let arcGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [c1, c2] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(
                arcGrad,
                start: pStart,
                end: pEnd,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()
    }

    // 5. Vector Backbone Arc (108° -> 342° CCW)
    let backboneC1 = isLight
        ? CGColor(srgbRed: 0.11, green: 0.39, blue: 0.95, alpha: 1.0)
        : CGColor(srgbRed: 0.22, green: 0.52, blue: 0.98, alpha: 1.0)
    let backboneC2 = isLight
        ? CGColor(srgbRed: 0.05, green: 0.65, blue: 0.91, alpha: 1.0)
        : CGColor(srgbRed: 0.22, green: 0.78, blue: 0.98, alpha: 1.0)
    drawGradientArc(startDeg: 108, endDeg: 342, c1: backboneC1, c2: backboneC2)

    // 6. Recombinant Insert Arc (Top-Right Quadrant, 12° -> 78° CCW)
    let insertC1 = isLight
        ? CGColor(srgbRed: 0.06, green: 0.73, blue: 0.51, alpha: 1.0)
        : CGColor(srgbRed: 0.20, green: 0.85, blue: 0.62, alpha: 1.0)
    let insertC2 = isLight
        ? CGColor(srgbRed: 0.02, green: 0.59, blue: 0.41, alpha: 1.0)
        : CGColor(srgbRed: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
    drawGradientArc(startDeg: 12, endDeg: 78, c1: insertC1, c2: insertC2)

    // 7. Two Minimalist Homology Junction Dots (-3° and +93°)
    let dotRadius = size * 0.015
    for deg in [-3.0, 93.0] {
        let rad = CGFloat(deg * .pi / 180.0)
        let dx = cx + ringRadius * cos(rad)
        let dy = cy + ringRadius * sin(rad)
        let dotRect = CGRect(x: dx - dotRadius, y: dy - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

        ctx.saveGState()
        ctx.setFillColor(
            isLight
                ? CGColor(srgbRed: 0.08, green: 0.62, blue: 0.88, alpha: 0.95)
                : CGColor(srgbRed: 0.35, green: 0.85, blue: 0.98, alpha: 0.95)
        )
        ctx.fillEllipse(in: dotRect)
        ctx.restoreGState()
    }

    // 8. Inner Squircle Specular Rim Border
    let insetRect = sqRect.insetBy(dx: size * 0.002, dy: size * 0.002)
    let rimPath = CGPath(roundedRect: insetRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(rimPath)
    ctx.setLineWidth(size * 0.004)
    ctx.setStrokeColor(
        isLight
            ? CGColor(srgbRed: 0.62, green: 0.71, blue: 0.84, alpha: 0.52)
            : CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
    )
    ctx.strokePath()

    ctx.restoreGState()
    return rep
}

func renderStatusBarTemplateIcon(pixelSize: Int) -> NSBitmapImageRep? {
    guard let (rep, ctx) = makeBitmapContext(pixelSize: pixelSize) else {
        return nil
    }
    let size = CGFloat(pixelSize)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let cx = size * 0.5
    let cy = size * 0.5
    let r = size * 0.34
    let lw = size * 0.135

    ctx.setStrokeColor(CGColor(gray: 0.0, alpha: 1.0))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)

    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 112 * .pi / 180, endAngle: 338 * .pi / 180, clockwise: false)
    ctx.strokePath()

    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 16 * .pi / 180, endAngle: 74 * .pi / 180, clockwise: false)
    ctx.strokePath()

    let dotR = size * 0.048
    ctx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
    for deg in [-3.0, 93.0] {
        let rad = CGFloat(deg * .pi / 180.0)
        let dx = cx + r * cos(rad)
        let dy = cy + r * sin(rad)
        ctx.fillEllipse(in: CGRect(x: dx - dotR, y: dy - dotR, width: dotR * 2, height: dotR * 2))
    }

    return rep
}

let args = CommandLine.arguments
let resDir = args.count > 1 ? args[1] : "."

if let dark1024 = renderPlasmidIcon(pixelSize: 1024, isLight: false) {
    saveRepPNG(dark1024, to: "\(resDir)/AppIcon_Dark_1024.png")
    saveRepPNG(dark1024, to: "\(resDir)/AppIcon_1024.png")
}
if let light1024 = renderPlasmidIcon(pixelSize: 1024, isLight: true) {
    saveRepPNG(light1024, to: "\(resDir)/AppIcon_Light_1024.png")
}

saveICNS(isLight: false, to: "\(resDir)/AppIcon_Dark.icns")
saveICNS(isLight: true, to: "\(resDir)/AppIcon_Light.icns")
saveICNS(isLight: false, to: "\(resDir)/AppIcon.icns")

if let status1x = renderStatusBarTemplateIcon(pixelSize: 18) {
    saveRepPNG(status1x, to: "\(resDir)/StatusBarIcon.png")
}
if let status2x = renderStatusBarTemplateIcon(pixelSize: 36) {
    saveRepPNG(status2x, to: "\(resDir)/StatusBarIcon@2x.png")
}
"""


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    res_dir = os.path.join(project_dir, "Sources", "CloneStudioCore", "Resources")
    os.makedirs(res_dir, exist_ok=True)

    print("🎨 Rendering Apple HIG-compliant Dark & Light plasmid icons...")
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
        f.write(SWIFT_ICON_RENDERER)
        swift_script = f.name

    try:
        subprocess.run(["/usr/bin/swift", swift_script, res_dir], check=True)
    finally:
        if os.path.exists(swift_script):
            os.remove(swift_script)

    print(f"✅ Compiled AppIcon_Light.icns, AppIcon_Dark.icns, AppIcon.icns & StatusBarIcon in: {res_dir}")


if __name__ == "__main__":
    main()
