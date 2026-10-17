import Foundation

/// The error's own text, for the **diagnostic profile only**: description, file/URL user-info
/// values and the underlying-error chain. Strict reports never call this (they use
/// `CrashReportingConfiguration.describeError`).
enum ErrorDetail {
    static let maxLength = 4_096
    /// Errors printed: the error itself plus up to `maxDepth - 1` underlying errors.
    static let maxDepth = 3
    /// User-info values worth printing. Others can be arbitrary objects (data blobs, nested
    /// dictionaries) and are left out.
    static let userInfoKeys = [
        NSFilePathErrorKey, NSURLErrorKey, NSLocalizedFailureReasonErrorKey,
        NSLocalizedRecoverySuggestionErrorKey, NSDebugDescriptionErrorKey
    ]

    static func text(for error: any Error) -> String {
        var lines: [String] = []
        append(error, depth: 0, to: &lines)
        let text = lines.joined(separator: "\n")
        return text.count <= maxLength ? text : String(text.prefix(maxLength)) + "…"
    }

    private static func append(_ error: any Error, depth: Int, to lines: inout [String]) {
        let nsError = error as NSError
        let prefix = depth == 0 ? "" : "caused by: "
        if type(of: error) is NSError.Type {
            lines.append("\(prefix)\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
        } else {
            lines.append("\(prefix)\(String(reflecting: error)): \(nsError.localizedDescription)")
        }
        for key in userInfoKeys {
            if let value = nsError.userInfo[key] { lines.append("  \(key): \(value)") }
        }
        if depth + 1 < maxDepth, let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            append(underlying, depth: depth + 1, to: &lines)
        }
    }
}
