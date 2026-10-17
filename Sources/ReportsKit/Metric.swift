import Foundation

extension CrashReporting {
    /// A metric the app records (counter, distribution or gauge). Declare each one once, as a
    /// static constant:
    ///
    /// ```swift
    /// extension CrashReporting.Metric {
    ///     static let exportDuration = Self(
    ///         "export.duration", kind: .distribution, unit: .millisecond,
    ///         attributes: ["format": ["cube", "3dl"], "outcome": Self.outcomes])
    /// }
    /// ```
    ///
    /// The name, every attribute key and every allowed value are static identifiers written in
    /// source — never user data (file names, paths, text, identifiers). When recording, keys not
    /// declared here are dropped and values not declared for their key are sent as `other`.
    /// An invalid declaration traps the first time it is used: touch every declaration in a test.
    public struct Metric: Sendable, Hashable {
        public enum Kind: String, Sendable { case counter, distribution, gauge }
        /// Counters have no unit.
        public enum Unit: String, Sendable { case none, millisecond, second, byte, percent, ratio }

        public static let outcomeKey = "outcome"
        public static let outcomes: Set<String> = ["success", "failure", "cancelled"]
        /// Sent in place of a value that isn't declared for its key.
        public static let otherValue = "other"
        static let maxAttributeKeys = 4
        static let maxValuesPerKey = 64
        /// Keys the SDK or ReportsKit own; an app attribute must never shadow them.
        static let reservedKeyPrefixes = ["sentry.", "user.", "os.", "device.", "report."]

        public let name: String
        public let kind: Kind
        public let unit: Unit
        /// Allowed attribute keys and, per key, every value it may take.
        public let attributes: [String: Set<String>]

        public init(_ name: StaticString, kind: Kind, unit: Unit = .none, attributes: [String: Set<String>] = [:]) {
            let name = name.description
            precondition(Self.isValidName(name), "invalid metric name \(name)")
            precondition(kind != .counter || unit == .none, "counter \(name) cannot have a unit")
            precondition(attributes.count <= Self.maxAttributeKeys,
                         "metric \(name) declares more than \(Self.maxAttributeKeys) attributes")
            for (key, values) in attributes {
                precondition(Self.isValidKey(key), "metric \(name): invalid attribute key \(key)")
                precondition(!values.isEmpty && values.count <= Self.maxValuesPerKey,
                             "metric \(name): \(key) needs 1...\(Self.maxValuesPerKey) values")
                precondition(values.allSatisfy(Self.isValidValue), "metric \(name): invalid value for \(key)")
            }
            self.name = name
            self.kind = kind
            self.unit = unit
            self.attributes = attributes
        }

        /// `^[a-z][a-z0-9_.]{0,63}$`
        static func isValidName(_ text: String) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard let first = scalars.first, scalars.count <= 64, ("a"..."z").contains(first) else { return false }
            return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "." }
        }

        static func isValidKey(_ key: String) -> Bool {
            isValidName(key) && !reservedKeyPrefixes.contains { key.hasPrefix($0) }
        }

        /// `^[A-Za-z0-9_.-]{1,64}$`
        static func isValidValue(_ text: String) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard (1...64).contains(scalars.count) else { return false }
            return scalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                    || $0 == "_" || $0 == "." || $0 == "-"
            }
        }

        /// The attributes actually sent: declared keys only; undeclared values become `other`.
        func filtered(_ values: [String: String]) -> [String: String] {
            var result: [String: String] = [:]
            for (key, value) in values {
                guard let allowed = attributes[key] else { continue }
                result[key] = allowed.contains(value) ? value : Self.otherValue
            }
            return result
        }
    }
}
