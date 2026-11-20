import Foundation
import PDFKit

public struct ReportHints {
    public var expectedLongestSideMeters: Float?
    public var recommendedPointSizeMeters: Float?
    public var minPointRadiusPx: Float?
    public var maxPointRadiusPx: Float?
    public var verticalExaggeration: Float? // nil means default 1.0 (no exaggeration)
}

public enum ReportIngestor {
    public static func extractHints() -> ReportHints? {
        let bundle = Bundle.main
        let candidateNames = ["Report", "report", "SiteReport"]
        var pdfURL: URL? = nil
        
        for name in candidateNames {
            if let url = bundle.url(forResource: name, withExtension: "pdf") {
                pdfURL = url
                break
            }
        }
        
        guard let url = pdfURL else {
            print("[ReportIngestor] No report PDF found in bundle.")
            return nil
        }
        
        guard let document = PDFDocument(url: url) else {
            print("[ReportIngestor] Failed to load PDF document at \(url).")
            return nil
        }
        
        var fullText = ""
        for pageIndex in 0..<document.pageCount {
            if let page = document.page(at: pageIndex),
               let pageText = page.string {
                fullText.append(pageText + "\n")
            }
        }
        
        if fullText.isEmpty {
            print("[ReportIngestor] PDF text extraction yielded empty text.")
            return nil
        }
        
        let lowerText = fullText.lowercased()
        var hints = ReportHints()
        
        // 1) Find pair of dimensions pattern: e.g. "123 m x 456 m" or "123 meters by 456 meters"
        // pattern: number + optional decimal + unit + separator (×, x, by) + number + optional decimal + unit
        // Unit: meters, m, or meters abbreviation, case insensitive
        // Use regex with named capture groups
        
        if let dims = matchFirstDimensions(in: lowerText) {
            hints.expectedLongestSideMeters = dims
            // print("[ReportIngestor] Found expectedLongestSideMeters from dimensions: \(dims)m")
        } else if let longest = matchLongestSide(in: lowerText) {
            hints.expectedLongestSideMeters = longest
            // print("[ReportIngestor] Found expectedLongestSideMeters from longest side: \(longest)m")
        }
        
        // 2) Find point spacing or GSD, e.g. "point spacing: 0.10 m" or "GSD: 5 cm"
        if let spacingMeters = matchPointSpacingOrGSD(in: lowerText) {
            hints.recommendedPointSizeMeters = spacingMeters * 1.3
            hints.minPointRadiusPx = 1.5
            hints.maxPointRadiusPx = 6.0
            // print("[ReportIngestor] Found spacing \(spacingMeters)m, recommendedPointSizeMeters set to \(spacingMeters * 1.3)m")
        }
        
        // verticalExaggeration left nil intentionally (prefers accuracy)
        
        return hints
    }
    
    // MARK: - Helpers
    
    private static func matchFirstDimensions(in text: String) -> Float? {
        // Pattern components:
        // number: (\d+(\.\d+)?)
        // unit: (m|meter|meters)
        // separator: (×|x|by)
        // full regex (with optional spaces)
        let pattern = #"(\d+(?:\.\d+)?)\s*(m|meter|meters)\s*(×|x|by)\s*(\d+(?:\.\d+)?)\s*(m|meter|meters)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            print("[ReportIngestor] Failed to create regex for dimensions.")
            return nil
        }
        
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        
        func floatFromCapture(_ idx: Int) -> Float? {
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return Float(text[r])
        }
        
        func unitFromCapture(_ idx: Int) -> String? {
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[r])
        }
        
        guard
            let firstNum = floatFromCapture(1),
            let secondNum = floatFromCapture(4),
            let firstUnit = unitFromCapture(2),
            let secondUnit = unitFromCapture(5)
        else {
            return nil
        }
        
        let firstMeters = convertToMeters(value: firstNum, unit: firstUnit)
        let secondMeters = convertToMeters(value: secondNum, unit: secondUnit)
        
        return max(firstMeters, secondMeters)
    }
    
    private static func matchLongestSide(in text: String) -> Float? {
        // pattern: "longest side: 310 m"
        // number + unit after "longest side"
        let pattern = #"longest side\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*(m|meter|meters)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            print("[ReportIngestor] Failed to create regex for longest side.")
            return nil
        }
        
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        
        func floatFromCapture(_ idx: Int) -> Float? {
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return Float(text[r])
        }
        
        func unitFromCapture(_ idx: Int) -> String? {
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[r])
        }
        
        guard
            let num = floatFromCapture(1),
            let unit = unitFromCapture(2)
        else {
            return nil
        }
        
        return convertToMeters(value: num, unit: unit)
    }
    
    private static func matchPointSpacingOrGSD(in text: String) -> Float? {
        // try to find "point spacing: 0.10 m" or "GSD: 5 cm"
        // pattern: (point spacing|gsd)\s*[:\-]?\s*(number) (unit)
        let pattern = #"(point spacing|gsd)\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*(mm|cm|m|meter|meters)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            print("[ReportIngestor] Failed to create regex for point spacing / GSD.")
            return nil
        }
        
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        
        func floatFromCapture(_ idx: Int) -> Float? {
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return Float(text[r])
        }
        
        func unitFromCapture(_ idx: Int) -> String? {
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[r])
        }
        
        guard
            let num = floatFromCapture(2),
            let unit = unitFromCapture(3)
        else {
            return nil
        }
        
        return convertToMeters(value: num, unit: unit)
    }
    
    private static func convertToMeters(value: Float, unit: String) -> Float {
        let u = unit.lowercased()
        switch u {
        case "m", "meter", "meters":
            return value
        case "cm":
            return value / 100.0
        case "mm":
            return value / 1000.0
        default:
            // unknown unit
            return value
        }
    }
}
