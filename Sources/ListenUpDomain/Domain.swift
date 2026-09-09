import Foundation

public enum SessionPurpose: String, Codable, CaseIterable, Sendable {
    case lecture
    case meeting

    public var displayName: String { self == .lecture ? "강의" : "회의" }
}

public enum InputSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case systemAudio
    case microphoneAndSystem
    case importedFile
}

public enum CaptureStatus: String, Codable, Sendable {
    case idle, preparing, recording, paused, stopping, stopped, interrupted
}

public enum ProcessingStatus: String, Codable, Sendable {
    case notStarted, preparing, transcribing, summarizing, ready, paused, partial, failed, cancelled
}

public enum TimePrecision: String, Codable, Sendable { case chunk, segment, word }
public enum SourceTrack: String, Codable, Sendable { case microphone, system, mixed, imported }
public enum GapReason: String, Codable, Sendable { case permission, device, disk, pause, sleep, unknown }
public enum AnnotationKind: String, Codable, Sendable { case bookmark, note, replayRange, textExclusion }
public enum ProcessingLocation: String, Codable, Sendable { case local, cloud }

public struct SessionContext: Codable, Equatable, Sendable {
    public var languages: [String]
    public var keywords: [String]
    public var notes: String

    public init(languages: [String] = ["ko"], keywords: [String] = [], notes: String = "") {
        self.languages = languages
        self.keywords = keywords
        self.notes = notes
    }
}

public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public var sttModelID: String
    public var sttRevision: String
    public var summaryModelID: String
    public var summaryRevision: String
    public var sttLocation: ProcessingLocation
    public var summaryLocation: ProcessingLocation

    public init(
        sttModelID: String = "gpt-transcribe",
        sttRevision: String = "openai-api",
        summaryModelID: String = "gpt-5.6-luna",
        summaryRevision: String = "openai-api",
        sttLocation: ProcessingLocation = .cloud,
        summaryLocation: ProcessingLocation = .cloud
    ) {
        self.sttModelID = sttModelID
        self.sttRevision = sttRevision
        self.summaryModelID = summaryModelID
        self.summaryRevision = summaryRevision
        self.sttLocation = sttLocation
        self.summaryLocation = summaryLocation
    }
}

public struct AudioSpan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trackID: String
    public var relativePath: String
    public var inputOffsetMs: Int64
    public var durationMs: Int64
    public var sessionStartMs: Int64
    public var sampleRate: Double
    public var frameCount: Int64
    public var checksum: String

    public init(id: UUID = UUID(), trackID: String, relativePath: String, inputOffsetMs: Int64 = 0, durationMs: Int64, sessionStartMs: Int64, sampleRate: Double, frameCount: Int64, checksum: String) {
        self.id = id; self.trackID = trackID; self.relativePath = relativePath
        self.inputOffsetMs = inputOffsetMs; self.durationMs = durationMs; self.sessionStartMs = sessionStartMs
        self.sampleRate = sampleRate; self.frameCount = frameCount; self.checksum = checksum
    }
}

public struct Gap: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startMs: Int64
    public var endMs: Int64?
    public var reason: GapReason
    public var recovered: Bool
    public init(id: UUID = UUID(), startMs: Int64, endMs: Int64? = nil, reason: GapReason, recovered: Bool = false) {
        self.id = id; self.startMs = startMs; self.endMs = endMs; self.reason = reason; self.recovered = recovered
    }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    public var timePrecision: TimePrecision
    public var sourceTrack: SourceTrack
    public var speakerID: String?
    public var requestID: String
    public var revision: Int
    public var confidence: Double?

    public init(id: String = UUID().uuidString, text: String, startMs: Int64, endMs: Int64, timePrecision: TimePrecision = .segment, sourceTrack: SourceTrack = .mixed, speakerID: String? = nil, requestID: String, revision: Int = 1, confidence: Double? = nil) {
        self.id = id; self.text = text; self.startMs = startMs; self.endMs = endMs
        self.timePrecision = timePrecision; self.sourceTrack = sourceTrack; self.speakerID = speakerID
        self.requestID = requestID; self.revision = revision; self.confidence = confidence
    }
}

public struct Coverage: Codable, Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    public var failedRanges: [Gap]
    public var isComplete: Bool { failedRanges.isEmpty }
    public init(startMs: Int64, endMs: Int64, failedRanges: [Gap] = []) {
        self.startMs = startMs; self.endMs = endMs; self.failedRanges = failedRanges
    }
}

