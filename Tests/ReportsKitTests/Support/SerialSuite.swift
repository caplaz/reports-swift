import Testing

/// Every test touching process-wide state (SentrySDK, ConsentGate.shared, protocol statics)
/// lives in an extension of this suite so they run one at a time.
@Suite(.serialized) struct SerialSuite {}
