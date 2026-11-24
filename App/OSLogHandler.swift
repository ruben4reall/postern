import Foundation
import Logging
import OSLog

/// Sends the core's swift-log messages to the unified log, under Postern's subsystem. The core only logs failures
/// and metadata (error kinds, host names, verdict levels), never a secret or a message's content, so the text is
/// public.
struct OSLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info
    private let log: os.Logger

    init(label: String) {
        let category = label.split(separator: ".").last.map(String.init) ?? label
        log = os.Logger(subsystem: "ch.rubencatalao.postern", category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logging.Logger.Level, message: Logging.Logger.Message, metadata: Logging.Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        let text = message.description
        switch level {
        case .trace, .debug: log.debug("\(text, privacy: .public)")
        case .info, .notice: log.info("\(text, privacy: .public)")
        case .warning, .error: log.error("\(text, privacy: .public)")
        case .critical: log.fault("\(text, privacy: .public)")
        }
    }
}
