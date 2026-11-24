import Foundation
import PosternPolicy

/// The protocol between the core and its interfaces on Linux and Windows: the app, the command line, and the
/// Windows app written in C#, which mirrors these types. One JSON object per line, both ways.
///
/// The first line from an interface is a `ControlHello`. Then requests (`id`, `method`, `params`) get one answer
/// each (`id` with `result` or `error`), and the core sends events (`event`, `data`) whenever something changes or an
/// approval waits. The interface only shows and asks: every decision that gives apps more power is proved to the
/// core by the system itself (polkit on Linux, a Windows Hello signature on Windows), never by the interface's word.
public enum ControlWire {
    public static let version = 1

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The first line on a connection: a relay or an interface.
    public struct Hello: Codable, Sendable {
        public enum Role: String, Codable, Sendable { case relay, control }
        public let postern: Role
        public let version: Int
        /// For a relay: the name of the process that launched it (claude, cursor, code…).
        public let client: String?

        public init(postern: Role, version: Int = ControlWire.version, client: String? = nil) {
            self.postern = postern
            self.version = version
            self.client = client
        }
    }

    /// A request from an interface.
    public struct Request: Codable, Sendable {
        public let id: Int
        public let method: String
        public let params: Params?

        public init(id: Int, method: String, params: Params? = nil) {
            self.id = id
            self.method = method
            self.params = params
        }
    }

    /// Every parameter a request may carry; each method reads the ones it needs.
    public struct Params: Codable, Sendable {
        public var policy: Policy?
        public var paused: Bool?
        public var imapPort: Int?
        public var smtpPort: Int?
        public var username: String?
        public var password: String?
        public var fingerprint: String?
        public var app: String?
        public var limit: Int?
        public var id: String?
        public var decision: Decision?
        public var reason: String?
        public var chosen: [String]?
        public var signature: String?
        public var publicKey: String?

        public init(
            policy: Policy? = nil, paused: Bool? = nil, imapPort: Int? = nil, smtpPort: Int? = nil, username: String? = nil,
            password: String? = nil, fingerprint: String? = nil, app: String? = nil, limit: Int? = nil, id: String? = nil,
            decision: Decision? = nil, reason: String? = nil, chosen: [String]? = nil, signature: String? = nil,
            publicKey: String? = nil
        ) {
            self.policy = policy
            self.paused = paused
            self.imapPort = imapPort
            self.smtpPort = smtpPort
            self.username = username
            self.password = password
            self.fingerprint = fingerprint
            self.app = app
            self.limit = limit
            self.id = id
            self.decision = decision
            self.reason = reason
            self.chosen = chosen
            self.signature = signature
            self.publicKey = publicKey
        }
    }

    public enum Decision: String, Codable, Sendable { case send, reject, draft }

    /// An answer or an event from the core.
    public struct Message: Codable, Sendable {
        public var id: Int?
        public var result: Result?
        public var error: Failure?
        public var event: String?
        public var data: Result?

        public init(id: Int? = nil, result: Result? = nil, error: Failure? = nil, event: String? = nil, data: Result? = nil) {
            self.id = id
            self.result = result
            self.error = error
            self.event = event
            self.data = data
        }
    }

    public struct Failure: Codable, Sendable, Error {
        public let code: String
        public let message: String

        public init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    /// What answers and events carry; each holds the parts that apply.
    public struct Result: Codable, Sendable {
        public var status: Status?
        public var tools: [ToolInfo]?
        public var detection: Detection?
        public var mailboxes: [MailboxRow]?
        public var apps: [AppRow]?
        public var activity: [ActivityRow]?
        public var batches: [BatchRow]?
        public var approval: Approval?
        public var text: String?

        public init(
            status: Status? = nil, tools: [ToolInfo]? = nil, detection: Detection? = nil, mailboxes: [MailboxRow]? = nil,
            apps: [AppRow]? = nil, activity: [ActivityRow]? = nil, batches: [BatchRow]? = nil, approval: Approval? = nil,
            text: String? = nil
        ) {
            self.status = status
            self.tools = tools
            self.detection = detection
            self.mailboxes = mailboxes
            self.apps = apps
            self.activity = activity
            self.batches = batches
            self.approval = approval
            self.text = text
        }
    }

    public struct Status: Codable, Sendable {
        public var version: String
        /// The core's process, for a terminal polkit agent on a machine without a desktop.
        public var processID: Int32
        public var system: String
        public var configured: Bool
        /// Why apps cannot be served, when they cannot.
        public var problem: String?
        public var account: String?
        public var imapPort: Int?
        public var smtpPort: Int?
        public var policy: Policy
        public var sendsLastHour: Int
        public var sendsLastDay: Int
        public var connectedApps: [String]
        /// When Proton itself refused for its sending limit, and how many had left in the day before.
        public var protonLimits: [ProtonLimit]
        /// Linux: polkit's actions are installed. Windows: a Windows Hello key is registered.
        public var approvalsReady: Bool
        public var approvalMethod: String
        public var pendingApprovals: Int

        public init(version: String, processID: Int32, system: String, configured: Bool, problem: String?, account: String?, imapPort: Int?, smtpPort: Int?, policy: Policy, sendsLastHour: Int, sendsLastDay: Int, connectedApps: [String], protonLimits: [ProtonLimit], approvalsReady: Bool, approvalMethod: String, pendingApprovals: Int) {
            self.version = version
            self.processID = processID
            self.system = system
            self.configured = configured
            self.problem = problem
            self.account = account
            self.imapPort = imapPort
            self.smtpPort = smtpPort
            self.policy = policy
            self.sendsLastHour = sendsLastHour
            self.sendsLastDay = sendsLastDay
            self.connectedApps = connectedApps
            self.protonLimits = protonLimits
            self.approvalsReady = approvalsReady
            self.approvalMethod = approvalMethod
            self.pendingApprovals = pendingApprovals
        }
    }

