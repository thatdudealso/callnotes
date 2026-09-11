#!/usr/bin/env swift
/// Rasterize the three CallNotes app-icon concepts and their menu-bar marks.
/// Source of truth is the SVG written next to each PNG; this file draws both
/// from the same geometry so 16pt proofs match the vector art.
///
/// Usage:
///   swift Scripts/render-app-icon-concepts.swift \
///     --out Resources/AppIcon \
///     --proof /path/to/firstmate/data/callnotes-app-icon-p1 \
///     --voices \
///     --catalog Resources/Assets.xcassets
///
/// `--catalog` writes only the shipped mark (diary-facing-voices).
/// The menu-bar SVG is independently authored from `drawVoiceMenuMark`.

import AppKit
import Foundation
import CoreGraphics

// MARK: - CLI

struct Args {
    var outDir: URL
    var proofDir: URL?
    var voicesOnly: Bool
    var catalogDir: URL?

    static func parse() -> Args {
        let argv = CommandLine.arguments
        var out = "Resources/AppIcon"
        var proof: String?
        var voices = false
        var catalog: String?
        var i = 1
        while i < argv.count {
            switch argv[i] {
            case "--out":
                i += 1
                out = argv[i]
            case "--proof":
                i += 1
                proof = argv[i]
            case "--voices":
                voices = true
            case "--catalog":
                i += 1
                catalog = argv[i]
            default:
                fputs("unknown argument \(argv[i])\n", stderr)
                exit(2)
            }
            i += 1
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return Args(
            outDir: URL(fileURLWithPath: out, relativeTo: cwd).absoluteURL,
            proofDir: proof.map { URL(fileURLWithPath: $0, relativeTo: cwd).absoluteURL },
            voicesOnly: voices,
            catalogDir: catalog.map { URL(fileURLWithPath: $0, relativeTo: cwd).absoluteURL }
        )
    }
}

// MARK: - Color

struct RGB {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat = 1

    init(_ r8: Int, _ g8: Int, _ b8: Int, _ a: CGFloat = 1) {
        r = CGFloat(r8) / 255
        g = CGFloat(g8) / 255
        b = CGFloat(b8) / 255
        self.a = a
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String {
        func byte(_ x: CGFloat) -> Int { Int((x * 255).rounded()) }
        if a < 1 {
            return String(format: "rgba(%d,%d,%d,%.3f)", byte(r), byte(g), byte(b), Double(a))
        }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

enum Palette {
    static let teal = RGB(14, 124, 123)
    static let tealDark = RGB(9, 78, 77)
    static let tealDeep = RGB(7, 48, 48)
    static let tealInk = RGB(12, 38, 38)
    static let paper = RGB(247, 241, 228)
    static let paperShadow = RGB(214, 200, 172)
    static let line = RGB(48, 92, 91)
    static let spine = RGB(186, 166, 132)
    static let pageEdge = RGB(255, 252, 245)
    static let record = RGB(214, 69, 69)
    static let menuLight = RGB(236, 236, 236)
    static let menuDark = RGB(40, 40, 42)
    static let menuLightGlyph = RGB(28, 28, 30)
    static let menuDarkGlyph = RGB(245, 245, 247)
}

// MARK: - Concepts

enum Concept: String, CaseIterable {
    case handsetOverPage = "handset-over-page"
    case notepadReceiver = "notepad-receiver"
    case diaryEmboss = "diary-emboss"

    var title: String {
        switch self {
        case .handsetOverPage: return "Handset over page"
        case .notepadReceiver: return "Notepad receiver"
        case .diaryEmboss: return "Diary emboss"
        }
    }

    var slug: String { rawValue }
}

/// Two-voice wave marks on the diary body. No phone glyph.
enum VoiceVariant: String, CaseIterable {
    case splitWaves = "diary-split-waves"
    case linedVoices = "diary-lined-voices"
    case facingVoices = "diary-facing-voices"

    var title: String {
        switch self {
        case .splitWaves: return "Split waves"
        case .linedVoices: return "Lined voices"
        case .facingVoices: return "Facing voices"
        }
    }

    var slug: String { rawValue }
}

enum Detail {
    case tiny   // 16pt: silhouette only
    case small  // 32pt: silhouette + 2 lines
    case full   // 128pt and up

    static func forSize(_ size: CGFloat) -> Detail {
        if size <= 20 { return .tiny }
        if size <= 40 { return .small }
        return .full
    }
}

// MARK: - Geometry helpers

func roundedRect(_ rect: CGRect, rx: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = min(rx, rect.width / 2, rect.height / 2)
    path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
    return path
}

func addSquircle(_ path: CGMutablePath, in rect: CGRect, n: CGFloat = 5) {
    let steps = 180
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
}

func squirclePath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    addSquircle(path, in: rect)
    return path
}

/// Classic telephone receiver: two earcups + a connecting bridge.
/// `earsDown` hangs the cups below the bridge (on a page). `false` points
/// them up so the bridge can sit on a notepad as a clip.
func handsetPath(in rect: CGRect, earsDown: Bool = true) -> CGPath {
    let path = CGMutablePath()
    let ear = min(rect.width * 0.32, rect.height * 0.86)
    let earR = ear * 0.48
    let leftY = earsDown ? rect.maxY - ear : rect.minY
    let rightY = leftY
    let left = CGRect(x: rect.minX, y: leftY, width: ear, height: ear)
    let right = CGRect(x: rect.maxX - ear, y: rightY, width: ear, height: ear)
    let bridgeH = rect.height * 0.56
    let bridgeY = earsDown ? rect.minY : rect.maxY - bridgeH
    let bridge = CGRect(
        x: rect.minX + ear * 0.32,
        y: bridgeY,
        width: rect.width - ear * 0.64,
        height: bridgeH
    )
    let bridgeR = bridgeH * 0.48
    path.addRoundedRect(in: left, cornerWidth: earR, cornerHeight: earR)
    path.addRoundedRect(in: right, cornerWidth: earR, cornerHeight: earR)
    path.addRoundedRect(in: bridge, cornerWidth: bridgeR, cornerHeight: bridgeR)
    return path
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: RGB) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(color.cg)
    ctx.fillPath()
    ctx.restoreGState()
}

func stroke(_ ctx: CGContext, _ path: CGPath, _ color: RGB, width: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color.cg)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - App-icon drawings (1024 design space, scaled)

func drawBackground(_ ctx: CGContext, size: CGFloat, top: RGB, bottom: RGB) {
    let colors = [top.cg, bottom.cg] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: size * 0.2, y: 0),
        end: CGPoint(x: size * 0.8, y: size),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func scaleRect(_ r: CGRect, _ size: CGFloat) -> CGRect {
    CGRect(
        x: r.origin.x / 1024 * size,
        y: r.origin.y / 1024 * size,
        width: r.size.width / 1024 * size,
        height: r.size.height / 1024 * size
    )
}

func drawHandsetOverPage(_ ctx: CGContext, size: CGFloat, detail: Detail) {
    drawBackground(ctx, size: size, top: RGB(18, 148, 146), bottom: Palette.tealDark)

    let page = scaleRect(CGRect(x: 214, y: 188, width: 596, height: 676), size)
    let pageR = 64 / 1024 * size
    fill(ctx, roundedRect(page, rx: pageR), Palette.paper)

    if detail != .tiny {
        let shadow = scaleRect(CGRect(x: 214, y: 820, width: 596, height: 44), size)
        fill(ctx, roundedRect(shadow, rx: 16 / 1024 * size), RGB(14, 124, 123, 0.10))
    }

    let lineCount = detail == .full ? 4 : (detail == .small ? 2 : 0)
    if lineCount > 0 {
        let ys: [CGFloat] = detail == .full ? [548, 628, 708, 788] : [640, 740]
        let widths: [CGFloat] = detail == .full ? [452, 452, 452, 280] : [400, 260]
        let thickness = max(6 / 1024 * size, detail == .small ? 2.0 : 10 / 1024 * size)
        for (index, y) in ys.prefix(lineCount).enumerated() {
            let w = widths[index]
            let rect = scaleRect(CGRect(x: 286, y: y, width: w, height: 20), size)
            let lineRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness)
            fill(ctx, roundedRect(lineRect, rx: thickness / 2), Palette.line)
        }
    }

    let handset = scaleRect(CGRect(x: 268, y: 248, width: 488, height: 236), size)
    fill(ctx, handsetPath(in: handset), Palette.tealInk)

