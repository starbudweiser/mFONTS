// Génère l'icône (1024 px) : carré arrondi sombre Socle, « Aa » bleu #2C9ED6.
import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor(srgbRed: 0.075, green: 0.075, blue: 0.086, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: size - 200, height: size - 200), xRadius: 185, yRadius: 185).fill()
let blue = NSColor(srgbRed: 0x2C/255, green: 0x9E/255, blue: 0xD6/255, alpha: 1)
let big = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 520, weight: .bold), .foregroundColor: blue])
let small = NSAttributedString(string: "a", attributes: [.font: NSFont.systemFont(ofSize: 380, weight: .semibold), .foregroundColor: NSColor(white: 0.92, alpha: 1)])
let bw = big.size().width, sw = small.size().width
let x0 = (size - (bw + sw - 10)) / 2
big.draw(at: NSPoint(x: x0, y: 330))
small.draw(at: NSPoint(x: x0 + bw - 10, y: 330))
let bar = NSBezierPath(roundedRect: NSRect(x: 280, y: 270, width: 464, height: 26), xRadius: 13, yRadius: 13)
blue.setFill(); bar.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