public struct TranscriptRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var parentID: String?
    public var originalResponseReferences: [String]
    public var segments: [TranscriptSegment]
    public var coverage: Coverage
    public var createdAt: Date
    public var modelID: String
    public var configurationHash: String

    public init(id: String, parentID: String? = nil, originalResponseReferences: [String] = [], segments: [TranscriptSegment], coverage: Coverage, createdAt: Date = Date(), modelID: String, configurationHash: String) {
        self.id = id; self.parentID = parentID; self.originalResponseReferences = originalResponseReferences
        self.segments = segments; self.coverage = coverage; self.createdAt = createdAt
        self.modelID = modelID; self.configurationHash = configurationHash
    }
}

public struct TextSelection: Codable, Equatable, Sendable {
    public var segmentID: String
    public var range: Range<Int>
    public init(segmentID: String, range: Range<Int>) { self.segmentID = segmentID; self.range = range }
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var startMs: Int64
    public var endMs: Int64?
    public var textSelection: TextSelection?
    public var content: String
    public var excludedFromSummary: Bool
    public var revision: Int
    public init(id: UUID = UUID(), kind: AnnotationKind, startMs: Int64, endMs: Int64? = nil, textSelection: TextSelection? = nil, content: String = "", excludedFromSummary: Bool = false, revision: Int = 1) {
        self.id = id; self.kind = kind; self.startMs = startMs; self.endMs = endMs
        self.textSelection = textSelection; self.content = content; self.excludedFromSummary = excludedFromSummary; self.revision = revision
    }
}

public struct AnnotationRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var parentID: String?
    public var annotations: [Annotation]
    public var createdAt: Date
    public init(id: String, parentID: String? = nil, annotations: [Annotation] = [], createdAt: Date = Date()) {
        self.id = id; self.parentID = parentID; self.annotations = annotations; self.createdAt = createdAt
    }
}

public struct SummaryItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var evidenceSegmentIDs: [String]
    public var generated: Bool
    public init(id: UUID = UUID(), text: String, evidenceSegmentIDs: [String] = [], generated: Bool = false) {
        self.id = id; self.text = text; self.evidenceSegmentIDs = evidenceSegmentIDs; self.generated = generated
    }
}

public struct ActionItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var task: String
    public var owner: String?
    public var dueOriginal: String?
    public var dueNormalized: String?
    public var evidenceSegmentIDs: [String]
    public init(id: UUID = UUID(), task: String, owner: String? = nil, dueOriginal: String? = nil, dueNormalized: String? = nil, evidenceSegmentIDs: [String]) {
        self.id = id; self.task = task; self.owner = owner; self.dueOriginal = dueOriginal
        self.dueNormalized = dueNormalized; self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

public struct SummarySections: Codable, Equatable, Sendable {
    public var overview: [SummaryItem]
    public var topics: [SummaryItem]
    public var concepts: [SummaryItem]
    public var examples: [SummaryItem]
    public var emphasizedPoints: [SummaryItem]
    public var reviewQuestions: [SummaryItem]
    public var agendaItems: [SummaryItem]
    public var decisions: [SummaryItem]
    public var actionItems: [ActionItem]
    public var openIssues: [SummaryItem]
    public var disagreements: [SummaryItem]
    public var uncertainties: [SummaryItem]

    public init(overview: [SummaryItem] = [], topics: [SummaryItem] = [], concepts: [SummaryItem] = [], examples: [SummaryItem] = [], emphasizedPoints: [SummaryItem] = [], reviewQuestions: [SummaryItem] = [], agendaItems: [SummaryItem] = [], decisions: [SummaryItem] = [], actionItems: [ActionItem] = [], openIssues: [SummaryItem] = [], disagreements: [SummaryItem] = [], uncertainties: [SummaryItem] = []) {
        self.overview = overview; self.topics = topics; self.concepts = concepts; self.examples = examples
        self.emphasizedPoints = emphasizedPoints; self.reviewQuestions = reviewQuestions; self.agendaItems = agendaItems
        self.decisions = decisions; self.actionItems = actionItems; self.openIssues = openIssues
        self.disagreements = disagreements; self.uncertainties = uncertainties
    }
}

public struct SummaryRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var purpose: SessionPurpose
    public var sourceTranscriptRevisionID: String
    public var annotationRevisionID: String
    public var promptVersion: String
    public var modelID: String
    public var sections: SummarySections
    public var inputHash: String
    public var createdAt: Date
    public init(id: String, purpose: SessionPurpose, sourceTranscriptRevisionID: String, annotationRevisionID: String, promptVersion: String, modelID: String, sections: SummarySections, inputHash: String, createdAt: Date = Date()) {
        self.id = id; self.purpose = purpose; self.sourceTranscriptRevisionID = sourceTranscriptRevisionID
        self.annotationRevisionID = annotationRevisionID; self.promptVersion = promptVersion; self.modelID = modelID
        self.sections = sections; self.inputHash = inputHash; self.createdAt = createdAt
    }
}