    if size >= 256 {
        let holeY = 338 / 1024 * size
        let holeH = 96 / 1024 * size
        let holeW = 72 / 1024 * size
        let leftHole = CGRect(x: 300 / 1024 * size, y: holeY, width: holeW, height: holeH)
        let rightHole = CGRect(x: 652 / 1024 * size, y: holeY, width: holeW, height: holeH)
        fill(ctx, roundedRect(leftHole, rx: holeW * 0.45), Palette.paper)
        fill(ctx, roundedRect(rightHole, rx: holeW * 0.45), Palette.paper)
    }
}

func drawNotepadReceiver(_ ctx: CGContext, size: CGFloat, detail: Detail) {
    drawBackground(ctx, size: size, top: RGB(16, 138, 136), bottom: Palette.tealDark)

    // Cream pad. The receiver sits on the top edge as a clip, ears pointing
    // up, so it cannot collapse into a face at 16/32pt.
    let body = scaleRect(CGRect(x: 196, y: 360, width: 632, height: 508), size)
    let bodyR = 56 / 1024 * size
    fill(ctx, roundedRect(body, rx: bodyR), Palette.paper)

    // Receiver rests on the pad as its header, cups hanging onto the page.
    let clip = scaleRect(CGRect(x: 236, y: 168, width: 552, height: 268), size)
    fill(ctx, handsetPath(in: clip, earsDown: true), Palette.tealInk)

    if detail != .tiny {
        let ringCount = detail == .full ? 5 : 3
        let ringR = (detail == .full ? 15 : 9) / 1024 * size
        let y = 456 / 1024 * size
        let x0 = 330 / 1024 * size
        let x1 = 694 / 1024 * size
        for i in 0..<ringCount {
            let t = ringCount == 1 ? 0.5 : CGFloat(i) / CGFloat(ringCount - 1)
            let x = x0 + (x1 - x0) * t
            let rect = CGRect(x: x - ringR, y: y - ringR, width: ringR * 2, height: ringR * 2)
            fill(ctx, CGPath(ellipseIn: rect, transform: nil), Palette.tealDark)
        }
    }

    let lineCount = detail == .tiny ? 0 : (detail == .small ? 2 : 3)
    if lineCount > 0 {
        let ys: [CGFloat] = [520, 620, 720]
        let widths: [CGFloat] = [472, 472, 300]
        let thickness = max(6 / 1024 * size, detail == .small ? 2.0 : 12 / 1024 * size)
        for i in 0..<lineCount {
            let rect = scaleRect(CGRect(x: 276, y: ys[i], width: widths[i], height: 22), size)
            let lineRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness)
            fill(ctx, roundedRect(lineRect, rx: thickness / 2), Palette.line)
        }
    }
}

func drawDiaryEmboss(_ ctx: CGContext, size: CGFloat, detail: Detail) {
    drawBackground(ctx, size: size, top: RGB(16, 138, 136), bottom: Palette.tealDark)

    let cover = scaleRect(CGRect(x: 196, y: 156, width: 600, height: 712), size)
    let coverR = 52 / 1024 * size
    fill(ctx, roundedRect(cover, rx: coverR), Palette.paper)

    let spine = scaleRect(CGRect(x: 196, y: 156, width: 88, height: 712), size)
    let spinePath = CGMutablePath()
    spinePath.move(to: CGPoint(x: spine.minX + coverR, y: spine.minY))
    spinePath.addLine(to: CGPoint(x: spine.maxX, y: spine.minY))
    spinePath.addLine(to: CGPoint(x: spine.maxX, y: spine.maxY))
    spinePath.addLine(to: CGPoint(x: spine.minX + coverR, y: spine.maxY))
    spinePath.addQuadCurve(
        to: CGPoint(x: spine.minX, y: spine.maxY - coverR),
        control: CGPoint(x: spine.minX, y: spine.maxY)
    )
    spinePath.addLine(to: CGPoint(x: spine.minX, y: spine.minY + coverR))
    spinePath.addQuadCurve(
        to: CGPoint(x: spine.minX + coverR, y: spine.minY),
        control: CGPoint(x: spine.minX, y: spine.minY)
    )
    spinePath.closeSubpath()
    fill(ctx, spinePath, Palette.spine)

    if detail == .full {
        for t in [0.22, 0.50, 0.78] as [CGFloat] {
            let y = spine.minY + spine.height * t
            let rib = CGRect(x: spine.minX + 14 / 1024 * size, y: y - 4 / 1024 * size, width: spine.width - 28 / 1024 * size, height: 8 / 1024 * size)
            fill(ctx, roundedRect(rib, rx: 3 / 1024 * size), RGB(160, 140, 108))
        }
    }

    if detail != .tiny {
        let edgeX: [CGFloat] = [808, 828, 848]
        for (i, x) in edgeX.enumerated() {
            let inset: CGFloat = CGFloat(i) * 6
            let edge = scaleRect(CGRect(x: x, y: 176 + inset, width: 16, height: 672 - inset * 2), size)
            fill(ctx, roundedRect(edge, rx: 6 / 1024 * size), Palette.pageEdge)
        }
    }

    let phone = scaleRect(CGRect(x: 360, y: 268, width: 360, height: 196), size)
    fill(ctx, handsetPath(in: phone), Palette.tealInk)

    let lineCount = detail == .tiny ? 0 : (detail == .small ? 2 : 3)
    if lineCount > 0 {
        let ys: [CGFloat] = [520, 600, 680]
        let widths: [CGFloat] = [300, 300, 200]
        let thickness = max(6 / 1024 * size, detail == .small ? 2.0 : 12 / 1024 * size)
        for i in 0..<lineCount {
            let rect = scaleRect(CGRect(x: 360, y: ys[i], width: widths[i], height: 22), size)
            let lineRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness)
            fill(ctx, roundedRect(lineRect, rx: thickness / 2), Palette.line)
        }
    }
}

// MARK: - Closed diary body (no cover stamp)

func drawClosedDiaryBody(_ ctx: CGContext, size: CGFloat, detail: Detail) -> (cover: CGRect, content: CGRect) {
    drawBackground(ctx, size: size, top: RGB(16, 138, 136), bottom: Palette.tealDark)

    let cover = scaleRect(CGRect(x: 196, y: 156, width: 600, height: 712), size)
    let coverR = 52 / 1024 * size
    fill(ctx, roundedRect(cover, rx: coverR), Palette.paper)

    let spine = scaleRect(CGRect(x: 196, y: 156, width: 88, height: 712), size)
    let spinePath = CGMutablePath()
    spinePath.move(to: CGPoint(x: spine.minX + coverR, y: spine.minY))
    spinePath.addLine(to: CGPoint(x: spine.maxX, y: spine.minY))
    spinePath.addLine(to: CGPoint(x: spine.maxX, y: spine.maxY))
    spinePath.addLine(to: CGPoint(x: spine.minX + coverR, y: spine.maxY))
    spinePath.addQuadCurve(
        to: CGPoint(x: spine.minX, y: spine.maxY - coverR),
        control: CGPoint(x: spine.minX, y: spine.maxY)
    )
    spinePath.addLine(to: CGPoint(x: spine.minX, y: spine.minY + coverR))
    spinePath.addQuadCurve(
        to: CGPoint(x: spine.minX + coverR, y: spine.minY),
        control: CGPoint(x: spine.minX, y: spine.minY)
    )
    spinePath.closeSubpath()
    fill(ctx, spinePath, Palette.spine)

    if detail == .full {
        for t in [0.22, 0.50, 0.78] as [CGFloat] {
            let y = spine.minY + spine.height * t
            let rib = CGRect(x: spine.minX + 14 / 1024 * size, y: y - 4 / 1024 * size, width: spine.width - 28 / 1024 * size, height: 8 / 1024 * size)
            fill(ctx, roundedRect(rib, rx: 3 / 1024 * size), RGB(160, 140, 108))
        }
    }

    if detail != .tiny {
        let edgeX: [CGFloat] = [808, 828, 848]
        for (i, x) in edgeX.enumerated() {
            let inset: CGFloat = CGFloat(i) * 6
            let edge = scaleRect(CGRect(x: x, y: 176 + inset, width: 16, height: 672 - inset * 2), size)
            fill(ctx, roundedRect(edge, rx: 6 / 1024 * size), Palette.pageEdge)
        }
    }

    let content = CGRect(
        x: cover.minX + cover.width * 0.22,
        y: cover.minY + cover.height * 0.14,
        width: cover.width * 0.68,
        height: cover.height * 0.72
    )
    return (cover, content)
}

/// One voice: a sine whose amplitude changes per syllable so two voices
/// cannot collapse into one repeating clip.
func waveformPath(centerY: CGFloat, x0: CGFloat, width: CGFloat, height: CGFloat, amps: [CGFloat], invert: Bool) -> CGPath {
    let path = CGMutablePath()
    let n = max(amps.count, 1)
    let samples = max(28, n * 14)
    let sign: CGFloat = invert ? -1 : 1
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples)
        let x = x0 + t * width
        let idx = min(Int(floor(t * CGFloat(n))), n - 1)
        let local = t * CGFloat(n) - CGFloat(idx)
        let a = amps[idx]
        let y = centerY - sign * sin(local * .pi) * height * a
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    return path
}

