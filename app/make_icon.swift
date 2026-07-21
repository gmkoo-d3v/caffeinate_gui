// 앱 아이콘 생성기 — 1024px PNG를 그린다 (실행: swiftc로 컴파일 후 1회 실행).
// 커피 브라운 그라디언트 스쿼클 + 흰색 cup.and.saucer.fill (메뉴바 아이콘과 동일 모티프).
import AppKit

let px = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap rep") }
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Big Sur+ 아이콘 그리드: 1024 캔버스 중앙의 824x824 스쿼클
let squircle = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius = 824.0 * 0.2237
let path = NSBezierPath(roundedRect: squircle, xRadius: radius, yRadius: radius)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.51, green: 0.33, blue: 0.20, alpha: 1.0), // 라이트 커피
    NSColor(calibratedRed: 0.26, green: 0.15, blue: 0.09, alpha: 1.0), // 다크 로스트
])!
gradient.draw(in: path, angle: -90)

// 흰색 컵 심볼 (메뉴바와 동일한 cup.and.saucer.fill)
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolSize = symbol.size
    let tinted = NSImage(size: symbolSize)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbolSize))
    NSColor.white.set()
    NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
    tinted.unlockFocus()

    // 스쿼클 중앙 배치 (살짝 위로 — 시각 중심 보정)
    let scale = 560.0 / max(symbolSize.width, symbolSize.height)
    let w = symbolSize.width * scale
    let h = symbolSize.height * scale
    let target = NSRect(
        x: squircle.midX - w / 2,
        y: squircle.midY - h / 2 + 14,
        width: w, height: h
    )
    tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1.0)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