public struct Session: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var purpose: SessionPurpose
    public var inputSource: InputSource
    public var createdAt: Date
    public var timeZoneIdentifier: String
    public var captureStatus: CaptureStatus
    public var processingStatus: ProcessingStatus
    public var revision: Int
    public var lastJournalSequence: Int64
    public var tracks: [AudioSpan]
    public var gaps: [Gap]
    public var context: SessionContext
    public var activeTranscriptRevisionID: String?
    public var activeAnnotationRevisionID: String?
    public var activeSummaryRevisionID: String?
    public var summaryStale: Bool
    public var providerConfiguration: ProviderConfiguration

    public init(id: UUID = UUID(), title: String, purpose: SessionPurpose, inputSource: InputSource, createdAt: Date = Date(), timeZoneIdentifier: String = TimeZone.current.identifier, captureStatus: CaptureStatus = .idle, processingStatus: ProcessingStatus = .notStarted, revision: Int = 0, lastJournalSequence: Int64 = 0, tracks: [AudioSpan] = [], gaps: [Gap] = [], context: SessionContext = .init(), activeTranscriptRevisionID: String? = nil, activeAnnotationRevisionID: String? = nil, activeSummaryRevisionID: String? = nil, summaryStale: Bool = false, providerConfiguration: ProviderConfiguration = .init()) {
        self.schemaVersion = Self.currentSchemaVersion; self.id = id; self.title = title; self.purpose = purpose
        self.inputSource = inputSource; self.createdAt = createdAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.captureStatus = captureStatus; self.processingStatus = processingStatus; self.revision = revision
        self.lastJournalSequence = lastJournalSequence; self.tracks = tracks; self.gaps = gaps; self.context = context
        self.activeTranscriptRevisionID = activeTranscriptRevisionID; self.activeAnnotationRevisionID = activeAnnotationRevisionID
        self.activeSummaryRevisionID = activeSummaryRevisionID; self.summaryStale = summaryStale
        self.providerConfiguration = providerConfiguration
    }
}

public enum ListenUpError: Error, Codable, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidTimeRange
    case invalidRelativePath(String)
    case missingReference(String)
    case permissionDenied
    case sourceUnavailable
    case deviceChanged
    case diskFull
    case writeFailed(String)
    case modelUnavailable(String)
    case invalidModelResponse(String)
    case summaryInvalid(String)
    case sessionMoved
}

public enum DomainValidator {
    public static func validate(_ session: Session) throws {
        guard session.schemaVersion == Session.currentSchemaVersion else { throw ListenUpError.unsupportedSchema(session.schemaVersion) }
        for span in session.tracks {
            guard span.durationMs >= 0, span.sessionStartMs >= 0, span.inputOffsetMs >= 0, span.sampleRate > 0, span.frameCount >= 0 else { throw ListenUpError.invalidTimeRange }
            try validateRelativePath(span.relativePath)
        }
        for gap in session.gaps { try validate(start: gap.startMs, end: gap.endMs) }
    }

    public static func validate(_ revision: TranscriptRevision) throws {
        try validate(start: revision.coverage.startMs, end: revision.coverage.endMs)
        var ids = Set<String>()
        for segment in revision.segments {
            try validate(start: segment.startMs, end: segment.endMs)
            guard segment.startMs >= revision.coverage.startMs, segment.endMs <= revision.coverage.endMs else { throw ListenUpError.invalidTimeRange }
            guard ids.insert(segment.id).inserted else { throw ListenUpError.missingReference("duplicate segment: \(segment.id)") }
        }
    }

    public static func validate(_ summary: SummaryRevision, transcript: TranscriptRevision) throws {
        guard summary.sourceTranscriptRevisionID == transcript.id else { throw ListenUpError.missingReference(summary.sourceTranscriptRevisionID) }
        let validIDs = Set(transcript.segments.map(\.id))
        let evidence = allSummaryEvidence(summary.sections)
        guard evidence.allSatisfy(validIDs.contains) else { throw ListenUpError.missingReference("summary evidence") }
    }

    public static func validateRelativePath(_ path: String) throws {
        // A backslash is a legal filename character on macOS. Only forward slashes
        // delimit path components, and containment is checked again by SessionStore.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." })
        else { throw ListenUpError.invalidRelativePath(path) }
    }

    private static func validate(start: Int64, end: Int64?) throws {
        guard start >= 0, end.map({ $0 >= start }) ?? true else { throw ListenUpError.invalidTimeRange }
    }

    private static func allSummaryEvidence(_ sections: SummarySections) -> [String] {
        let items = sections.overview + sections.topics + sections.concepts + sections.examples + sections.emphasizedPoints + sections.reviewQuestions + sections.agendaItems + sections.decisions + sections.openIssues + sections.disagreements + sections.uncertainties
        return items.flatMap(\.evidenceSegmentIDs) + sections.actionItems.flatMap(\.evidenceSegmentIDs)
    }
}