func strokeWave(_ ctx: CGContext, _ path: CGPath, _ color: RGB, width: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color.cg)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Voice A: fewer, punchier peaks. Voice B: more syllables, different rhythm.
let voiceAAmps: [CGFloat] = [1.00, 0.40, 0.82]
let voiceBAmps: [CGFloat] = [0.38, 0.72, 0.48, 0.95, 0.42]
let voiceATiny: [CGFloat] = [1.00, 0.45]
let voiceBTiny: [CGFloat] = [0.40, 0.95, 0.50]

func drawSplitWaves(_ ctx: CGContext, size: CGFloat, detail: Detail) {
    let body = drawClosedDiaryBody(ctx, size: size, detail: detail)
    let box = body.content
    let waveH = detail == .tiny ? box.height * 0.22 : box.height * 0.18
    let thick = max(size * 0.018, detail == .tiny ? 1.6 : 10 / 1024 * size)
    let aAmps = detail == .tiny ? voiceATiny : voiceAAmps
    let bAmps = detail == .tiny ? voiceBTiny : voiceBAmps
    let midY = box.midY
    if detail != .tiny {
        ctx.saveGState()
        ctx.setStrokeColor(Palette.line.cg)
        ctx.setLineWidth(max(2, size * 0.008))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: box.minX, y: midY))
        ctx.addLine(to: CGPoint(x: box.maxX, y: midY))
        ctx.strokePath()
        ctx.restoreGState()
    }
    let top = waveformPath(centerY: midY - box.height * 0.22, x0: box.minX, width: box.width, height: waveH, amps: aAmps, invert: false)
    let bot = waveformPath(centerY: midY + box.height * 0.22, x0: box.minX, width: box.width, height: waveH, amps: bAmps, invert: true)
    strokeWave(ctx, top, Palette.tealInk, width: thick)
    strokeWave(ctx, bot, Palette.line, width: thick)
}

func drawLinedVoices(_ ctx: CGContext, size: CGFloat, detail: Detail) {
    drawBackground(ctx, size: size, top: RGB(16, 138, 136), bottom: Palette.tealDark)
    let left = scaleRect(CGRect(x: 140, y: 180, width: 372, height: 664), size)
    let right = scaleRect(CGRect(x: 512, y: 180, width: 372, height: 664), size)
    let pageR = 40 / 1024 * size
    fill(ctx, roundedRect(left, rx: pageR), Palette.paper)
    fill(ctx, roundedRect(right, rx: pageR), Palette.paper)
    let gutter = scaleRect(CGRect(x: 500, y: 180, width: 24, height: 664), size)
    fill(ctx, roundedRect(gutter, rx: 8 / 1024 * size), Palette.spine)

    let thick = max(size * 0.018, detail == .tiny ? 1.7 : 12 / 1024 * size)
    let aAmps = detail == .tiny ? voiceATiny : voiceAAmps
    let bAmps = detail == .tiny ? voiceBTiny : voiceBAmps
    let inset: CGFloat = left.width * 0.14
    let leftBox = left.insetBy(dx: inset, dy: left.height * 0.18)
    let rightBox = right.insetBy(dx: inset, dy: right.height * 0.18)
    let waveH = detail == .tiny ? leftBox.height * 0.28 : leftBox.height * 0.16
    let leftWave = waveformPath(
        centerY: leftBox.midY - (detail == .tiny ? 0 : leftBox.height * 0.12),
        x0: leftBox.minX, width: leftBox.width, height: waveH, amps: aAmps, invert: false
    )
    let rightWave = waveformPath(
        centerY: rightBox.midY + (detail == .tiny ? 0 : rightBox.height * 0.12),
        x0: rightBox.minX, width: rightBox.width, height: waveH, amps: bAmps, invert: true
    )
    strokeWave(ctx, leftWave, Palette.tealInk, width: thick)
    strokeWave(ctx, rightWave, Palette.line, width: thick)
    if detail == .full {
        let left2 = waveformPath(centerY: leftBox.midY + leftBox.height * 0.22, x0: leftBox.minX, width: leftBox.width * 0.72, height: waveH * 0.7, amps: [0.7, 0.35], invert: false)
        let right2 = waveformPath(centerY: rightBox.midY - rightBox.height * 0.22, x0: rightBox.minX, width: rightBox.width * 0.78, height: waveH * 0.7, amps: [0.4, 0.8, 0.45], invert: true)
        strokeWave(ctx, left2, Palette.line, width: thick * 0.7)
        strokeWave(ctx, right2, Palette.tealInk, width: thick * 0.7)
    }
}