    public struct ProtonLimit: Codable, Sendable {
        public let date: Date
        public let sentInLastDay: Int

        public init(date: Date, sentInLastDay: Int) {
            self.date = date
            self.sentInLastDay = sentInLastDay
        }
    }

    public struct ToolInfo: Codable, Sendable {
        public let id: String
        public let tier: String
        public let title: String
        public let summary: String
        public let risk: String
        public let enabled: Bool

        public init(id: String, tier: String, title: String, summary: String, risk: String, enabled: Bool) {
            self.id = id
            self.tier = tier
            self.title = title
            self.summary = summary
            self.risk = risk
            self.enabled = enabled
        }
    }

    public struct Detection: Codable, Sendable {
        public let bridgeVersion: String?
        public let imapPort: Int
        public let smtpPort: Int
        public let imapMode: String
        public let smtpMode: String
        /// The certificate's SHA-256, to compare with the one Bridge shows under Settings › Advanced.
        public let fingerprint: String

        public init(bridgeVersion: String?, imapPort: Int, smtpPort: Int, imapMode: String, smtpMode: String, fingerprint: String) {
            self.bridgeVersion = bridgeVersion
            self.imapPort = imapPort
            self.smtpPort = smtpPort
            self.imapMode = imapMode
            self.smtpMode = smtpMode
            self.fingerprint = fingerprint
        }
    }

    public struct MailboxRow: Codable, Sendable {
        public let name: String
        public let kind: String
        public let hidden: Bool

        public init(name: String, kind: String, hidden: Bool) {
            self.name = name
            self.kind = kind
            self.hidden = hidden
        }
    }

    public struct AppRow: Codable, Sendable {
        public let id: String
        public let title: String
        public let path: String
        public let installed: Bool
        /// connected, notConnected, otherCommand, unreadable
        public let status: String

        public init(id: String, title: String, path: String, installed: Bool, status: String) {
            self.id = id
            self.title = title
            self.path = path
            self.installed = installed
            self.status = status
        }
    }

    public struct ActivityRow: Codable, Sendable {
        public let date: Date
        public let client: String
        public let tool: String
        public let outcome: String
        public let items: Int?

        public init(date: Date, client: String, tool: String, outcome: String, items: Int?) {
            self.date = date
            self.client = client
            self.tool = tool
            self.outcome = outcome
            self.items = items
        }
    }

    public struct BatchRow: Codable, Sendable {
        public let id: String
        public let kind: String
        public let client: String
        public let created: Date
        public let total: Int
        public let done: Int
        public let waiting: Int
        public let failed: Int
        public let phase: String
        public let reason: String?
        public let interrupted: Bool

        public init(id: String, kind: String, client: String, created: Date, total: Int, done: Int, waiting: Int, failed: Int, phase: String, reason: String?, interrupted: Bool) {
            self.id = id
            self.kind = kind
            self.client = client
            self.created = created
            self.total = total
            self.done = done
            self.waiting = waiting
            self.failed = failed
            self.phase = phase
            self.reason = reason
            self.interrupted = interrupted
        }
    }

    /// An approval waiting for the user: everything the panel shows.
    public struct Approval: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case email, batch, deletion }
        public let id: String
        public let kind: Kind
        public let client: String
        public let tool: String
        public let deadline: Date
        public let context: String?
        public let email: Email?
        public let batch: [Email]?
        public let deletion: [DeletionRow]?
        public let permanent: Bool

        public init(id: String, kind: Kind, client: String, tool: String, deadline: Date, context: String?, email: Email?, batch: [Email]?, deletion: [DeletionRow]?, permanent: Bool) {
            self.id = id
            self.kind = kind
            self.client = client
            self.tool = tool
            self.deadline = deadline
            self.context = context
            self.email = email
            self.batch = batch
            self.deletion = deletion
            self.permanent = permanent
        }
    }

    public struct Email: Codable, Sendable {
        public let id: String
        public let from: String
        public let to: [String]
        public let cc: [String]
        public let bcc: [String]
        public let subject: String
        public let body: String
        public let quoted: String?
        public let attachments: [Attachment]
        /// Per address: firstContact, cameFromEmail, replyToDiffers, trusted.
        public let badges: [String: [String]]
        public let missingAttachment: String?

        public init(id: String, from: String, to: [String], cc: [String], bcc: [String], subject: String, body: String, quoted: String?, attachments: [Attachment], badges: [String: [String]], missingAttachment: String?) {
            self.id = id
            self.from = from
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = subject
            self.body = body
            self.quoted = quoted
            self.attachments = attachments
            self.badges = badges
            self.missingAttachment = missingAttachment
        }
    }

    public struct Attachment: Codable, Sendable {
        public let name: String
        public let type: String
        public let size: Int

        public init(name: String, type: String, size: Int) {
            self.name = name
            self.type = type
            self.size = size
        }
    }

    public struct DeletionRow: Codable, Sendable {
        public let mailbox: String
        public let from: String
        public let subject: String
        public let date: Date?

        public init(mailbox: String, from: String, subject: String, date: Date?) {
            self.mailbox = mailbox
            self.from = from
            self.subject = subject
            self.date = date
        }
    }
}
