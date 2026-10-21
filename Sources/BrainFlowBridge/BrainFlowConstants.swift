/// Hand-mirrored subset of native/brainflow/include/brainflow_constants.h (BrainFlow 5.23.0).
/// That header uses C++ `enum class`, so it cannot be imported through the C module map.
/// Verify against the header whenever scripts/vendor_brainflow.sh bumps the version.
public enum BrainFlowExitCode: Int32, Sendable {
    case statusOK = 0
    case portAlreadyOpen = 1
    case unableToOpenPort = 2
    case setPortError = 3
    case boardWriteError = 4
    case incomingMsgError = 5
    case initialMsgError = 6
    case boardNotReady = 7
    case streamAlreadyRun = 8
    case invalidBufferSize = 9
    case streamThreadError = 10
    case streamThreadIsNotRunning = 11
    case emptyBufferError = 12
    case invalidArguments = 13
    case unsupportedBoard = 14
    case boardNotCreated = 15
    case anotherBoardIsCreated = 16
    case generalError = 17
    case syncTimeoutError = 18
    case jsonNotFound = 19
    case noSuchDataInJson = 20
    case classifierIsNotPrepared = 21
    case anotherClassifierIsPrepared = 22
    case unsupportedClassifierAndMetric = 23
}

public enum BrainFlowPreset: Int32, Sendable {
    case `default` = 0
    case auxiliary = 1
    case ancillary = 2
}

public enum BrainFlowLogLevel: Int32, Sendable {
    case trace = 0, debug = 1, info = 2, warn = 3, error = 4, critical = 5, off = 6
}

public enum KnownBoard {
    public static let playbackFile: Int32 = -3
    public static let streaming: Int32 = -2
    public static let synthetic: Int32 = -1
    public static let cyton: Int32 = 0
    public static let ganglion: Int32 = 1
    public static let cytonDaisy: Int32 = 2
}
