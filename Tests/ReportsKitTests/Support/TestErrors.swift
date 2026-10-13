import Foundation
@testable import ReportsKit

/// Stand-in for an app's `describeError`: static type name and numeric code only.
enum TestErrors {
    @Sendable static func describe(_ error: any Error) -> String {
        "\(type(of: error)) code=\((error as NSError).code)"
    }
}

/// Operations the tests capture under, declared the way an app declares its own.
extension CrashReporting.Operation {
    static let exportPrepare = Self("exportPrepare")
    static let exportSave = Self("exportSave")
    static let profileSave = Self("profileSave")
    static let deviceStart = Self("deviceStart")
}
