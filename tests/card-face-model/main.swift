import Foundation

func requireInvalid(_ design: CardFaceDesign) {
    do {
        try CardFaceValidation.validate(design)
        fatalError("Invalid design accepted")
    } catch CardFaceLibraryError.invalidDesign {
        // Expected: reject unsafe or unrenderable imported/persisted state.
    } catch { fatalError("Unexpected error: \(error)") }
}

let id = UUID()
var original = CardFaceDesign(name: "交通卡面", layers: [
    CardFaceLayer(id: id, imageName: id.uuidString + ".png", title: "交通联合", x: 0.8, y: 0.2, width: 0.25, rotation: 45, opacity: 0.35)
])
try CardFaceValidation.validate(original)
let bytes = try JSONEncoder().encode(original)
let decoded = try JSONDecoder().decode(CardFaceDesign.self, from: bytes)
try CardFaceValidation.validate(decoded)
precondition(decoded.id == original.id && decoded.name == original.name)
precondition(decoded.layers[0].imageName == original.layers[0].imageName)
precondition(decoded.layers[0].x == 0.8 && decoded.layers[0].rotation == 45)
precondition(decoded.layers[0].opacity == 0.35)

// Current projects require every persisted style field; optional text/font remain optional.
for key in ["opacity", "textBold", "textItalic", "textRed", "textGreen", "textBlue"] {
    var incomplete = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    var layers = incomplete["layers"] as! [[String: Any]]
    layers[0].removeValue(forKey: key)
    incomplete["layers"] = layers
    let data = try JSONSerialization.data(withJSONObject: incomplete)
    do {
        _ = try JSONDecoder().decode(CardFaceDesign.self, from: data)
        fatalError("Missing required field accepted: \(key)")
    } catch DecodingError.keyNotFound(_, _) { }
}

var ordered = original
let second = UUID(), third = UUID()
ordered.layers.append(CardFaceLayer(id: second, imageName: second.uuidString + ".png", title: "中层"))
ordered.layers.append(CardFaceLayer(id: third, imageName: third.uuidString + ".png", title: "顶层"))
precondition(ordered.moveLayer(id: id, to: third))
precondition(ordered.layers.map(\.id) == [second, third, id])
precondition(ordered.moveLayer(id: id, to: second))
precondition(ordered.layers.map(\.id) == [id, second, third])
precondition(!ordered.moveLayer(id: id, to: id))
precondition(!ordered.moveLayer(id: UUID(), to: third))
let reordered = try JSONDecoder().decode(CardFaceDesign.self, from: JSONEncoder().encode(ordered))
precondition(reordered.layers.map(\.id) == [id, second, third])
precondition(reordered.layers[0].opacity == 0.35 && reordered.layers[0].x == 0.8)

var invalid = original
invalid.layers[0].imageName = "../cover.png"
requireInvalid(invalid)
for opacity in [-0.1, 1.1, Double.nan] {
    invalid = original
    invalid.layers[0].opacity = opacity
    requireInvalid(invalid)
}
invalid = original
invalid.layers.append(original.layers[0])
requireInvalid(invalid)
invalid = original
invalid.layers[0].x = .nan
requireInvalid(invalid)
invalid = original
invalid.layers[0].y = 1.1
requireInvalid(invalid)
invalid = original
invalid.layers[0].width = 0
requireInvalid(invalid)
invalid = original
invalid.layers[0].rotation = .infinity
requireInvalid(invalid)
invalid = original
invalid.red = -0.1
requireInvalid(invalid)
invalid = original
invalid.name = " \n "
requireInvalid(invalid)
invalid = original
invalid.name = String(repeating: "长", count: 81)
requireInvalid(invalid)
invalid = original
invalid.layers = (0..<25).map { i in
    let layerID = UUID()
    return CardFaceLayer(id: layerID, imageName: layerID.uuidString + ".png", title: "\(i)")
}
requireInvalid(invalid)
let entry = CardFaceEntry(id: original.id, name: original.name, revision: UUID(), updatedAt: Date())
let entryRoundTrip = try JSONDecoder().decode(CardFaceEntry.self, from: JSONEncoder().encode(entry))
precondition(entryRoundTrip.id == entry.id && entryRoundTrip.revision == entry.revision)
print("Card-face persistence, required fields, layer ordering, and 13 invalid-state cases passed")

let canvas = CGSize(width: 200, height: 120)
let halfSize = CGSize(width: 10, height: 5)
let centered = CardFaceAlignment.snap(center: CGPoint(x: 103, y: 57), halfSize: halfSize,
                                      canvas: canvas, otherFrames: [])
precondition(centered.center == CGPoint(x: 100, y: 60))
precondition(centered.verticalGuide == 100 && centered.horizontalGuide == 60)
let distant = CardFaceAlignment.snap(center: CGPoint(x: 108, y: 70), halfSize: halfSize,
                                     canvas: canvas, otherFrames: [])
precondition(distant.center == CGPoint(x: 108, y: 70))
precondition(distant.verticalGuide == nil && distant.horizontalGuide == nil)
let edge = CardFaceAlignment.snap(center: CGPoint(x: 91, y: 79), halfSize: halfSize,
                                 canvas: canvas, otherFrames: [CGRect(x: 80, y: 40, width: 40, height: 20)])
precondition(edge.center == CGPoint(x: 90, y: 79) && edge.verticalGuide == 80)
precondition(edge.horizontalGuide == nil)
let nearest = CardFaceAlignment.snap(center: CGPoint(x: 103, y: 60), halfSize: halfSize,
                                    canvas: canvas, otherFrames: [CGRect(x: 95, y: 20, width: 20, height: 20)])
