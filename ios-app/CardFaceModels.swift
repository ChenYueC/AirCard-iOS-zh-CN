import Foundation
import CoreGraphics

enum CardFaceAlignment {
    struct Result {
        var center: CGPoint
        var verticalGuide: CGFloat?
        var horizontalGuide: CGFloat?
    }

    static func snap(center: CGPoint, halfSize: CGSize, canvas: CGSize,
                     otherFrames: [CGRect], threshold: CGFloat = 6) -> Result {
        func align(_ value: CGFloat, limit: CGFloat,
                   targets: [(CGFloat, CGFloat)]) -> (CGFloat, CGFloat?) {
            let clamped = min(limit, max(0, value))
            var best = threshold + 1
            var position = clamped
            var guide: CGFloat?
            for (target, offset) in targets {
                let candidate = target - offset
                let distance = abs(candidate - clamped)
                if candidate >= 0, candidate <= limit, distance <= threshold, distance < best {
                    best = distance
                    position = candidate
                    guide = target
                }
            }
            return (position, guide)
        }
        var xTargets: [(CGFloat, CGFloat)] = [(canvas.width / 2, 0)]
        var yTargets: [(CGFloat, CGFloat)] = [(canvas.height / 2, 0)]
        for frame in otherFrames {
            xTargets += [(frame.midX, 0), (frame.minX, -halfSize.width), (frame.maxX, halfSize.width)]
            yTargets += [(frame.midY, 0), (frame.minY, -halfSize.height), (frame.maxY, halfSize.height)]
        }
        let x = align(center.x, limit: canvas.width, targets: xTargets)
        let y = align(center.y, limit: canvas.height, targets: yTargets)
        return Result(center: CGPoint(x: x.0, y: y.0), verticalGuide: x.1, horizontalGuide: y.1)
    }
}

struct CardFaceHSV {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init(red: Double, green: Double, blue: Double, fallbackHue: Double = 0) {
        let maximum = max(red, max(green, blue)), minimum = min(red, min(green, blue))
        let delta = maximum - minimum
        brightness = maximum
        saturation = maximum == 0 ? 0 : delta / maximum
        if delta == 0 {
            hue = fallbackHue
        } else {
            let sector: Double
            if maximum == red { sector = (green - blue) / delta }
            else if maximum == green { sector = (blue - red) / delta + 2 }
            else { sector = (red - green) / delta + 4 }
            hue = (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
        }
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        let position = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let sector = Int(position)
        let fraction = position - Double(sector)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return (brightness, rising, low)
        case 1: return (falling, brightness, low)
        case 2: return (low, brightness, rising)
        case 3: return (low, falling, brightness)
        case 4: return (rising, low, brightness)
        default: return (brightness, low, falling)
        }
    }
}

struct CardFaceLayer: Codable, Identifiable, Equatable {
    var id = UUID()
    var imageName: String
    var title: String
    var x: Double = 0.5
    var y: Double = 0.5
    var width: Double = 0.3
    var rotation: Double = 0
    var opacity: Double = 1
    var text: String? = nil
    var textBold = false
    var textItalic = false
    var textFontID: UUID? = nil
    var textRed: Double = 1
    var textGreen: Double = 1
    var textBlue: Double = 1

    var textColorHex: String {
        String(format: "#%02X%02X%02X", Int((textRed * 255).rounded()),
               Int((textGreen * 255).rounded()), Int((textBlue * 255).rounded()))
    }

    @discardableResult
    mutating func setTextColor(hex: String) -> Bool {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }), let rgb = UInt32(value, radix: 16) else { return false }
        textRed = Double((rgb >> 16) & 255) / 255
        textGreen = Double((rgb >> 8) & 255) / 255
        textBlue = Double(rgb & 255) / 255
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, imageName, title, x, y, width, rotation, opacity, text, textBold, textItalic
        case textRed, textGreen, textBlue, textFontID
    }
}

struct CardFaceDesign: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "新卡面"
    var red: Double = 0.12
    var green: Double = 0.22
    var blue: Double = 0.38
    var layers: [CardFaceLayer] = []

    @discardableResult
    mutating func moveLayer(id: UUID, to targetID: UUID) -> Bool {
        guard id != targetID,
              let source = layers.firstIndex(where: { $0.id == id }),
              let destination = layers.firstIndex(where: { $0.id == targetID }) else { return false }
        let layer = layers.remove(at: source)
        layers.insert(layer, at: destination)
        return true
    }
}

struct CardFaceEntry: Codable, Identifiable {
    let id: UUID
    let name: String
    let revision: UUID
    let updatedAt: Date
}

enum CardFaceLibraryError: LocalizedError {
    case invalidDesign
    case imageMissing
    var errorDescription: String? {
        switch self {
        case .invalidDesign: return "卡面工程无效，请重新打开或新建设计。"
        case .imageMissing: return "卡面图片或素材缺失，无法保存或使用。"
        }
    }
}

enum CardFaceValidation {
    static func validate(_ design: CardFaceDesign) throws {
        guard !design.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              design.name.count <= 80, design.layers.count <= 24,
              [design.red, design.green, design.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              Set(design.layers.map(\.id)).count == design.layers.count,
              Set(design.layers.map(\.imageName)).count == design.layers.count else { throw CardFaceLibraryError.invalidDesign }
        for layer in design.layers {
            if let text = layer.text {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= 30 else { throw CardFaceLibraryError.invalidDesign }
            }
            guard layer.imageName == layer.id.uuidString + ".png",
                  [layer.x, layer.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  layer.width.isFinite, (0.05...0.85).contains(layer.width),
                  layer.rotation.isFinite, (-180...180).contains(layer.rotation),
                  [layer.textRed, layer.textGreen, layer.textBlue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  layer.opacity.isFinite, (0...1).contains(layer.opacity) else { throw CardFaceLibraryError.invalidDesign }
        }
    }
}
