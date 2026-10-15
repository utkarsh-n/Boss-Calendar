import Foundation

/// A proposed plan is independent of the model provider and cannot schedule anything itself.
public struct ShapedPlan: Codable, Equatable, Sendable {
    public let summary: String
    public let phases: [ShapedPhase]
    public init(summary: String, phases: [ShapedPhase]) { self.summary = summary; self.phases = phases }
    private enum CodingKeys: String, CodingKey { case summary, phases }
    public init(from decoder: any Decoder) throws {
        try requireShapeKeys(["summary", "phases"], decoder: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        phases = try container.decode([ShapedPhase].self, forKey: .phases)
    }

    public func validate() throws {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 320,
              summary.rangeOfCharacter(from: .controlCharacters) == nil else { throw ShapedPlanError.invalidSummary }
        guard (3...6).contains(phases.count) else { throw ShapedPlanError.invalidPhaseCount }
        var titles = Set<String>()
        for phase in phases {
            let title = phase.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = title.split(whereSeparator: \.isWhitespace).count
            guard !title.isEmpty, title.count <= 28, (1...3).contains(wordCount),
                  title.rangeOfCharacter(from: .controlCharacters) == nil else { throw ShapedPlanError.invalidTitle }
            guard titles.insert(title.lowercased()).inserted else { throw ShapedPlanError.duplicateTitle }
            guard (1...40).contains(phase.hours) else { throw ShapedPlanError.invalidHours }
        }
    }
}

public struct ShapedPhase: Codable, Equatable, Sendable {
    public let title: String
    public let hours: Int
    public init(title: String, hours: Int) { self.title = title; self.hours = hours }
    private enum CodingKeys: String, CodingKey { case title, hours }
    public init(from decoder: any Decoder) throws {
        try requireShapeKeys(["title", "hours"], decoder: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        hours = try container.decode(Int.self, forKey: .hours)
    }
}

public enum ShapedPlanError: Error, LocalizedError {
    case invalidSummary, invalidPhaseCount, invalidTitle, duplicateTitle, invalidHours
    public var errorDescription: String? {
        switch self {
        case .invalidSummary: "The proposed summary must be a nonempty single line of at most 320 characters."
        case .invalidPhaseCount: "The proposed plan must contain 3 to 6 phases."
        case .invalidTitle: "Each proposed phase needs a name of 1 to 3 words, at most 28 characters."
        case .duplicateTitle: "The proposed phase names must be distinct."
        case .invalidHours: "Each proposed phase must contain 1 to 40 whole hours."
        }
    }
}

private struct ShapeKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireShapeKeys(_ expected: Set<String>, decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: ShapeKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                               debugDescription: "The proposed plan contains missing or unexpected fields."))
    }
}