precondition(nearest.center.x == 105 && nearest.verticalGuide == 105)
let clamped = CardFaceAlignment.snap(center: CGPoint(x: -20, y: 150), halfSize: halfSize,
                                    canvas: canvas, otherFrames: [])
precondition(clamped.center == CGPoint(x: 0, y: 120))
print("Card-face alignment: center, edge, nearest target, release distance and canvas bounds passed")

var textDesign = original
textDesign.layers[0].text = String(repeating: "字", count: 30)
try CardFaceValidation.validate(textDesign)
let textRoundTrip = try JSONDecoder().decode(CardFaceDesign.self, from: JSONEncoder().encode(textDesign))
precondition(textRoundTrip.layers[0].text == textDesign.layers[0].text)
precondition(decoded.layers[0].text == nil)
precondition(!decoded.layers[0].textBold && !decoded.layers[0].textItalic)
for (bold, italic) in [(false, false), (true, false), (false, true), (true, true)] {
    textDesign.layers[0].textBold = bold
    textDesign.layers[0].textItalic = italic
    let styled = try JSONDecoder().decode(CardFaceDesign.self, from: JSONEncoder().encode(textDesign))
    precondition(styled.layers[0].textBold == bold && styled.layers[0].textItalic == italic)
    precondition(styled == textDesign)
}
for text in ["", " \n ", String(repeating: "字", count: 31)] {
    textDesign.layers[0].text = text
    requireInvalid(textDesign)
}
print("Text layers: persistence, image layers and 30-character validation passed")

var colored = original
colored.layers[0].text = "123 中文 ABC"
precondition(colored.layers[0].setTextColor(hex: " #2a1e3a "))
precondition(colored.layers[0].textColorHex == "#2A1E3A")
precondition(colored.layers[0].textRed == 42.0 / 255 && colored.layers[0].textGreen == 30.0 / 255 && colored.layers[0].textBlue == 58.0 / 255)
try CardFaceValidation.validate(colored)
let coloredRoundTrip = try JSONDecoder().decode(CardFaceDesign.self, from: JSONEncoder().encode(colored))
precondition(coloredRoundTrip == colored)
for value in ["", "#123", "#12345678", "GG0000", "0x1234", "１２３４５６"] {
    var layer = colored.layers[0]
    precondition(!layer.setTextColor(hex: value))
    precondition(layer == colored.layers[0])
}
for value in ["000000", "#FFFFFF", "007aff"] {
    var layer = colored.layers[0]
    precondition(layer.setTextColor(hex: value))
}
for value in [-0.1, 1.1, Double.nan, Double.infinity] {
    for key in [\CardFaceLayer.textRed, \CardFaceLayer.textGreen, \CardFaceLayer.textBlue] {
        var invalidColor = colored
        invalidColor.layers[0][keyPath: key] = value
        requireInvalid(invalidColor)
    }
}
print("Text color: hex parsing, persistence and invalid components passed")

precondition(coloredRoundTrip.layers[0].textFontID == nil)
var fontDesign = colored
let importedFontID = UUID()
fontDesign.layers[0].textFontID = importedFontID
let fontRoundTrip = try JSONDecoder().decode(CardFaceDesign.self, from: JSONEncoder().encode(fontDesign))
precondition(fontRoundTrip.layers[0].textFontID == importedFontID)
precondition(fontRoundTrip.layers[0].textColorHex == colored.layers[0].textColorHex)
fontDesign.layers[0].textFontID = nil
let defaultFontRoundTrip = try JSONDecoder().decode(CardFaceDesign.self, from: JSONEncoder().encode(fontDesign))
precondition(defaultFontRoundTrip.layers[0].textFontID == nil)
print("Text fonts: font identity persistence and reset passed")

for (hue, red, green, blue) in [(0.0, 1.0, 0.0, 0.0), (1.0 / 6, 1.0, 1.0, 0.0),
                              (1.0 / 3, 0.0, 1.0, 0.0), (0.5, 0.0, 1.0, 1.0),
                              (2.0 / 3, 0.0, 0.0, 1.0), (5.0 / 6, 1.0, 0.0, 1.0), (1.0, 1.0, 0.0, 0.0)] {
    let rgb = CardFaceHSV(hue: hue, saturation: 1, brightness: 1).rgb
    precondition(abs(rgb.red - red) < 1e-12 && abs(rgb.green - green) < 1e-12 && abs(rgb.blue - blue) < 1e-12)
}
for (red, green, blue) in [(42.0 / 255, 30.0 / 255, 58.0 / 255), (1.0, 1.0, 1.0),
                          (0.0, 0.0, 0.0), (0.4, 0.4, 0.4), (0.8, 0.2, 0.5)] {
    let hsv = CardFaceHSV(red: red, green: green, blue: blue, fallbackHue: 0.7)
    let rgb = hsv.rgb
    precondition(abs(rgb.red - red) < 1e-12 && abs(rgb.green - green) < 1e-12 && abs(rgb.blue - blue) < 1e-12)
    if red == green && green == blue { precondition(hsv.hue == 0.7) }
}
let dark = CardFaceHSV(hue: 0.6, saturation: 0.8, brightness: 0).rgb
precondition(dark.red == 0 && dark.green == 0 && dark.blue == 0)
let gray = CardFaceHSV(hue: 0.6, saturation: 0, brightness: 0.4).rgb
precondition(gray.red == 0.4 && gray.green == 0.4 && gray.blue == 0.4)
print("HSV: primary colors, hue endpoints, RGB round trips, gray and black passed")
