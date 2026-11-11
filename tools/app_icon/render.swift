// Rendert das App-Icon (Entwurf 2a) als 1024-px-PNG. Aufruf: swift render.swift <ziel.png> <eckenradius>
import AppKit
let path = CommandLine.arguments[1]; let radius = CGFloat(Double(CommandLine.arguments[2]) ?? 0)
func c(_ h: UInt32) -> CGColor { CGColor(red: CGFloat(h>>16&255)/255, green: CGFloat(h>>8&255)/255, blue: CGFloat(h&255)/255, alpha: 1) }
let info = radius > 0 ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
let g = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
g.translateBy(x: 0, y: 1024); g.scaleBy(x: 2, y: -2)
let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 512, height: 512), cornerWidth: radius, cornerHeight: radius, transform: nil)
g.addPath(bg); g.setFillColor(c(0x1E2329)); g.fillPath()
g.setLineCap(.round)
func arc(_ a: CGFloat, _ b: CGFloat, _ col: CGColor, _ w: CGFloat) { g.addArc(center: CGPoint(x: 256, y: 256), radius: 168, startAngle: a * .pi/180, endAngle: b * .pi/180, clockwise: false); g.setStrokeColor(col); g.setLineWidth(w); g.strokePath() }
arc(135, 405, c(0x343B45), 36); arc(135, 315, c(0xF2A93B), 36)
g.move(to: CGPoint(x: 158, y: 276))
g.addCurve(to: CGPoint(x: 247, y: 200), control1: CGPoint(x: 198, y: 276), control2: CGPoint(x: 205, y: 200))
g.addCurve(to: CGPoint(x: 326, y: 318), control1: CGPoint(x: 289, y: 200), control2: CGPoint(x: 290, y: 318))
g.addCurve(to: CGPoint(x: 358, y: 268), control1: CGPoint(x: 362, y: 318), control2: CGPoint(x: 340, y: 268))
g.setStrokeColor(c(0xFFFFFF)); g.setLineWidth(22); g.strokePath()
let dot = CGRect(x: 227, y: 180, width: 40, height: 40)
g.setFillColor(c(0x1E2329)); g.fillEllipse(in: dot)
g.setStrokeColor(c(0xF2A93B)); g.setLineWidth(11); g.strokeEllipse(in: dot)
let rep = NSBitmapImageRep(cgImage: g.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