func drawFacingArcs(
    _ ctx: CGContext,
    origin: CGPoint,
    radii: [CGFloat],
    facingRight: Bool,
    color: RGB,
    width: CGFloat,
    openness: CGFloat
) {
    ctx.saveGState()
    ctx.setStrokeColor(color.cg)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    let start: CGFloat = facingRight ? -.pi * openness : .pi * (1 - openness)
    let end: CGFloat = facingRight ? .pi * openness : .pi * (1 + openness)
    for r in radii {
        ctx.addArc(center: origin, radius: r, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func drawFacingVoices(_ ctx: CGContext, size: CGFloat, detail: Detail) {
    let body = drawClosedDiaryBody(ctx, size: size, detail: detail)
    let box = body.content
    // Two heavy rings per voice. Asymmetry is spacing + aperture, not ring count.
    let thick: CGFloat
    switch detail {
    case .tiny: thick = max(2.3, size * 0.14)
    case .small: thick = max(2.6, size * 0.085)
    case .full: thick = max(12 / 1024 * size, size * 0.028)
    }
    let leftOrigin = CGPoint(x: box.minX + box.width * 0.10, y: box.midY)
    let rightOrigin = CGPoint(x: box.maxX - box.width * 0.10, y: box.midY)
    let span = box.width * (detail == .tiny ? 0.28 : 0.32)
    // Left: compact pair. Right: larger outer ring and more air between rings.
    let leftRadii = [span * 0.38, span * 0.82]
    let rightRadii = [span * 0.50, span * 1.12]
    if detail == .full {
        fill(ctx, CGPath(ellipseIn: CGRect(x: leftOrigin.x - thick * 0.55, y: leftOrigin.y - thick * 0.55, width: thick * 1.1, height: thick * 1.1), transform: nil), Palette.tealInk)
        fill(ctx, CGPath(ellipseIn: CGRect(x: rightOrigin.x - thick * 0.45, y: rightOrigin.y - thick * 0.45, width: thick * 0.9, height: thick * 0.9), transform: nil), Palette.line)
    }
    drawFacingArcs(ctx, origin: leftOrigin, radii: leftRadii, facingRight: true, color: Palette.tealInk, width: thick, openness: 0.36)
    drawFacingArcs(ctx, origin: rightOrigin, radii: rightRadii, facingRight: false, color: Palette.line, width: thick * 0.88, openness: 0.48)
}

func drawVoiceVariant(_ variant: VoiceVariant, ctx: CGContext, size: CGFloat, clipSquircle: Bool) {
    ctx.saveGState()
    if clipSquircle {
        ctx.addPath(squirclePath(in: CGRect(x: 0, y: 0, width: size, height: size)))
        ctx.clip()
    }
    let detail = Detail.forSize(size)
    switch variant {
    case .splitWaves: drawSplitWaves(ctx, size: size, detail: detail)
    case .linedVoices: drawLinedVoices(ctx, size: size, detail: detail)
    case .facingVoices: drawFacingVoices(ctx, size: size, detail: detail)
    }
    ctx.restoreGState()
}

func renderVoiceIcon(_ variant: VoiceVariant, size: Int, squircle: Bool) -> Data {
    let ctx = makeContext(width: size, height: size, opaque: !squircle)
    drawVoiceVariant(variant, ctx: ctx, size: CGFloat(size), clipSquircle: squircle)
    return pngData(from: ctx)
}

func renderVoiceCatalogGlyph(variant: VoiceVariant, state: MenuState, size: Int, color: RGB, template: Bool) -> Data {
    let ctx = makeContext(width: size, height: size)
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawVoiceMenuMark(variant, ctx: ctx, size: CGFloat(size), color: color, state: state, template: template)
    return pngData(from: ctx)
}

func drawConcept(_ concept: Concept, ctx: CGContext, size: CGFloat, clipSquircle: Bool) {
    ctx.saveGState()
    if clipSquircle {
        ctx.addPath(squirclePath(in: CGRect(x: 0, y: 0, width: size, height: size)))
        ctx.clip()
    }
    let detail = Detail.forSize(size)
    switch concept {
    case .handsetOverPage: drawHandsetOverPage(ctx, size: size, detail: detail)
    case .notepadReceiver: drawNotepadReceiver(ctx, size: size, detail: detail)
    case .diaryEmboss: drawDiaryEmboss(ctx, size: size, detail: detail)
    }
    ctx.restoreGState()
}

// MARK: - Menu-bar marks (template glyphs, same identity)

enum MenuState: String {
    case idle
    case armed
    case recording
    case processing
}

func drawMenuMark(_ concept: Concept, ctx: CGContext, size: CGFloat, color: RGB, state: MenuState) {
    let inset = size * 0.06
    let canvas = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let filled = state != .idle
    let lineW = max(1.35, size * 0.085)

    switch concept {
    case .handsetOverPage:
        let page = canvas.insetBy(dx: canvas.width * 0.12, dy: canvas.height * 0.06)
        let pagePath = roundedRect(page, rx: page.width * 0.12)
        let hs = CGRect(
            x: page.minX + page.width * 0.10,
            y: page.minY + page.height * 0.10,
            width: page.width * 0.80,
            height: page.height * 0.38
        )
        let hsPath = handsetPath(in: hs)
        if filled {
            fill(ctx, pagePath, color)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            stroke(ctx, hsPath, RGB(0, 0, 0), width: max(1.6, lineW * 1.15))
            let ys = [page.minY + page.height * 0.62, page.minY + page.height * 0.76]
            for (i, y) in ys.enumerated() {
                let w = page.width * (i == 1 ? 0.46 : 0.68)
                let line = CGRect(x: page.minX + page.width * 0.16, y: y, width: w, height: max(1.2, size * 0.06))
                fill(ctx, roundedRect(line, rx: line.height / 2), RGB(0, 0, 0))
            }
            ctx.restoreGState()
        } else {
            stroke(ctx, pagePath, color, width: lineW)
            stroke(ctx, hsPath, color, width: lineW)
        }

    case .notepadReceiver:
        let body = CGRect(
            x: canvas.minX + canvas.width * 0.12,
            y: canvas.minY + canvas.height * 0.34,
            width: canvas.width * 0.76,
            height: canvas.height * 0.58
        )
        let clip = CGRect(
            x: canvas.minX + canvas.width * 0.16,
            y: canvas.minY + canvas.height * 0.02,
            width: canvas.width * 0.68,
            height: canvas.height * 0.42
        )
        if filled {
            fill(ctx, roundedRect(body, rx: body.width * 0.12), color)
            fill(ctx, handsetPath(in: clip, earsDown: true), color)
            let line = CGRect(
                x: body.minX + body.width * 0.16,
                y: body.minY + body.height * 0.52,
                width: body.width * 0.58,
                height: max(1.2, size * 0.06)
            )
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            fill(ctx, roundedRect(line, rx: line.height / 2), RGB(0, 0, 0))
            ctx.restoreGState()
        } else {
            stroke(ctx, roundedRect(body, rx: body.width * 0.12), color, width: lineW)
            stroke(ctx, handsetPath(in: clip, earsDown: true), color, width: lineW)
        }

    case .diaryEmboss:
        let cover = canvas.insetBy(dx: canvas.width * 0.10, dy: canvas.height * 0.06)
        let coverPath = roundedRect(cover, rx: cover.width * 0.12)
        if filled {
            fill(ctx, coverPath, color)
        } else {
            stroke(ctx, coverPath, color, width: lineW)
        }
        let spineW = cover.width * 0.16
        let spine = CGRect(x: cover.minX, y: cover.minY, width: spineW, height: cover.height)
        if filled {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            let punch = CGRect(x: spine.maxX - max(1.1, size * 0.05), y: cover.minY + cover.height * 0.08, width: max(1.1, size * 0.05), height: cover.height * 0.84)
            fill(ctx, roundedRect(punch, rx: punch.width / 2), RGB(0, 0, 0))
            ctx.restoreGState()
        } else {
            let x = cover.minX + spineW
            ctx.saveGState()
            ctx.setStrokeColor(color.cg)
            ctx.setLineWidth(lineW)
            ctx.move(to: CGPoint(x: x, y: cover.minY + lineW))
            ctx.addLine(to: CGPoint(x: x, y: cover.maxY - lineW))
            ctx.strokePath()
            ctx.restoreGState()
        }
        let hs = CGRect(
            x: cover.minX + cover.width * 0.28,
            y: cover.minY + cover.height * 0.16,
            width: cover.width * 0.58,
            height: cover.height * 0.34
        )
        if filled {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            fill(ctx, handsetPath(in: hs), RGB(0, 0, 0))
            ctx.restoreGState()
        } else {
            stroke(ctx, handsetPath(in: hs), color, width: lineW)
        }
    }

    switch state {
    case .idle, .armed:
        break
    case .recording:
        let d = size * 0.28
        let badge = CGRect(x: size - d - size * 0.02, y: size - d - size * 0.02, width: d, height: d)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        fill(ctx, CGPath(ellipseIn: badge.insetBy(dx: -size * 0.04, dy: -size * 0.04), transform: nil), RGB(0, 0, 0))
        ctx.restoreGState()
        fill(ctx, CGPath(ellipseIn: badge, transform: nil), Palette.record)
        let inner = badge.insetBy(dx: d * 0.28, dy: d * 0.28)
        fill(ctx, CGPath(ellipseIn: inner, transform: nil), RGB(255, 252, 250))
    case .processing:
        let d = size * 0.30
        let badge = CGRect(x: size - d - size * 0.02, y: size - d - size * 0.02, width: d, height: d)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        fill(ctx, CGPath(ellipseIn: badge.insetBy(dx: -size * 0.04, dy: -size * 0.04), transform: nil), RGB(0, 0, 0))
        ctx.restoreGState()
        fill(ctx, CGPath(ellipseIn: badge, transform: nil), color)
        ctx.saveGState()
        ctx.setStrokeColor(RGB(255, 252, 250).cg)
        ctx.setLineWidth(max(1.2, size * 0.07))
        ctx.setLineCap(.round)
        ctx.addArc(
            center: CGPoint(x: badge.midX, y: badge.midY),
            radius: d * 0.28,
            startAngle: -.pi * 0.15,
            endAngle: .pi * 1.15,
            clockwise: false
        )
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func drawVoiceMenuMark(_ variant: VoiceVariant, ctx: CGContext, size: CGFloat, color: RGB, state: MenuState, template: Bool = false) {
    let inset = size * 0.06
    let canvas = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let filled = state != .idle
    let lineW = max(1.35, size * 0.085)
    let waveW = max(1.4, size * 0.09)

    switch variant {
    case .splitWaves:
        let cover = canvas.insetBy(dx: canvas.width * 0.10, dy: canvas.height * 0.06)
        let coverPath = roundedRect(cover, rx: cover.width * 0.12)
        let spineX = cover.minX + cover.width * 0.16
        if filled {
            fill(ctx, coverPath, color)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            let punch = CGRect(x: spineX - max(1.1, size * 0.04), y: cover.minY + cover.height * 0.08, width: max(1.1, size * 0.05), height: cover.height * 0.84)
            fill(ctx, roundedRect(punch, rx: punch.width / 2), RGB(0, 0, 0))
            let box = CGRect(x: cover.minX + cover.width * 0.26, y: cover.minY + cover.height * 0.18, width: cover.width * 0.62, height: cover.height * 0.64)
            let top = waveformPath(centerY: box.midY - box.height * 0.22, x0: box.minX, width: box.width, height: box.height * 0.18, amps: voiceATiny, invert: false)
            let bot = waveformPath(centerY: box.midY + box.height * 0.22, x0: box.minX, width: box.width, height: box.height * 0.18, amps: voiceBTiny, invert: true)
            strokeWave(ctx, top, RGB(0, 0, 0), width: waveW)
            strokeWave(ctx, bot, RGB(0, 0, 0), width: waveW)
            ctx.setLineWidth(max(1.1, size * 0.05))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: box.minX, y: box.midY))
            ctx.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            stroke(ctx, coverPath, color, width: lineW)
            ctx.saveGState()
            ctx.setStrokeColor(color.cg)
            ctx.setLineWidth(lineW)
            ctx.move(to: CGPoint(x: spineX, y: cover.minY + lineW))
            ctx.addLine(to: CGPoint(x: spineX, y: cover.maxY - lineW))
            ctx.strokePath()
            ctx.restoreGState()
            let box = CGRect(x: cover.minX + cover.width * 0.26, y: cover.minY + cover.height * 0.18, width: cover.width * 0.62, height: cover.height * 0.64)
            let top = waveformPath(centerY: box.midY - box.height * 0.22, x0: box.minX, width: box.width, height: box.height * 0.18, amps: voiceATiny, invert: false)
            let bot = waveformPath(centerY: box.midY + box.height * 0.22, x0: box.minX, width: box.width, height: box.height * 0.18, amps: voiceBTiny, invert: true)
            strokeWave(ctx, top, color, width: waveW)
            strokeWave(ctx, bot, color, width: waveW)
        }

    case .linedVoices:
        let left = CGRect(x: canvas.minX, y: canvas.minY + canvas.height * 0.08, width: canvas.width * 0.46, height: canvas.height * 0.84)
        let right = CGRect(x: canvas.midX + canvas.width * 0.02, y: canvas.minY + canvas.height * 0.08, width: canvas.width * 0.46, height: canvas.height * 0.84)
        if filled {
            fill(ctx, roundedRect(left, rx: left.width * 0.14), color)
            fill(ctx, roundedRect(right, rx: right.width * 0.14), color)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            let lWave = waveformPath(centerY: left.midY, x0: left.minX + left.width * 0.14, width: left.width * 0.72, height: left.height * 0.16, amps: voiceATiny, invert: false)
            let rWave = waveformPath(centerY: right.midY, x0: right.minX + right.width * 0.14, width: right.width * 0.72, height: right.height * 0.16, amps: voiceBTiny, invert: true)
            strokeWave(ctx, lWave, RGB(0, 0, 0), width: waveW)
            strokeWave(ctx, rWave, RGB(0, 0, 0), width: waveW)
            ctx.restoreGState()
        } else {
            stroke(ctx, roundedRect(left, rx: left.width * 0.14), color, width: lineW)
            stroke(ctx, roundedRect(right, rx: right.width * 0.14), color, width: lineW)
            let lWave = waveformPath(centerY: left.midY, x0: left.minX + left.width * 0.14, width: left.width * 0.72, height: left.height * 0.16, amps: voiceATiny, invert: false)
            let rWave = waveformPath(centerY: right.midY, x0: right.minX + right.width * 0.14, width: right.width * 0.72, height: right.height * 0.16, amps: voiceBTiny, invert: true)
            strokeWave(ctx, lWave, color, width: waveW)
            strokeWave(ctx, rWave, color, width: waveW)
        }

    case .facingVoices:
        let cover = canvas.insetBy(dx: canvas.width * 0.10, dy: canvas.height * 0.06)
        let coverPath = roundedRect(cover, rx: cover.width * 0.12)
        let spineX = cover.minX + cover.width * 0.16
        if filled {
            fill(ctx, coverPath, color)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            let punch = CGRect(x: spineX - max(1.1, size * 0.04), y: cover.minY + cover.height * 0.08, width: max(1.1, size * 0.05), height: cover.height * 0.84)
            fill(ctx, roundedRect(punch, rx: punch.width / 2), RGB(0, 0, 0))
            let leftO = CGPoint(x: cover.minX + cover.width * 0.30, y: cover.midY)
            let rightO = CGPoint(x: cover.maxX - cover.width * 0.10, y: cover.midY)
            let span = cover.width * 0.20
            drawFacingArcs(ctx, origin: leftO, radii: [span * 0.38, span * 0.82], facingRight: true, color: RGB(0, 0, 0), width: max(2.2, waveW * 1.35), openness: 0.36)
            drawFacingArcs(ctx, origin: rightO, radii: [span * 0.50, span * 1.12], facingRight: false, color: RGB(0, 0, 0), width: max(1.9, waveW * 1.15), openness: 0.48)
            ctx.restoreGState()
        } else {
            stroke(ctx, coverPath, color, width: lineW)
            ctx.saveGState()
            ctx.setStrokeColor(color.cg)
            ctx.setLineWidth(lineW)
            ctx.move(to: CGPoint(x: spineX, y: cover.minY + lineW))
            ctx.addLine(to: CGPoint(x: spineX, y: cover.maxY - lineW))
            ctx.strokePath()
            ctx.restoreGState()
            let leftO = CGPoint(x: cover.minX + cover.width * 0.30, y: cover.midY)
            let rightO = CGPoint(x: cover.maxX - cover.width * 0.10, y: cover.midY)
            let span = cover.width * 0.20
            drawFacingArcs(ctx, origin: leftO, radii: [span * 0.38, span * 0.82], facingRight: true, color: color, width: max(2.2, waveW * 1.35), openness: 0.36)
            drawFacingArcs(ctx, origin: rightO, radii: [span * 0.50, span * 1.12], facingRight: false, color: color, width: max(1.9, waveW * 1.15), openness: 0.48)
        }
    }

    switch state {
    case .idle, .armed:
        break
    case .recording:
        let d = size * 0.28
        let badge = CGRect(x: size - d - size * 0.02, y: size - d - size * 0.02, width: d, height: d)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        fill(ctx, CGPath(ellipseIn: badge.insetBy(dx: -size * 0.04, dy: -size * 0.04), transform: nil), RGB(0, 0, 0))
        ctx.restoreGState()
        fill(ctx, CGPath(ellipseIn: badge, transform: nil), Palette.record)
        let inner = badge.insetBy(dx: d * 0.28, dy: d * 0.28)
        fill(ctx, CGPath(ellipseIn: inner, transform: nil), RGB(255, 252, 250))
    case .processing:
        let d = size * 0.30
        let badge = CGRect(x: size - d - size * 0.02, y: size - d - size * 0.02, width: d, height: d)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        fill(ctx, CGPath(ellipseIn: badge.insetBy(dx: -size * 0.04, dy: -size * 0.04), transform: nil), RGB(0, 0, 0))
        ctx.restoreGState()
        fill(ctx, CGPath(ellipseIn: badge, transform: nil), color)
        ctx.saveGState()
        if template {
            ctx.setBlendMode(.clear)
            ctx.setStrokeColor(RGB(0, 0, 0).cg)
        } else {
            ctx.setStrokeColor(RGB(255, 252, 250).cg)
        }
        ctx.setLineWidth(max(1.2, size * 0.07))
        ctx.setLineCap(.round)
        ctx.addArc(
            center: CGPoint(x: badge.midX, y: badge.midY),
            radius: d * 0.28,
            startAngle: -.pi * 0.15,
            endAngle: .pi * 1.15,
            clockwise: false
        )
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func renderVoiceMenuBar(variant: VoiceVariant, state: MenuState, dark: Bool, glyphPt: CGFloat, barWidth: Int, barHeight: Int) -> Data {
    let ctx = makeContext(width: barWidth, height: barHeight)
    let bg = dark ? Palette.menuDark : Palette.menuLight
    ctx.setFillColor(bg.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: barWidth, height: barHeight))
    let glyphPx = Int((glyphPt * 2).rounded())
    ctx.saveGState()
    let x = CGFloat(barWidth - glyphPx) / 2
    let y = CGFloat(barHeight - glyphPx) / 2
    ctx.translateBy(x: x, y: y)
    let color = dark ? Palette.menuDarkGlyph : Palette.menuLightGlyph
    drawVoiceMenuMark(variant, ctx: ctx, size: CGFloat(glyphPx), color: color, state: state)
    ctx.restoreGState()
    return pngData(from: ctx)
}

func renderVoiceGlyph(variant: VoiceVariant, state: MenuState, size: Int, dark: Bool) -> Data {
    let ctx = makeContext(width: size, height: size)
    let bg = dark ? Palette.menuDark : Palette.menuLight
    ctx.setFillColor(bg.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let color = dark ? Palette.menuDarkGlyph : Palette.menuLightGlyph
    drawVoiceMenuMark(variant, ctx: ctx, size: CGFloat(size), color: color, state: state)
    return pngData(from: ctx)
}

// MARK: - SVG export

func svgHandset(rect: CGRect, fill hex: String, earsDown: Bool = true) -> String {
    let ear = min(rect.width * 0.32, rect.height * 0.86)
    let earR = ear * 0.48
    let leftY = earsDown ? rect.minY + rect.height - ear : rect.minY
    let left = CGRect(x: rect.minX, y: leftY, width: ear, height: ear)
    let right = CGRect(x: rect.maxX - ear, y: leftY, width: ear, height: ear)
    let bridgeH = rect.height * 0.56
    let bridgeY = earsDown ? rect.minY : rect.minY + rect.height - bridgeH
    let bridge = CGRect(
        x: rect.minX + ear * 0.32,
        y: bridgeY,
        width: rect.width - ear * 0.64,
        height: bridgeH
    )
    let bridgeR = bridgeH * 0.48
    func rr(_ r: CGRect, _ rad: CGFloat) -> String {
        String(format: "<rect x='%.2f' y='%.2f' width='%.2f' height='%.2f' rx='%.2f'/>", r.minX, r.minY, r.width, r.height, rad)
    }
    return "<g fill='\(hex)'>\(rr(left, earR))\(rr(right, earR))\(rr(bridge, bridgeR))</g>"
}

func svgForConcept(_ concept: Concept) -> String {
    let tealTop = "#129492"
    let tealBot = "#094E4D"
    let paper = Palette.paper.hex
    let ink = Palette.tealInk.hex
    let line = Palette.line.hex
    let spine = Palette.spine.hex
    let pageEdge = Palette.pageEdge.hex
    let bg = """
    <defs>
      <linearGradient id='bg' x1='20%' y1='0%' x2='80%' y2='100%'>
        <stop offset='0%' stop-color='\(tealTop)'/>
        <stop offset='100%' stop-color='\(tealBot)'/>
      </linearGradient>
    </defs>
    <rect width='1024' height='1024' fill='url(#bg)'/>
    """

    let body: String
    switch concept {
    case .handsetOverPage:
        body = """
        <rect x='214' y='188' width='596' height='676' rx='64' fill='\(paper)'/>
        <rect x='286' y='548' width='452' height='20' rx='10' fill='\(line)'/>
        <rect x='286' y='628' width='452' height='20' rx='10' fill='\(line)'/>
        <rect x='286' y='708' width='452' height='20' rx='10' fill='\(line)'/>
        <rect x='286' y='788' width='280' height='20' rx='10' fill='\(line)'/>
        \(svgHandset(rect: CGRect(x: 268, y: 248, width: 488, height: 236), fill: ink))
        <rect x='300' y='338' width='72' height='96' rx='32' fill='\(paper)'/>
        <rect x='652' y='338' width='72' height='96' rx='32' fill='\(paper)'/>
        """
    case .notepadReceiver:
        body = """
        <rect x='196' y='360' width='632' height='508' rx='56' fill='\(paper)'/>
        \(svgHandset(rect: CGRect(x: 236, y: 168, width: 552, height: 268), fill: ink, earsDown: true))
        <circle cx='330' cy='456' r='15' fill='\(tealBot)'/>
        <circle cx='421' cy='456' r='15' fill='\(tealBot)'/>
        <circle cx='512' cy='456' r='15' fill='\(tealBot)'/>
        <circle cx='603' cy='456' r='15' fill='\(tealBot)'/>
        <circle cx='694' cy='456' r='15' fill='\(tealBot)'/>
        <rect x='276' y='520' width='472' height='22' rx='11' fill='\(line)'/>
        <rect x='276' y='620' width='472' height='22' rx='11' fill='\(line)'/>
        <rect x='276' y='720' width='300' height='22' rx='11' fill='\(line)'/>
        """
    case .diaryEmboss:
        body = """
        <rect x='196' y='156' width='600' height='712' rx='52' fill='\(paper)'/>
        <path d='M248 156 H284 V868 H248 C218 868 196 846 196 816 V208 C196 178 218 156 248 156 Z' fill='\(spine)'/>
        <rect x='210' y='300' width='60' height='8' rx='3' fill='#A08C6C'/>
        <rect x='210' y='500' width='60' height='8' rx='3' fill='#A08C6C'/>
        <rect x='210' y='700' width='60' height='8' rx='3' fill='#A08C6C'/>
        <rect x='808' y='176' width='16' height='672' rx='6' fill='\(pageEdge)'/>
        <rect x='828' y='182' width='16' height='660' rx='6' fill='\(pageEdge)'/>
        <rect x='848' y='188' width='16' height='648' rx='6' fill='\(pageEdge)'/>
        \(svgHandset(rect: CGRect(x: 360, y: 268, width: 360, height: 196), fill: ink))
        <rect x='360' y='520' width='300' height='22' rx='11' fill='\(line)'/>
        <rect x='360' y='600' width='300' height='22' rx='11' fill='\(line)'/>
        <rect x='360' y='680' width='200' height='22' rx='11' fill='\(line)'/>
        """
    }

    return """
    <?xml version='1.0' encoding='UTF-8'?>
    <svg xmlns='http://www.w3.org/2000/svg' width='1024' height='1024' viewBox='0 0 1024 1024'>
    \(bg)
    \(body)
    </svg>
    """
}

func svgMenuMark(_ concept: Concept) -> String {
    // Template glyph in a 24pt-aligned 128 viewBox; black fill, no background.
    let ink = "#1C1C1E"
    switch concept {
    case .handsetOverPage:
        return """
        <?xml version='1.0' encoding='UTF-8'?>
        <svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>
          <rect x='22' y='14' width='84' height='100' rx='12' fill='none' stroke='\(ink)' stroke-width='8'/>
          \(svgHandset(rect: CGRect(x: 34, y: 26, width: 60, height: 34), fill: ink))
          <rect x='36' y='76' width='56' height='7' rx='3.5' fill='\(ink)'/>
          <rect x='36' y='92' width='36' height='7' rx='3.5' fill='\(ink)'/>
        </svg>
        """
    case .notepadReceiver:
        return """
        <?xml version='1.0' encoding='UTF-8'?>
        <svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>
          <rect x='22' y='50' width='84' height='66' rx='12' fill='\(ink)'/>
          \(svgHandset(rect: CGRect(x: 28, y: 10, width: 72, height: 52), fill: ink, earsDown: true))
          <rect x='38' y='84' width='52' height='7' rx='3.5' fill='#FFFFFF'/>
        </svg>
        """
    case .diaryEmboss:
        return """
        <?xml version='1.0' encoding='UTF-8'?>
        <svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>
          <rect x='20' y='12' width='88' height='104' rx='12' fill='none' stroke='\(ink)' stroke-width='8'/>
          <rect x='20' y='12' width='18' height='104' rx='8' fill='\(ink)'/>
          \(svgHandset(rect: CGRect(x: 48, y: 32, width: 50, height: 30), fill: ink))
          <rect x='50' y='74' width='42' height='7' rx='3.5' fill='\(ink)'/>
          <rect x='50' y='88' width='28' height='7' rx='3.5' fill='\(ink)'/>
        </svg>
        """
    }
}

func svgWave(centerY: CGFloat, x0: CGFloat, width: CGFloat, height: CGFloat, amps: [CGFloat], invert: Bool, stroke hex: String, sw: CGFloat) -> String {
    let n = max(amps.count, 1)
    let samples = max(28, n * 14)
    let sign: CGFloat = invert ? -1 : 1
    var d = ""
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples)
        let x = x0 + t * width
        let idx = min(Int(floor(t * CGFloat(n))), n - 1)
        let local = t * CGFloat(n) - CGFloat(idx)
        let y = centerY - sign * sin(local * .pi) * height * amps[idx]
        d += i == 0 ? String(format: "M%.2f,%.2f", x, y) : String(format: " L%.2f,%.2f", x, y)
    }
    return "<path d='\(d)' fill='none' stroke='\(hex)' stroke-width='\(sw)' stroke-linecap='round' stroke-linejoin='round'/>"
}

func svgVoiceMark(_ variant: VoiceVariant) -> String {
    let ink = "#1C1C1E"
    switch variant {
    case .splitWaves:
        return """
        <?xml version='1.0' encoding='UTF-8'?>
        <svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>
          <rect x='20' y='12' width='88' height='104' rx='12' fill='none' stroke='\(ink)' stroke-width='8'/>
          <rect x='20' y='12' width='18' height='104' rx='8' fill='\(ink)'/>
          \(svgWave(centerY: 48, x0: 46, width: 54, height: 12, amps: voiceATiny, invert: false, stroke: ink, sw: 5))
          \(svgWave(centerY: 86, x0: 46, width: 54, height: 12, amps: voiceBTiny, invert: true, stroke: ink, sw: 5))
        </svg>
        """
    case .linedVoices:
        return """
        <?xml version='1.0' encoding='UTF-8'?>
        <svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>
          <rect x='10' y='16' width='50' height='96' rx='10' fill='none' stroke='\(ink)' stroke-width='7'/>
          <rect x='68' y='16' width='50' height='96' rx='10' fill='none' stroke='\(ink)' stroke-width='7'/>
          \(svgWave(centerY: 64, x0: 18, width: 34, height: 14, amps: voiceATiny, invert: false, stroke: ink, sw: 5))
          \(svgWave(centerY: 64, x0: 76, width: 34, height: 14, amps: voiceBTiny, invert: true, stroke: ink, sw: 5))
        </svg>
        """
    case .facingVoices:
        return """
        <?xml version='1.0' encoding='UTF-8'?>
        <svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>
          <rect x='20' y='12' width='88' height='104' rx='12' fill='none' stroke='\(ink)' stroke-width='8'/>
          <rect x='20' y='12' width='18' height='104' rx='8' fill='\(ink)'/>
          <path d='M54,46 A16,20 0 0 1 54,82' fill='none' stroke='\(ink)' stroke-width='8' stroke-linecap='round'/>
          <path d='M48,52 A10,14 0 0 1 48,76' fill='none' stroke='\(ink)' stroke-width='8' stroke-linecap='round'/>
          <path d='M100,40 A22,28 0 0 0 100,88' fill='none' stroke='\(ink)' stroke-width='7' stroke-linecap='round'/>
          <path d='M90,50 A14,18 0 0 0 90,78' fill='none' stroke='\(ink)' stroke-width='7' stroke-linecap='round'/>
        </svg>
        """
    }
}

func svgForVoice(_ variant: VoiceVariant) -> String {
    svgVoiceMark(variant)
}

// MARK: - Raster

func makeContext(width: Int, height: Int, opaque: Bool = false) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: alpha.rawValue
    ) else {
        fputs("failed to create bitmap \(width)x\(height)\n", stderr)
        exit(1)
    }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func pngData(from ctx: CGContext) -> Data {
    guard let image = ctx.makeImage() else {
        fputs("makeImage failed\n", stderr)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("png encode failed\n", stderr)
        exit(1)
    }
    return data
}

func writePNG(_ data: Data, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

func renderAppIcon(_ concept: Concept, size: Int, squircle: Bool) -> Data {
    let ctx = makeContext(width: size, height: size)
    drawConcept(concept, ctx: ctx, size: CGFloat(size), clipSquircle: squircle)
    return pngData(from: ctx)
}

func renderMenuBar(concept: Concept, state: MenuState, dark: Bool, glyphPt: CGFloat, barWidth: Int, barHeight: Int) -> Data {
    let ctx = makeContext(width: barWidth, height: barHeight)
    let bg = dark ? Palette.menuDark : Palette.menuLight
    ctx.setFillColor(bg.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: barWidth, height: barHeight))
    let glyphPx = Int((glyphPt * 2).rounded()) // 18pt @2x
    ctx.saveGState()
    let x = CGFloat(barWidth - glyphPx) / 2
    let y = CGFloat(barHeight - glyphPx) / 2
    ctx.translateBy(x: x, y: y)
    let color = dark ? Palette.menuDarkGlyph : Palette.menuLightGlyph
    drawMenuMark(concept, ctx: ctx, size: CGFloat(glyphPx), color: color, state: state)
    ctx.restoreGState()
    return pngData(from: ctx)
}

func renderGlyphOnly(concept: Concept, state: MenuState, size: Int, dark: Bool) -> Data {
    let ctx = makeContext(width: size, height: size)
    let bg = dark ? Palette.menuDark : Palette.menuLight
    ctx.setFillColor(bg.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let color = dark ? Palette.menuDarkGlyph : Palette.menuLightGlyph
    drawMenuMark(concept, ctx: ctx, size: CGFloat(size), color: color, state: state)
    return pngData(from: ctx)
}

func renderVoiceContactSheet(variants: [VoiceVariant], sizes: [Int]) -> Data {
    let cell: Int = 160
    let labelH: Int = 28
    let cols = sizes.count
    let rows = variants.count
    let pad = 16
    let width = pad * 2 + cols * cell + (cols - 1) * 12
    let height = pad * 2 + rows * (cell + labelH) + (rows - 1) * 12 + 36
    let ctx = makeContext(width: width, height: height)
    ctx.setFillColor(RGB(28, 28, 30).cg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func drawLabel(_ text: String, at point: CGPoint, size fontSize: CGFloat, color: RGB) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let line = CTLineCreateWithAttributedString(str)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
    drawLabel("CallNotes voice-wave variants  ·  no phone", at: CGPoint(x: pad, y: 22), size: 13, color: RGB(200, 200, 204))
    for (r, variant) in variants.enumerated() {
        for (c, sz) in sizes.enumerated() {
            let x = pad + c * (cell + 12)
            let y = 40 + pad + r * (cell + labelH + 12)
            ctx.setFillColor(RGB(44, 44, 46).cg)
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            let icon = renderVoiceIcon(variant, size: sz, squircle: true)
            let nsimage = NSImage(data: icon)!
            let cg = nsimage.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let dest = CGRect(x: x, y: y, width: cell, height: cell)
            ctx.saveGState()
            ctx.translateBy(x: dest.minX, y: dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = sz <= 32 ? .none : .high
            ctx.draw(cg, in: CGRect(origin: .zero, size: dest.size))
            ctx.restoreGState()
            drawLabel("\(variant.slug)  \(sz)pt", at: CGPoint(x: x, y: y + cell + 16), size: 11, color: RGB(170, 170, 176))
        }
    }
    return pngData(from: ctx)
}

func renderContactSheet(concepts: [Concept], sizes: [Int]) -> Data {
    let cell: Int = 160
    let labelH: Int = 28
    let cols = sizes.count
    let rows = concepts.count
    let pad = 16
    let width = pad * 2 + cols * cell + (cols - 1) * pad
    let height = pad * 2 + 36 + rows * (cell + labelH + 12)
    let ctx = makeContext(width: width, height: height)
    ctx.setFillColor(RGB(18, 18, 20).cg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func drawLabel(_ text: String, at point: CGPoint, size fontSize: CGFloat, color: RGB) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let line = CTLineCreateWithAttributedString(str)
        ctx.textPosition = CGPoint(x: point.x, y: point.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    drawLabel("CallNotes icon concepts  ·  16 / 32 / 128 / 1024 shown at \(cell)px cells", at: CGPoint(x: pad, y: 22), size: 13, color: RGB(200, 200, 204))

    for (r, concept) in concepts.enumerated() {
        for (c, sz) in sizes.enumerated() {
            let x = pad + c * (cell + pad)
            let y = 48 + r * (cell + labelH + 12)
            let icon = renderAppIcon(concept, size: sz, squircle: true)
            let nsimage = NSImage(data: icon)!
            let cg = nsimage.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let dest = CGRect(x: x, y: y, width: cell, height: cell)
            ctx.saveGState()
            ctx.translateBy(x: dest.minX, y: dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(origin: .zero, size: dest.size))
            ctx.restoreGState()
            drawLabel("\(concept.slug)  \(sz)pt", at: CGPoint(x: x, y: y + cell + 16), size: 11, color: RGB(170, 170, 176))
        }
    }
    return pngData(from: ctx)
}

// MARK: - Shipped catalog (diary-facing-voices only)

func writeJSON(_ object: String, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! object.write(to: url, atomically: true, encoding: .utf8)
}

func writeCatalog(_ catalogDir: URL) {
    let shipped = VoiceVariant.facingVoices
    let fm = FileManager.default
    try! fm.createDirectory(at: catalogDir, withIntermediateDirectories: true)
    writeJSON(
        """
        {
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """,
        to: catalogDir.appendingPathComponent("Contents.json")
    )

    let appIcon = catalogDir.appendingPathComponent("AppIcon.appiconset")
    try! fm.createDirectory(at: appIcon, withIntermediateDirectories: true)
    struct MacIcon {
        var size: Int
        var scale: Int
        var filename: String
        var pixels: Int { size * scale }
    }
    let macIcons: [MacIcon] = [
        .init(size: 16, scale: 1, filename: "icon_16x16.png"),
        .init(size: 16, scale: 2, filename: "icon_16x16@2x.png"),
        .init(size: 32, scale: 1, filename: "icon_32x32.png"),
        .init(size: 32, scale: 2, filename: "icon_32x32@2x.png"),
        .init(size: 128, scale: 1, filename: "icon_128x128.png"),
        .init(size: 128, scale: 2, filename: "icon_128x128@2x.png"),
        .init(size: 256, scale: 1, filename: "icon_256x256.png"),
        .init(size: 256, scale: 2, filename: "icon_256x256@2x.png"),
        .init(size: 512, scale: 1, filename: "icon_512x512.png"),
        .init(size: 512, scale: 2, filename: "icon_512x512@2x.png"),
    ]
    var imagesJSON: [String] = []
    for icon in macIcons {
        writePNG(
            renderVoiceIcon(shipped, size: icon.pixels, squircle: false),
            to: appIcon.appendingPathComponent(icon.filename)
        )
        imagesJSON.append(
            """
                {
                  "filename" : "\(icon.filename)",
                  "idiom" : "mac",
                  "scale" : "\(icon.scale)x",
                  "size" : "\(icon.size)x\(icon.size)"
                }
            """
        )
    }
    imagesJSON.append(
        """
            {
              "filename" : "icon_512x512@2x.png",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            }
        """
    )
    writeJSON(
        """
        {
          "images" : [
        \(imagesJSON.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """,
        to: appIcon.appendingPathComponent("Contents.json")
    )

    struct MenuAsset {
        var name: String
        var state: MenuState
        var original: Bool
        var includeDark: Bool
    }
    let menuAssets: [MenuAsset] = [
        .init(name: "CallNotesMark", state: .idle, original: false, includeDark: false),
        .init(name: "CallNotesMarkFill", state: .armed, original: false, includeDark: false),
        .init(name: "CallNotesMarkRecording", state: .recording, original: true, includeDark: true),
        .init(name: "CallNotesMarkProcessing", state: .processing, original: false, includeDark: false),
    ]
    let scales = [(1, 18), (2, 36), (3, 54)]
    for asset in menuAssets {
        let set = catalogDir.appendingPathComponent("\(asset.name).imageset")
        try! fm.createDirectory(at: set, withIntermediateDirectories: true)
        var entries: [String] = []
        for (scale, pixels) in scales {
            let filename = scale == 1 ? "\(asset.name).png" : "\(asset.name)@\(scale)x.png"
            let color = asset.original ? Palette.menuLightGlyph : RGB(0, 0, 0)
            writePNG(
                renderVoiceCatalogGlyph(
                    variant: shipped,
                    state: asset.state,
                    size: pixels,
                    color: color,
                    template: !asset.original
                ),
                to: set.appendingPathComponent(filename)
            )
            entries.append(
                """
                    {
                      "filename" : "\(filename)",
                      "idiom" : "universal",
                      "scale" : "\(scale)x"
                    }
                """
            )
            if asset.includeDark {
                let darkName = scale == 1 ? "\(asset.name)-dark.png" : "\(asset.name)-dark@\(scale)x.png"
                writePNG(
                    renderVoiceCatalogGlyph(
                        variant: shipped,
                        state: asset.state,
                        size: pixels,
                        color: Palette.menuDarkGlyph,
                        template: false
                    ),
                    to: set.appendingPathComponent(darkName)
                )
                entries.append(
                    """
                        {
                          "appearances" : [
                            {
                              "appearance" : "luminosity",
                              "value" : "dark"
                            }
                          ],
                          "filename" : "\(darkName)",
                          "idiom" : "universal",
                          "scale" : "\(scale)x"
                        }
                    """
                )
            }
        }
        let intent = asset.original ? "original" : "template"
        writeJSON(
            """
            {
              "images" : [
            \(entries.joined(separator: ",\n"))
              ],
              "info" : {
                "author" : "xcode",
                "version" : 1
              },
              "properties" : {
                "template-rendering-intent" : "\(intent)"
              }
            }

            """,
            to: set.appendingPathComponent("Contents.json")
        )
    }
}

// MARK: - Main

let args = Args.parse()
let fm = FileManager.default
try! fm.createDirectory(at: args.outDir.appendingPathComponent("Concepts"), withIntermediateDirectories: true)
try! fm.createDirectory(at: args.outDir.appendingPathComponent("Renders"), withIntermediateDirectories: true)

let sizes = [16, 32, 128, 1024]
var proofURLs: [URL] = []
if let proof = args.proofDir {
    try! fm.createDirectory(at: proof, withIntermediateDirectories: true)
    proofURLs.append(proof)
}

func publish(_ data: Data, name: String) {
    let repoURL = args.outDir.appendingPathComponent("Renders").appendingPathComponent(name)
    writePNG(data, to: repoURL)
    if let proof = args.proofDir {
        writePNG(data, to: proof.appendingPathComponent(name))
    }
}

if !args.voicesOnly {
for concept in Concept.allCases {
    let svg = svgForConcept(concept)
    let svgURL = args.outDir.appendingPathComponent("Concepts").appendingPathComponent("\(concept.slug).svg")
    try! svg.write(to: svgURL, atomically: true, encoding: .utf8)
    let markSVG = svgMenuMark(concept)
    let markURL = args.outDir.appendingPathComponent("Concepts").appendingPathComponent("\(concept.slug)-menubar.svg")
    try! markSVG.write(to: markURL, atomically: true, encoding: .utf8)

    for size in sizes {
        let png = renderAppIcon(concept, size: size, squircle: true)
        publish(png, name: "\(concept.slug)-\(size).png")
        let unmasked = renderAppIcon(concept, size: size, squircle: false)
        writePNG(unmasked, to: args.outDir.appendingPathComponent("Renders").appendingPathComponent("\(concept.slug)-\(size)-square.png"))
    }

    for dark in [false, true] {
        let appearance = dark ? "dark" : "light"
        let strip = renderMenuBar(
            concept: concept,
            state: .armed,
            dark: dark,
            glyphPt: 18,
            barWidth: 360,
            barHeight: 48
        )
        publish(strip, name: "\(concept.slug)-menubar-18-\(appearance).png")
        let glyph = renderGlyphOnly(concept: concept, state: .armed, size: 36, dark: dark)
        publish(glyph, name: "\(concept.slug)-menubar-18pt@2x-\(appearance).png")
    }

    let recLight = renderMenuBar(concept: concept, state: .recording, dark: false, glyphPt: 18, barWidth: 360, barHeight: 48)
    let recDark = renderMenuBar(concept: concept, state: .recording, dark: true, glyphPt: 18, barWidth: 360, barHeight: 48)
    let procLight = renderMenuBar(concept: concept, state: .processing, dark: false, glyphPt: 18, barWidth: 360, barHeight: 48)
    let procDark = renderMenuBar(concept: concept, state: .processing, dark: true, glyphPt: 18, barWidth: 360, barHeight: 48)
    publish(recLight, name: "\(concept.slug)-menubar-recording-light.png")
    publish(recDark, name: "\(concept.slug)-menubar-recording-dark.png")
    publish(procLight, name: "\(concept.slug)-menubar-processing-light.png")
    publish(procDark, name: "\(concept.slug)-menubar-processing-dark.png")
}

let sheet = renderContactSheet(concepts: Concept.allCases, sizes: sizes)
publish(sheet, name: "concepts-contact-sheet.png")
}

for variant in VoiceVariant.allCases {
    let svg = svgForVoice(variant)
    let svgURL = args.outDir.appendingPathComponent("Concepts").appendingPathComponent("\(variant.slug).svg")
    try! svg.write(to: svgURL, atomically: true, encoding: .utf8)
    let markURL = args.outDir.appendingPathComponent("Concepts").appendingPathComponent("\(variant.slug)-menubar.svg")
    try! svgVoiceMark(variant).write(to: markURL, atomically: true, encoding: .utf8)

    for size in sizes {
        let png = renderVoiceIcon(variant, size: size, squircle: true)
        publish(png, name: "\(variant.slug)-\(size).png")
        let unmasked = renderVoiceIcon(variant, size: size, squircle: false)
        writePNG(unmasked, to: args.outDir.appendingPathComponent("Renders").appendingPathComponent("\(variant.slug)-\(size)-square.png"))
    }

    for dark in [false, true] {
        let appearance = dark ? "dark" : "light"
        let strip = renderVoiceMenuBar(variant: variant, state: .idle, dark: dark, glyphPt: 18, barWidth: 360, barHeight: 48)
        publish(strip, name: "\(variant.slug)-menubar-18-\(appearance).png")
        let glyph = renderVoiceGlyph(variant: variant, state: .idle, size: 36, dark: dark)
        publish(glyph, name: "\(variant.slug)-menubar-18pt@2x-\(appearance).png")
        let armed = renderVoiceMenuBar(variant: variant, state: .armed, dark: dark, glyphPt: 18, barWidth: 360, barHeight: 48)
        publish(armed, name: "\(variant.slug)-menubar-armed-18-\(appearance).png")
    }
    publish(renderVoiceMenuBar(variant: variant, state: .recording, dark: false, glyphPt: 18, barWidth: 360, barHeight: 48), name: "\(variant.slug)-menubar-recording-light.png")
    publish(renderVoiceMenuBar(variant: variant, state: .recording, dark: true, glyphPt: 18, barWidth: 360, barHeight: 48), name: "\(variant.slug)-menubar-recording-dark.png")
    publish(renderVoiceMenuBar(variant: variant, state: .processing, dark: false, glyphPt: 18, barWidth: 360, barHeight: 48), name: "\(variant.slug)-menubar-processing-light.png")
    publish(renderVoiceMenuBar(variant: variant, state: .processing, dark: true, glyphPt: 18, barWidth: 360, barHeight: 48), name: "\(variant.slug)-menubar-processing-dark.png")
}

let voiceSheet = renderVoiceContactSheet(variants: VoiceVariant.allCases, sizes: sizes)
publish(voiceSheet, name: "voice-waves-contact-sheet.png")

fputs("wrote concepts to \(args.outDir.path)\n", stderr)
if let proof = args.proofDir {
    fputs("wrote proofs to \(proof.path)\n", stderr)
}
if let catalog = args.catalogDir {
    writeCatalog(catalog)
    fputs("wrote catalog to \(catalog.path)\n", stderr)
}
