import XCTest

/// Pins the picker's drag geometry and hex handling — the parts that fail silently.
final class ColorSpectrumMathTests: XCTestCase {

    // MARK: - Saturation / brightness plane

    func testPlaneCornersMapToTheExpectedExtremes() {
        let size = (w: 200.0, h: 100.0)
        // top-left = unsaturated + full brightness; bottom-right = saturated + black
        let topLeft = ColorSpectrumMath.saturationBrightness(atX: 0, y: 0, width: size.w, height: size.h)
        XCTAssertEqual(topLeft.saturation, 0, accuracy: 0.0001)
        XCTAssertEqual(topLeft.brightness, 1, accuracy: 0.0001)

        let bottomRight = ColorSpectrumMath.saturationBrightness(atX: size.w, y: size.h, width: size.w, height: size.h)
        XCTAssertEqual(bottomRight.saturation, 1, accuracy: 0.0001)
        XCTAssertEqual(bottomRight.brightness, 0, accuracy: 0.0001)
    }

    func testPlaneClampsDragsBeyondTheEdges() {
        // Dragging past the view bounds must saturate, never overshoot or go negative.
        let out = ColorSpectrumMath.saturationBrightness(atX: 500, y: -80, width: 200, height: 100)
        XCTAssertEqual(out.saturation, 1, accuracy: 0.0001)
        XCTAssertEqual(out.brightness, 1, accuracy: 0.0001)

        let under = ColorSpectrumMath.saturationBrightness(atX: -40, y: 900, width: 200, height: 100)
        XCTAssertEqual(under.saturation, 0, accuracy: 0.0001)
        XCTAssertEqual(under.brightness, 0, accuracy: 0.0001)
    }

    func testPlaneRoundTrips() {
        let size = (w: 240.0, h: 160.0)
        for saturation in [0.0, 0.25, 0.5, 0.9, 1.0] {
            for brightness in [0.0, 0.33, 0.75, 1.0] {
                let p = ColorSpectrumMath.point(saturation: saturation, brightness: brightness, width: size.w, height: size.h)
                let back = ColorSpectrumMath.saturationBrightness(atX: p.x, y: p.y, width: size.w, height: size.h)
                XCTAssertEqual(back.saturation, saturation, accuracy: 0.0001)
                XCTAssertEqual(back.brightness, brightness, accuracy: 0.0001)
            }
        }
    }

    func testZeroSizedPlaneDoesNotDivideByZero() {
        let out = ColorSpectrumMath.saturationBrightness(atX: 10, y: 10, width: 0, height: 0)
        XCTAssertEqual(out.saturation, 0)
        XCTAssertEqual(out.brightness, 0)
    }

    // MARK: - Hue slider

    func testHueRoundTripsAndClamps() {
        XCTAssertEqual(ColorSpectrumMath.hue(atX: 0, width: 300), 0, accuracy: 0.0001)
        XCTAssertEqual(ColorSpectrumMath.hue(atX: 150, width: 300), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ColorSpectrumMath.hue(atX: 900, width: 300), 1, accuracy: 0.0001)
        XCTAssertEqual(ColorSpectrumMath.hue(atX: -20, width: 300), 0, accuracy: 0.0001)

        XCTAssertEqual(ColorSpectrumMath.x(forHue: 0.25, width: 300), 75, accuracy: 0.0001)
        XCTAssertEqual(ColorSpectrumMath.x(forHue: 2, width: 300), 300, accuracy: 0.0001)
    }

    // MARK: - Hex

    func testHexFormatting() {
        XCTAssertEqual(ColorSpectrumMath.hexString(red: 0, green: 0, blue: 0), "#000000")
        XCTAssertEqual(ColorSpectrumMath.hexString(red: 1, green: 1, blue: 1), "#FFFFFF")
        // 0.1176 * 255 = 29.99 -> 30 = 0x1E
        XCTAssertEqual(ColorSpectrumMath.hexString(red: 0.1176, green: 0.5647, blue: 1), "#1E90FF")
    }

    func testHexParsingAcceptsTheFormsPeopleActuallyPaste() {
        let expected = (r: 30.0 / 255, g: 144.0 / 255, b: 1.0)
        for input in ["#1E90FF", "1e90ff", "  #1E90FF  "] {
            guard let parsed = ColorSpectrumMath.rgb(fromHex: input) else {
                return XCTFail("failed to parse \(input)")
            }
            XCTAssertEqual(parsed.red, expected.r, accuracy: 0.0001, input)
            XCTAssertEqual(parsed.green, expected.g, accuracy: 0.0001, input)
            XCTAssertEqual(parsed.blue, expected.b, accuracy: 0.0001, input)
        }
    }

    func testHexShorthandExpands() {
        guard let parsed = ColorSpectrumMath.rgb(fromHex: "#FFF") else {
            return XCTFail("shorthand should parse")
        }
        XCTAssertEqual(parsed.red, 1, accuracy: 0.0001)
        XCTAssertEqual(parsed.green, 1, accuracy: 0.0001)
        XCTAssertEqual(parsed.blue, 1, accuracy: 0.0001)
    }

    func testInvalidHexIsRejectedRatherThanGuessed() {
        for bad in ["", "#", "12345", "#GGGGGG", "#12345678Z", "not a color"] {
            XCTAssertNil(ColorSpectrumMath.rgb(fromHex: bad), "should reject \(bad)")
        }
    }

    func testHexRoundTrip() {
        for hex in ["#000000", "#FFFFFF", "#1E90FF", "#22C55E"] {
            guard let rgb = ColorSpectrumMath.rgb(fromHex: hex) else {
                return XCTFail("parse failed for \(hex)")
            }
            XCTAssertEqual(ColorSpectrumMath.hexString(red: rgb.red, green: rgb.green, blue: rgb.blue), hex)
        }
    }
}
