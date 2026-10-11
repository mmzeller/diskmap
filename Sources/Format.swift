import Foundation

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func signedBytes(_ value: Int64) -> String {
        let magnitude = byteFormatter.string(fromByteCount: value < 0 ? -value : value)
        return value < 0 ? "−" + magnitude : "+" + magnitude
    }

    static func count(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) sec" }
        return "\(whole / 60) min \(whole % 60) sec"
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "—" }
        let value = Double(part) / Double(whole) * 100
        if value < 0.1 { return "<0.1%" }
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }
}
