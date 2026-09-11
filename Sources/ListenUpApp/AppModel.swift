import AppKit
@preconcurrency import AVFoundation
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import ListenUpAI
import ListenUpAudio
import ListenUpDomain
import ListenUpExport
import ListenUpStorage

@MainActor
final class AppModel: ObservableObject {
    @Published var title = ""
    @Published var purpose: SessionPurpose = .lecture
    @Published var inputSource: InputSource = .microphone
    @Published var languages = "ko"
    @Published var keywords = ""
    @Published var notes = ""
    @Published var rootDirectory: URL?
    @Published var availableApplications: [CaptureApplication] = []
    @Published private(set) var hasAttemptedApplicationDiscovery = false
    @Published var selectedApplicationID: String?
    @Published var session: Session?
    @Published var elapsedMs: Int64 = 0
    @Published var notice = "저장 폴더를 선택하면 녹음을 시작할 수 있습니다."
    /// Setup guidance remains on the recording screen; processing feedback is kept
    /// with the result so changing tabs cannot hide an error the user is waiting on.
    @Published var resultNotice = ""
    @Published var apiNotice = "OpenAI API 키를 설정해 주세요."
    @Published var apiKeyDraft = ""
    @Published var hasAPIKey = false
    @Published var transcriptionModelID = UserDefaults.standard.string(forKey: "ListenUpTranscriptionModel") ?? OpenAIConfiguration.defaultTranscriptionModel {
        didSet { UserDefaults.standard.set(transcriptionModelID, forKey: "ListenUpTranscriptionModel") }
    }
    @Published var summaryModelID = UserDefaults.standard.string(forKey: "ListenUpSummaryModel") ?? OpenAIConfiguration.defaultSummaryModel {
        didSet { UserDefaults.standard.set(summaryModelID, forKey: "ListenUpSummaryModel") }
    }
    @Published var isBusy = false
    @Published var showResults = false
    @Published var transcript: TranscriptRevision?
    @Published var summary: SummaryRevision?
    @Published var transcriptDraft = ""
    @Published var summaryExclusions: [Annotation] = []
    @Published var exclusionStartSeconds = 0
    @Published var exclusionEndSeconds = 30
    @Published var editingExclusionID: UUID?
    @Published private(set) var captureActive = false
    @Published var processingProgress = ""

    private var store: SessionStore?
    private var microphone: MicrophoneCapture?
    private var systemAudio: SystemAudioRecorder?
    private var replay: ReplayEngine?
    private var timer: Timer?
    private var recordingBeganAt: Date?
    private var pendingChunks: [(URL, SourceTrack, Int64?)] = []
    private var isRegisteringChunk = false
    private var captureFailureMessage: String?
    private var scopedRootURL: URL?
    private var applicationDiscoveryBlockedByPermission = false
    private let recordingIndicator = RecordingIndicatorController()

    init() {
        hasAPIKey = OpenAIKeychain.load()?.isEmpty == false
        apiNotice = hasAPIKey ? "OpenAI API 키가 macOS 키체인에 저장되어 있습니다." : "OpenAI API 키를 설정해 주세요."
        restoreRootDirectory()
    }

    var isRecording: Bool { captureActive }
    var selectedApplication: CaptureApplication? {
        availableApplications.first { $0.id == selectedApplicationID }
    }
    var requiresMicrophone: Bool { inputSource == .microphone || inputSource == .microphoneAndSystem }
    var requiresSystemAudio: Bool { inputSource == .systemAudio || inputSource == .microphoneAndSystem }
    var canStartAPIProcessing: Bool { hasAPIKey && !isBusy }

    var hasCompleteTranscript: Bool { transcript?.coverage.isComplete == true }

    func chooseRootDirectory() {
        let panel = NSOpenPanel()
        panel.title = "ListenUp 녹음 저장 폴더"
        panel.prompt = "이 폴더 사용"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootDirectory = url
        scopedRootURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        scopedRootURL = url
        saveRootDirectory(url)
        notice = "녹음과 결과를 \(url.lastPathComponent)에 저장합니다."
    }

    func refreshApplications() async {
        hasAttemptedApplicationDiscovery = true
        guard !applicationDiscoveryBlockedByPermission else {
            notice = "화면 및 시스템 오디오 녹음 권한 변경은 ListenUp을 완전히 종료하고 다시 열면 적용됩니다."
            return
        }
        do {
            let recorder = SystemAudioRecorder()
            availableApplications = try await recorder.availableApplications()
            if selectedApplication == nil { selectedApplicationID = availableApplications.first?.id }
            if availableApplications.isEmpty {
                notice = "녹음할 수 있는 실행 중인 앱을 찾지 못했습니다. 대상 앱을 먼저 실행한 뒤 목록을 새로 고침해 주세요."
            }
        } catch {
            availableApplications = []
            if Self.isScreenCapturePermissionError(error) {
                applicationDiscoveryBlockedByPermission = true
                notice = "앱 소리를 사용하려면 시스템 설정의 ‘화면 및 시스템 오디오 녹음’에서 ListenUp을 허용한 뒤 앱을 완전히 종료하고 다시 열어 주세요."
            } else {
                notice = "녹음 가능한 앱 목록을 불러오지 못했습니다. ListenUp을 다시 연 뒤에도 계속되면 목록 새로 고침을 눌러 주세요. (\(error.localizedDescription))"
            }
        }
    }

    func loadApplicationsIfNeeded() async {
        guard !hasAttemptedApplicationDiscovery, availableApplications.isEmpty else { return }
        await refreshApplications()
    }

    func startRecording() async {
        guard !isBusy, !isRecording else { return }
        guard let rootDirectory else { notice = "먼저 저장 폴더를 선택해 주세요."; return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { notice = "녹음 제목을 입력해 주세요."; return }
        if requiresSystemAudio && selectedApplication == nil {
            notice = "녹음할 앱을 선택해 주세요. 앱이 보이지 않으면 목록을 새로 고침하세요."
            return
        }

        isBusy = true
        resetSessionPresentation()
        captureFailureMessage = nil
        var newSession = Session(
            title: cleanTitle,
            purpose: purpose,
            inputSource: inputSource,
            captureStatus: .preparing,
            context: SessionContext(
                languages: languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                keywords: keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                notes: notes
            ),
            providerConfiguration: selectedProviderConfiguration
        )
        do {
            let newStore = try SessionStore.create(in: rootDirectory, session: newSession)
            store = newStore
            let directory = await newStore.sessionDirectory
            let microphoneDirectory = directory.appendingPathComponent("audio/microphone", isDirectory: true)
            let systemDirectory = directory.appendingPathComponent("audio/system", isDirectory: true)
            captureActive = true

            if requiresMicrophone {
                let capture = MicrophoneCapture()
                capture.onFinalizedTimedChunk = { [weak self] url, sessionStartMs in
                    Task { @MainActor in self?.enqueueChunk(url, track: .microphone, sessionStartMs: sessionStartMs) }
                }
                capture.onError = { [weak self] error in
                    Task { @MainActor in await self?.handleCaptureFailure(error) }
                }
                try capture.start(directory: microphoneDirectory)
                microphone = capture
            }

            if requiresSystemAudio {
                let capture = SystemAudioRecorder()
                capture.onFinalizedTimedChunk = { [weak self] url, sessionStartMs in
                    Task { @MainActor in self?.enqueueChunk(url, track: .system, sessionStartMs: sessionStartMs) }
                }
                capture.onError = { [weak self] error in
                    Task { @MainActor in await self?.handleCaptureFailure(error) }
                }
                do {
                    try await capture.start(directory: systemDirectory, application: selectedApplication)
                    systemAudio = capture
                } catch {
                    microphone?.stop()
                    microphone = nil
                    throw error
                }
            }

            newSession.captureStatus = .recording
            session = try await newStore.updateSession { stored in stored.captureStatus = .recording }
            replay = ReplayEngine(sessionDirectory: directory)
            recordingBeganAt = Date()
            elapsedMs = 0
            startTimer()
            recordingIndicator.show()
            notice = "녹음 중입니다. 녹음을 끝낸 뒤 OpenAI API로 전사와 요약을 진행할 수 있습니다."
        } catch {
            microphone?.stop()
            microphone = nil
            try? await systemAudio?.stop()
            systemAudio = nil
            captureActive = false
            recordingIndicator.hide()
            newSession.captureStatus = .interrupted
            session = newSession
            notice = "녹음을 시작하지 못했습니다: \(error.localizedDescription)"
        }
        isBusy = false
    }

    func stopRecording() async {
        guard captureActive, !isBusy else { return }
        isBusy = true
        captureActive = false
        recordingIndicator.hide()
        timer?.invalidate()
        timer = nil
        microphone?.stop()
        microphone = nil
        do { try await systemAudio?.stop() }
        catch { captureFailureMessage = "시스템 오디오 종료: \(error.localizedDescription)" }
        systemAudio = nil
        await Task.yield()
        await waitForPendingChunks()
        if let store {
            do {
                if let captureFailureMessage {
                    let failureMs = elapsedMs
                    session = try await store.updateSession { value in
                        value.captureStatus = .interrupted
                        if value.gaps.last?.startMs != failureMs {
                            value.gaps.append(Gap(startMs: failureMs, reason: .unknown))
                        }
                    }
                    notice = "녹음은 끝났지만 오디오 저장 오류가 있었습니다: \(captureFailureMessage)"
                } else {
                    session = try await store.updateSession { value in
                        value.captureStatus = .stopped
                        value.processingStatus = .notStarted
                    }
                    notice = hasAPIKey
                        ? "녹음을 저장했습니다. 현재 결과에서 OpenAI 전사와 요약을 시작할 수 있습니다."
                        : "녹음을 저장했습니다. OpenAI API 키를 설정한 뒤 전사와 요약을 시작할 수 있습니다."
                }
            } catch {
                notice = "녹음은 끝났지만 세션 정보를 확정하지 못했습니다: \(error.localizedDescription)"
            }
        }
        isBusy = false
    }

    func rewind() async {
        guard let replay else { notice = "재생할 확정 오디오가 아직 없습니다."; return }
        await replay.update(spans: session?.tracks ?? [], liveHeadMs: elapsedMs)
        await replay.seek(to: elapsedMs)
        await replay.rewind15Seconds()
        do { try await replay.play(); notice = "15초 전부터 다시 듣는 중입니다. 녹음은 계속됩니다." }
        catch { notice = "재생할 확정 오디오가 아직 없습니다." }
    }

    func stopReplay() async {
        await replay?.stop()
        notice = isRecording ? "다시 듣기를 멈췄습니다. 녹음은 계속됩니다." : "재생을 멈췄습니다."
    }

    func returnToLive() async {
        await replay?.stop()
        await replay?.returnToLive()
        notice = "현재 녹음 위치로 돌아왔습니다."
    }

    func addBookmark() async {
        guard let store else { return }
        do {
            var prior: [Annotation] = []
            if let active = session?.activeAnnotationRevisionID {
                let existing = try await store.read(AnnotationRevision.self, relativePath: "revisions/\(active).json")
                prior = existing.annotations
            }
            prior.append(Annotation(kind: .bookmark, startMs: elapsedMs, content: "북마크"))
            try await commitAnnotations(prior)
            notice = "\(Self.clock(elapsedMs))에 북마크를 저장했습니다."
        } catch { notice = "북마크를 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    func openSessionFolder() {
        guard let store else { return }
        Task {
            let directory = await store.sessionDirectory
            _ = NSWorkspace.shared.open(directory)
        }
    }

    func saveAPIKey() {
        do {
            try OpenAIKeychain.save(apiKeyDraft)
            apiKeyDraft = ""
            hasAPIKey = true
            apiNotice = "OpenAI API 키를 macOS 키체인에 저장했습니다."
            notice = apiNotice
        } catch {
            apiNotice = error.localizedDescription
        }
    }

    func removeAPIKey() {
        do {
            try OpenAIKeychain.delete()
            apiKeyDraft = ""
            hasAPIKey = false
            apiNotice = "OpenAI API 키를 삭제했습니다."
            notice = apiNotice
        } catch {
            apiNotice = error.localizedDescription
        }
    }

    func testAPIConnection() async {
        guard !isBusy else { return }
        isBusy = true
        apiNotice = "OpenAI 연결을 확인하는 중입니다."
        defer { isBusy = false }
        do {
            try await openAIClient().validateCredentials()
            apiNotice = "OpenAI API 연결을 확인했습니다."
        } catch {
            apiNotice = friendlyMessage(for: error)
        }
    }

#if false
    // Retained only as migration history. The production UI and processing path
    // no longer expose or call local model installation.
    func refreshModelStates() async {
        var values: [String: ModelProgress] = [:]
        for manifest in ModelCatalog.all { values[manifest.id] = await modelManager.status(for: manifest) }
        if values[ModelCatalog.whisper.id]?.state == .ready,
           await modelManager.status(for: ModelCatalog.whisperTokenizer).state != .ready {
            values[ModelCatalog.whisper.id] = ModelProgress(state: .notInstalled, completedBytes: 0, totalBytes: ModelCatalog.whisper.totalBytes)
        }
        modelStates = values
    }

    func installModel(_ manifest: ModelManifest) {
        guard modelDownloadTasks[manifest.id] == nil else { return }
        modelNotice = ""
        notice = "\(ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file)) 모델 다운로드를 시작합니다."
        modelStates[manifest.id] = ModelProgress(state: .downloading, completedBytes: 0, totalBytes: manifest.totalBytes)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if manifest.id == ModelCatalog.whisper.id {
                    try await modelManager.install(ModelCatalog.whisperTokenizer) { progress in
                        Task { @MainActor in
                            self.modelStates[manifest.id] = ModelProgress(state: progress.state, completedBytes: 0, totalBytes: manifest.totalBytes, error: progress.error)
                        }
                    }
                }
                try await modelManager.install(manifest) { progress in
                    Task { @MainActor in self.modelStates[manifest.id] = progress }
                }
                await refreshModelStates()
                notice = "로컬 모델 설치와 SHA-256 검증을 완료했습니다."
            } catch is CancellationError {
                notice = "모델 다운로드를 일시정지했습니다. 다시 다운로드하면 이어받습니다."
            } catch {
                modelNotice = friendlyMessage(for: error)
                notice = modelNotice
            }
            modelDownloadTasks[manifest.id] = nil
        }
        modelDownloadTasks[manifest.id] = task
    }

    func installAllModels() {
        guard !isInstallingAllModels, !captureActive, modelDownloadTasks.isEmpty else { return }
        isInstallingAllModels = true
        modelNotice = ""
        notice = "로컬 모델 2,910,072,539 bytes를 순서대로 설치합니다."
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for manifest in [ModelCatalog.whisperTokenizer, ModelCatalog.whisper, ModelCatalog.qwen] {
                    try Task.checkCancellation()
                    try await modelManager.install(manifest) { progress in
                        Task { @MainActor in
                            let visibleID = manifest.id == ModelCatalog.whisperTokenizer.id ? ModelCatalog.whisper.id : manifest.id
                            self.modelStates[visibleID] = ModelProgress(
                                state: progress.state,
                                completedBytes: manifest.id == ModelCatalog.whisperTokenizer.id ? 0 : progress.completedBytes,
                                totalBytes: manifest.id == ModelCatalog.whisperTokenizer.id ? ModelCatalog.whisper.totalBytes : progress.totalBytes,
                                error: progress.error
                            )
                        }
                    }
                }
                await refreshModelStates()
                notice = "전사와 요약 모델의 검증·로딩 준비를 완료했습니다."
            } catch is CancellationError {
                notice = "모델 설치를 일시정지했습니다. 다시 시작하면 받은 파일을 이어받습니다."
            } catch {
                modelNotice = friendlyMessage(for: error)
                notice = modelNotice
            }
            isInstallingAllModels = false
            modelDownloadTasks["all"] = nil
        }
        modelDownloadTasks["all"] = task
    }

    func cancelAllModelInstalls() async {
        modelDownloadTasks["all"]?.cancel()
        for manifest in [ModelCatalog.whisperTokenizer, ModelCatalog.whisper, ModelCatalog.qwen] {
            await modelManager.cancel(manifest)
        }
        modelDownloadTasks["all"] = nil
        isInstallingAllModels = false
        await refreshModelStates()
    }

    func cancelModelInstall(_ manifest: ModelManifest) async {
        modelDownloadTasks[manifest.id]?.cancel()
        modelDownloadTasks[manifest.id] = nil
        await modelManager.cancel(manifest)
        if manifest.id == ModelCatalog.whisper.id { await modelManager.cancel(ModelCatalog.whisperTokenizer) }
        await refreshModelStates()
    }

    func deleteModel(_ manifest: ModelManifest) async {
        do {
            try await modelManager.delete(manifest)
            if manifest.id == ModelCatalog.whisper.id { try await modelManager.delete(ModelCatalog.whisperTokenizer) }
            await refreshModelStates()
        }
        catch { notice = "모델을 삭제하지 못했습니다: \(error.localizedDescription)" }
    }
#endif

    func importAudio() async {
        guard !isBusy, !captureActive else { return }
        guard let rootDirectory else { notice = "먼저 저장 폴더를 선택해 주세요."; return }
        let panel = NSOpenPanel()
        panel.title = "로컬 오디오 가져오기"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isBusy = true
        defer { isBusy = false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? source.deletingPathExtension().lastPathComponent : title
        do {
            let audio = try AVAudioFile(forReading: source)
            let durationMs = Int64((Double(audio.length) / audio.processingFormat.sampleRate * 1_000).rounded())
            var value = Session(
                title: cleanTitle,
                purpose: purpose,
                inputSource: .importedFile,
                captureStatus: .stopped,
                context: SessionContext(
                    languages: languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    keywords: keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    notes: notes
                ),
                providerConfiguration: selectedProviderConfiguration
            )
            let newStore = try SessionStore.create(in: rootDirectory, session: value)
            let relative = try await newStore.importFile(source)
            let copied = try await newStore.absoluteURL(for: relative)
            value.tracks = [AudioSpan(trackID: "imported", relativePath: relative, durationMs: durationMs, sessionStartMs: 0, sampleRate: audio.processingFormat.sampleRate, frameCount: audio.length, checksum: try Self.sha256(copied))]
            let importedSession = value
            resetSessionPresentation()
            session = try await newStore.updateSession { $0 = importedSession }
            store = newStore
            replay = ReplayEngine(spans: session?.tracks ?? [], sessionDirectory: await newStore.sessionDirectory)
            elapsedMs = durationMs
            notice = hasAPIKey ? "원본을 세션 폴더로 복사했습니다. OpenAI 처리를 시작할 수 있습니다." : "원본을 세션 폴더로 복사했습니다. 처리하려면 OpenAI API 키를 설정해 주세요."
            showResults = true
        } catch { notice = "오디오를 가져오지 못했습니다: \(error.localizedDescription)" }
    }

    func reopenSession() async {
        guard !isBusy, !captureActive else { return }
        let panel = NSOpenPanel()
        panel.title = "ListenUp 세션 폴더 열기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let reopened = try SessionStore.reopen(directory)
            let recovery = try await reopened.recover()
            resetSessionPresentation()
            store = reopened
            session = try await reopened.readSession()
            if let id = session?.activeTranscriptRevisionID {
                transcript = try? await reopened.read(TranscriptRevision.self, relativePath: "revisions/\(id).json")
                transcriptDraft = transcript?.segments.map(\.text).joined(separator: "\n") ?? ""
            }
            if let id = session?.activeSummaryRevisionID { summary = try? await reopened.read(SummaryRevision.self, relativePath: "revisions/\(id).json") }
            if let id = session?.activeAnnotationRevisionID,
               let revision = try? await reopened.read(AnnotationRevision.self, relativePath: "revisions/\(id).json") {
                summaryExclusions = revision.annotations.filter { $0.excludedFromSummary }
            }
            // A force-quit or crash can leave the last checkpoint marked as
            // transcribing/summarizing even though its transcript revision was
            // already committed. Recover that stale presentation state when a
            // session is reopened so the UI does not spin forever.
            if let current = session,
               (current.processingStatus == .transcribing || current.processingStatus == .summarizing),
               transcript != nil {
                let recoveredStatus: ProcessingStatus = summary != nil && !current.summaryStale ? .ready : .partial
                session = try? await reopened.updateSession { $0.processingStatus = recoveredStatus }
                resultNotice = summary == nil
                    ? "이전 처리 작업이 중단되었습니다. 저장된 전사를 확인하고 요약을 다시 생성할 수 있습니다."
                    : "저장된 처리 결과를 복구했습니다."
            }
            title = session?.title ?? title
            purpose = session?.purpose ?? purpose
            replay = ReplayEngine(spans: session?.tracks ?? [], sessionDirectory: directory)
            elapsedMs = session?.tracks.map { $0.sessionStartMs + $0.durationMs }.max() ?? 0
            notice = recovery.orphanedAudioFiles.isEmpty ? "세션을 열었습니다." : "세션을 열었습니다. 등록되지 않은 오디오 \(recovery.orphanedAudioFiles.count)개는 복구 대상으로 표시했습니다."
            showResults = true
        } catch { notice = "세션을 열지 못했습니다: \(error.localizedDescription)" }
    }

    func processSession() async {
        guard !captureActive, !isBusy, let store, let current = session, !current.tracks.isEmpty else { return }
        isBusy = true
        showResults = true
        resultNotice = ""
        processingProgress = "OpenAI API 연결 준비 중"
        defer { isBusy = false }
        do {
            let client = try openAIClient()
            let providerConfiguration = selectedProviderConfiguration
            let newTranscript: TranscriptRevision
            if let existing = transcript, existing.coverage.isComplete {
                newTranscript = existing
                processingProgress = "저장된 전사 사용 · 요약 준비 중"
                session = try await store.updateSession {
                    $0.providerConfiguration = providerConfiguration
                    $0.processingStatus = .summarizing
                }
            } else {
                session = try await store.updateSession {
                    $0.providerConfiguration = providerConfiguration
                    $0.processingStatus = .transcribing
                }
                let spans = preferredTranscriptionSpans(current.tracks)
                var generated = try await transcribeWithOpenAI(
                    spans: spans,
                    store: store,
                    client: client,
                    context: current.context,
                    purpose: current.purpose,
                    gaps: current.gaps
                )
                generated.parentID = current.activeTranscriptRevisionID
                _ = try await store.commit(generated, relativePath: "revisions/\(generated.id).json")
                let transcriptID = generated.id
                session = try await store.updateSession {
                    $0.activeTranscriptRevisionID = transcriptID
                    $0.summaryStale = $0.activeSummaryRevisionID != nil
                    $0.processingStatus = .summarizing
                }
                transcript = generated
                transcriptDraft = generated.segments.map(\.text).joined(separator: "\n")
                newTranscript = generated
            }

            processingProgress = "OpenAI 요약 생성 중"
            let inputHash = Self.sha256(try JSONEncoder().encode(newTranscript))
            let annotations: AnnotationRevision?
            if let annotationID = session?.activeAnnotationRevisionID {
                annotations = try await store.read(AnnotationRevision.self, relativePath: "revisions/\(annotationID).json")
            } else {
                annotations = nil
            }
            let summaryInput = SummaryInput(purpose: current.purpose, transcript: newTranscript, annotations: annotations, inputHash: inputHash)
            let newSummary = try await OpenAISummaryAdapter(client: client, modelID: summaryModelID).summarize(summaryInput)
            _ = try await store.commit(newSummary, relativePath: "revisions/\(newSummary.id).json")
            let transcriptIsComplete = newTranscript.coverage.isComplete
            let summaryID = newSummary.id
            session = try await store.updateSession {
                $0.activeSummaryRevisionID = summaryID
                $0.summaryStale = false
                $0.processingStatus = transcriptIsComplete ? .ready : .partial
            }
            summary = newSummary
            try await writeExports()
            if newTranscript.coverage.isComplete {
                processingProgress = "완료"
                resultNotice = "OpenAI API 전사와 요약을 완료했습니다. 결과는 선택한 로컬 폴더에 저장했습니다."
            } else {
                processingProgress = "부분 완료"
                resultNotice = "OpenAI API 처리를 저장했습니다. 오디오 공백 \(newTranscript.coverage.failedRanges.count)개가 결과에 표시됩니다."
            }
        } catch is CancellationError {
            session = try? await store.updateSession { $0.processingStatus = .cancelled }
            processingProgress = ""
            resultNotice = "OpenAI 처리를 취소했습니다. 저장된 원본과 완료된 결과는 그대로 유지됩니다."
        } catch {
            let failedStatus: ProcessingStatus = transcript == nil ? .failed : .partial
            session = try? await store.updateSession { $0.processingStatus = failedStatus }
            processingProgress = ""
            resultNotice = friendlyMessage(for: error)
        }
    }

    func copyResult(_ kind: ExportKind) {
        do {
            let content = try exportContent(kind)
            guard MarkdownExporter().copyMarkdownToPasteboard(content) else { throw ListenUpError.writeFailed("pasteboard") }
            notice = "Markdown과 서식 있는 내용을 클립보드에 복사했습니다."
        } catch { notice = "복사하지 못했습니다: \(error.localizedDescription)" }
    }

    func exportResultBundle() async {
        guard !captureActive, !isBusy,
              let store, let session, let transcript, let summary,
              !session.tracks.isEmpty
        else {
            resultNotice = "녹음, 전사, 요약이 모두 준비된 뒤 결과물을 내보낼 수 있습니다."
            return
        }

        let panel = NSSavePanel()
        panel.title = "ListenUp 결과물 내보내기"
        panel.prompt = "내보내기"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(MarkdownExporter.safeFilename(session.title))-ListenUp.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isBusy = true
        processingProgress = "결과물 M4A 생성 중"
        defer { isBusy = false }
        do {
            let sessionDirectory = await store.sessionDirectory
            try await ResultBundleExporter().export(
                session: session,
                transcript: transcript,
                summary: summary,
                sessionDirectory: sessionDirectory,
                destination: destination
            )
            processingProgress = "완료"
            resultNotice = "녹음 M4A와 요약·전체 전사가 담긴 HTML을 내보냈습니다."
        } catch {
            processingProgress = ""
            resultNotice = "결과물을 내보내지 못했습니다: \(error.localizedDescription)"
        }
    }

    func saveTranscriptCorrection() async {
        guard !captureActive, !isBusy, let store, let prior = transcript else { return }
        let lines = transcriptDraft.components(separatedBy: .newlines)
        guard lines.count == prior.segments.count else {
            notice = "교정본은 전사 구간 수를 유지해야 합니다. 현재 \(prior.segments.count)줄이 필요합니다."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            var segments = prior.segments
            for index in segments.indices {
                let text = lines[index].trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { throw ListenUpError.invalidModelResponse("빈 전사 구간") }
                segments[index].text = text
                segments[index].revision += 1
            }
            let corrected = TranscriptRevision(
                id: "transcript-\(UUID().uuidString)",
                parentID: prior.id,
                originalResponseReferences: prior.originalResponseReferences,
                segments: segments,
                coverage: prior.coverage,
                modelID: prior.modelID,
                configurationHash: prior.configurationHash
            )
            try DomainValidator.validate(corrected)
            _ = try await store.commit(corrected, relativePath: "revisions/\(corrected.id).json")
            let correctedID = corrected.id
            session = try await store.updateSession {
                $0.activeTranscriptRevisionID = correctedID
                $0.summaryStale = $0.activeSummaryRevisionID != nil
            }
            transcript = corrected
            notice = "원 전사를 보존하고 교정본 리비전을 저장했습니다. 요약을 다시 생성해 주세요."
        } catch { notice = "교정본을 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    func replaySegment(_ segment: TranscriptSegment) async {
        guard let replay else { return }
        await replay.seek(to: segment.startMs)
        do {
            try await replay.play()
            notice = "\(Self.clock(segment.startMs)) 근거 구간을 재생합니다."
        } catch { notice = "근거 오디오를 재생할 수 없습니다: \(error.localizedDescription)" }
    }

    func changePurpose(_ newPurpose: SessionPurpose) async {
        guard !captureActive, !isBusy, let store else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            session = try await store.updateSession {
                $0.purpose = newPurpose
                $0.summaryStale = $0.activeSummaryRevisionID != nil
            }
            purpose = newPurpose
            notice = "용도를 \(newPurpose.displayName)(으)로 바꿨습니다. 기존 요약은 보존되며 갱신이 필요합니다."
        } catch { notice = "용도를 변경하지 못했습니다: \(error.localizedDescription)" }
    }

    func editExclusion(_ annotation: Annotation?) {
        editingExclusionID = annotation?.id
        exclusionStartSeconds = Int((annotation?.startMs ?? 0) / 1_000)
        exclusionEndSeconds = Int((annotation?.endMs ?? 30_000) / 1_000)
    }

    func saveExclusion() async {
        guard !captureActive, !isBusy else { return }
        guard exclusionStartSeconds >= 0, exclusionEndSeconds > exclusionStartSeconds else {
            notice = "요약 제외 구간의 종료 시각은 시작 시각보다 뒤여야 합니다."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let current = try await currentAnnotations()
            var next = current
            let value = Annotation(
                id: editingExclusionID ?? UUID(),
                kind: .replayRange,
                startMs: Int64(exclusionStartSeconds) * 1_000,
                endMs: Int64(exclusionEndSeconds) * 1_000,
                content: "외부 반복 구간",
                excludedFromSummary: true
            )
            if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
            else { next.append(value) }
            try await commitAnnotations(next)
            editExclusion(nil)
            notice = "원 전사는 유지하고 선택한 반복 구간을 요약에서 제외했습니다."
        } catch { notice = "제외 구간을 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    func removeExclusion(_ id: UUID) async {
        guard !captureActive, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let next = (try await currentAnnotations()).filter { $0.id != id }
            try await commitAnnotations(next)
            if editingExclusionID == id { editExclusion(nil) }
            notice = "요약 제외 구간을 해제했습니다."
        } catch { notice = "제외 구간을 해제하지 못했습니다: \(error.localizedDescription)" }
    }

    func regenerateSummary() async {
        guard !captureActive, !isBusy, let store, let transcript, let currentSession = session else { return }
        isBusy = true
        processingProgress = "OpenAI 요약 생성 중"
        defer { isBusy = false }
        do {
            let client = try openAIClient()
            let annotations = try await activeAnnotationRevision(store: store, session: currentSession)
            let inputHash = Self.sha256(try JSONEncoder().encode(transcript))
            let input = SummaryInput(purpose: currentSession.purpose, transcript: transcript, annotations: annotations, inputHash: inputHash)
            let newSummary = try await OpenAISummaryAdapter(client: client, modelID: summaryModelID).summarize(input)
            _ = try await store.commit(newSummary, relativePath: "revisions/\(newSummary.id).json")
            let summaryID = newSummary.id
            let providerConfiguration = selectedProviderConfiguration
            session = try await store.updateSession {
                $0.activeSummaryRevisionID = summaryID
                $0.summaryStale = false
                $0.processingStatus = transcript.coverage.isComplete ? .ready : .partial
                $0.providerConfiguration = providerConfiguration
            }
            summary = newSummary
            try await writeExports()
            processingProgress = transcript.coverage.isComplete ? "완료" : "부분 완료"
            resultNotice = "현재 용도, 교정본, 제외 구간으로 OpenAI 요약을 생성했습니다."
        } catch {
            processingProgress = ""
            resultNotice = friendlyMessage(for: error)
        }
    }

    func writeExports() async throws {
        guard let store, let session else { throw ListenUpError.missingReference("session") }
        let directory = await store.sessionDirectory.appendingPathComponent("exports", isDirectory: true)
        let exporter = MarkdownExporter()
        if let transcript { _ = try exporter.write(try exporter.transcript(transcript, title: session.title), to: directory, filename: "transcript") }
        if let summary { _ = try exporter.write(exporter.summary(summary, title: session.title), to: directory, filename: "summary") }
        if transcript != nil { _ = try exporter.write(try exportContent(.combined), to: directory, filename: "listenup") }
    }

    private func exportContent(_ kind: ExportKind) throws -> String {
        guard let session else { throw ListenUpError.missingReference("session") }
        let exporter = MarkdownExporter()
        switch kind {
        case .transcript:
            guard let transcript else { throw ListenUpError.missingReference("transcript") }
            return try exporter.transcript(transcript, title: session.title)
        case .summary:
            guard let summary else { throw ListenUpError.missingReference("summary") }
            return exporter.summary(summary, title: session.title)
        case .combined:
            guard let transcript else { throw ListenUpError.missingReference("transcript") }
            return try exporter.combined(session: session, transcript: transcript, summary: summary)
        }
    }

    private func preferredTranscriptionSpans(_ values: [AudioSpan]) -> [AudioSpan] {
        if values.contains(where: { $0.trackID == "mixed" }) { return values.filter { $0.trackID == "mixed" }.sorted { $0.sessionStartMs < $1.sessionStartMs } }
        return values.filter { $0.trackID == "microphone" || $0.trackID == "system" || $0.trackID == "imported" }
            .sorted { lhs, rhs in
                lhs.sessionStartMs == rhs.sessionStartMs ? lhs.trackID < rhs.trackID : lhs.sessionStartMs < rhs.sessionStartMs
            }
    }

    private func transcribeWithOpenAI(
        spans: [AudioSpan],
        store: SessionStore,
        client: OpenAIAPIClient,
        context: SessionContext,
        purpose: SessionPurpose,
        gaps: [Gap]
    ) async throws -> TranscriptRevision {
        processingProgress = "OpenAI 전사 준비 중"
        var output: [TranscriptSegment] = []
        var responseReferences: [String] = []
        let totalChunks = max(1, spans.reduce(0) { partial, span in
            partial + max(1, Int(ceil(Double(span.durationMs) / 60_000.0)))
        })
        var completedChunks = 0
        let purposeDescription = purpose == .meeting ? "회의 녹음" : "강의 녹음"
        let promptParts = [purposeDescription, context.notes].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let transcriptionPrompt = promptParts.joined(separator: ". ")
        for (spanIndex, span) in spans.enumerated() {
            let url = try await store.absoluteURL(for: span.relativePath)
            let reader = try AudioChunkReader(url: url)
            var offsetMs: Int64 = 0
            var chunkIndex = 0
            while let samples = try reader.next() {
                try Task.checkCancellation()
                processingProgress = "OpenAI 전사 \(completedChunks)/\(totalChunks) 청크 · 트랙 \(spanIndex + 1)/\(spans.count)"
                let requestID = "\(span.id.uuidString)-\(chunkIndex)"
                let result = try await client.transcribe(
                    samples: samples,
                    model: transcriptionModelID,
                    languages: context.languages,
                    keywords: context.keywords,
                    prompt: transcriptionPrompt
                )
                let source = SourceTrack(rawValue: span.trackID) ?? .mixed
                let durationMs = Int64(Double(samples.count) / 16)
                if !result.text.isEmpty {
                    output.append(TranscriptSegment(
                        id: "\(requestID)-0",
                        text: result.text,
                        startMs: span.sessionStartMs + offsetMs,
                        endMs: min(span.sessionStartMs + span.durationMs, span.sessionStartMs + offsetMs + durationMs),
                        timePrecision: .chunk,
                        sourceTrack: source,
                        requestID: requestID
                    ))
                }
                if let apiRequestID = result.requestID { responseReferences.append(apiRequestID) }
                offsetMs += durationMs
                chunkIndex += 1
                completedChunks += 1
                processingProgress = "OpenAI 전사 \(completedChunks)/\(totalChunks) 청크 · 트랙 \(spanIndex + 1)/\(spans.count)"
            }
        }
        guard !output.isEmpty else { throw OpenAIAPIError.invalidResponse("인식된 음성이 없습니다") }
        let end = spans.map { $0.sessionStartMs + $0.durationMs }.max() ?? 0
        let failed = gaps.filter { !$0.recovered }.map { gap in
            var closed = gap
            if closed.endMs == nil { closed.endMs = end }
            return closed
        }
        return TranscriptRevision(
            id: "transcript-\(UUID().uuidString)",
            originalResponseReferences: responseReferences,
            segments: output.sorted { $0.startMs < $1.startMs },
            coverage: Coverage(startMs: 0, endMs: end, failedRanges: failed),
            modelID: transcriptionModelID,
            configurationHash: "openai-api-v1"
        )
    }

    private func enqueueChunk(_ url: URL, track: SourceTrack, sessionStartMs: Int64? = nil) {
        pendingChunks.append((url, track, sessionStartMs))
        guard !isRegisteringChunk else { return }
        isRegisteringChunk = true
        Task { @MainActor in
            while !pendingChunks.isEmpty {
                let next = pendingChunks.removeFirst()
                await registerChunk(next.0, track: next.1, sessionStartMs: next.2)
            }
            isRegisteringChunk = false
            let waiters = chunkDrainWaiters
            chunkDrainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func registerChunk(_ url: URL, track: SourceTrack, sessionStartMs: Int64?) async {
        guard let store else { return }
        do {
            let directory = await store.sessionDirectory
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.processingFormat.sampleRate
            let frameCount = audioFile.length
            let durationMs = max(0, Int64((Double(frameCount) / sampleRate * 1_000).rounded()))
            let trackID = track == .microphone ? "microphone" : "system"
            let span = AudioSpan(
                trackID: trackID,
                relativePath: relative,
                durationMs: durationMs,
                sessionStartMs: 0,
                sampleRate: sampleRate,
                frameCount: frameCount,
                checksum: try Self.sha256(url)
            )
            let inferredStart = sessionStartMs ?? max(0, elapsedMs - durationMs)
            session = try await store.updateSession { value in
                var registered = span
                let previousEnd = value.tracks.filter { $0.trackID == trackID }.map { $0.sessionStartMs + $0.durationMs }.max() ?? inferredStart
                registered.sessionStartMs = max(previousEnd, inferredStart)
                value.tracks.append(registered)
            }
            await replay?.update(spans: session?.tracks ?? [], liveHeadMs: elapsedMs)
        } catch { await handleCaptureFailure(error) }
    }

    private var chunkDrainWaiters: [CheckedContinuation<Void, Never>] = []

    private func waitForPendingChunks() async {
        guard isRegisteringChunk || !pendingChunks.isEmpty else { return }
        await withCheckedContinuation { chunkDrainWaiters.append($0) }
    }

    private func handleCaptureFailure(_ error: Error) async {
        notice = "오디오 저장 중 문제가 발생했습니다: \(error.localizedDescription)"
        let firstFailure = captureFailureMessage == nil
        captureFailureMessage = error.localizedDescription
        if firstFailure, let store {
            let failureMs = elapsedMs
            session = try? await store.updateSession { value in
                value.captureStatus = .interrupted
                value.gaps.append(Gap(startMs: failureMs, reason: .unknown))
            }
        }
        guard captureActive else { return }
        captureActive = false
        recordingIndicator.hide()
        timer?.invalidate()
        timer = nil
        microphone?.stop()
        microphone = nil
        try? await systemAudio?.stop()
        systemAudio = nil
    }

    private func resetSessionPresentation() {
        transcript = nil
        summary = nil
        transcriptDraft = ""
        summaryExclusions = []
        editingExclusionID = nil
        processingProgress = ""
        resultNotice = ""
        showResults = false
    }

    private var selectedProviderConfiguration: ProviderConfiguration {
        ProviderConfiguration(
            sttModelID: transcriptionModelID,
            sttRevision: "openai-api",
            summaryModelID: summaryModelID,
            summaryRevision: "openai-api",
            sttLocation: .cloud,
            summaryLocation: .cloud
        )
    }

    private func openAIClient() throws -> OpenAIAPIClient {
        guard let key = OpenAIKeychain.load(), !key.isEmpty else {
            hasAPIKey = false
            throw OpenAIAPIError.missingAPIKey
        }
        hasAPIKey = true
        return OpenAIAPIClient(apiKey: key)
    }

    private func friendlyMessage(for error: Error) -> String {
        switch error {
        case let value as ListenUpError:
            switch value {
            case .modelUnavailable(let name):
                return "\(name)을 사용할 수 없습니다. OpenAI API 설정과 선택한 모델을 확인해 주세요."
            case .permissionDenied:
                return "필요한 macOS 권한이 없습니다. 시스템 설정의 개인정보 보호 및 보안에서 마이크와 화면 기록 권한을 허용한 뒤 다시 시도해 주세요."
            case .sourceUnavailable:
                return "선택한 오디오 입력을 찾을 수 없습니다. 입력 앱을 열고 녹음할 앱을 다시 선택해 주세요."
            case .diskFull:
                return "저장 공간이 부족합니다. 디스크에 여유 공간을 확보한 뒤 다시 시도해 주세요."
            case .writeFailed(let path):
                return "결과를 저장하지 못했습니다(\(path)). 저장 폴더의 권한과 여유 공간을 확인해 주세요."
            case .invalidModelResponse, .summaryInvalid:
                return "OpenAI 응답 형식이 올바르지 않습니다. 원본 오디오와 완료된 전사는 보존되어 있으니 다시 시도해 주세요."
            case .deviceChanged:
                return "오디오 장치가 변경되어 작업을 완료하지 못했습니다. 입력 장치를 확인한 뒤 다시 시도해 주세요."
            case .missingReference(let reference):
                return "세션에 필요한 파일(\(reference))을 찾지 못했습니다. 세션 폴더를 확인하거나 다시 열어 주세요."
            case .invalidRelativePath, .invalidTimeRange, .unsupportedSchema:
                return "세션 파일 형식이 올바르지 않습니다. 세션 폴더의 원본 파일을 보존한 뒤 새 세션으로 다시 시도해 주세요."
            case .sessionMoved:
                return "세션 폴더 위치가 변경되었습니다. 현재 위치의 세션 폴더를 다시 열어 주세요."
            }
        case let value as OpenAIAPIError:
            return value.localizedDescription
        default:
            let description = error.localizedDescription
            if description.isEmpty || description.contains("ListenUpDomain.ListenUpError") {
                return "OpenAI 처리 중 알 수 없는 문제가 발생했습니다. 저장된 원본과 완료된 결과는 유지됩니다."
            }
            return "OpenAI 처리 중 문제가 발생했습니다: \(description)"
        }
    }

    private func currentAnnotations() async throws -> [Annotation] {
        guard let store, let active = session?.activeAnnotationRevisionID else { return [] }
        return try await store.read(AnnotationRevision.self, relativePath: "revisions/\(active).json").annotations
    }

    private func activeAnnotationRevision(store: SessionStore, session: Session) async throws -> AnnotationRevision? {
        guard let active = session.activeAnnotationRevisionID else { return nil }
        return try await store.read(AnnotationRevision.self, relativePath: "revisions/\(active).json")
    }

    private func commitAnnotations(_ annotations: [Annotation]) async throws {
        guard let store else { throw ListenUpError.missingReference("session store") }
        let revision = AnnotationRevision(
            id: "annotations-\(UUID().uuidString)",
            parentID: session?.activeAnnotationRevisionID,
            annotations: annotations
        )
        _ = try await store.commit(revision, relativePath: "revisions/\(revision.id).json")
        let revisionID = revision.id
        session = try await store.updateSession {
            $0.activeAnnotationRevisionID = revisionID
            $0.summaryStale = $0.activeSummaryRevisionID != nil
        }
        summaryExclusions = annotations.filter(\.excludedFromSummary).sorted { $0.startMs < $1.startMs }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let began = self.recordingBeganAt else { return }
                self.elapsedMs = Int64(Date().timeIntervalSince(began) * 1_000)
            }
        }
    }

    private func restoreRootDirectory() {
        guard let data = UserDefaults.standard.data(forKey: "ListenUpRootBookmark") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            rootDirectory = url
            _ = url.startAccessingSecurityScopedResource()
            scopedRootURL = url
            if stale { saveRootDirectory(url) }
        }
    }

    private func saveRootDirectory(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "ListenUpRootBookmark")
        }
    }

    private static func isScreenCapturePermissionError(_ error: Error) -> Bool {
        let value = error as NSError
        let details = "\(value.domain) \(value.localizedDescription)".lowercased()
        return details.contains("tcc")
            || details.contains("permission")
            || details.contains("denied")
            || details.contains("declined")
            || details.contains("거절")
            || details.contains("권한")
    }

    static func clock(_ milliseconds: Int64) -> String {
        let total = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class AudioChunkReader {
    private let file: AVAudioFile
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let sourceFramesPerChunk: AVAudioFrameCount

    init(url: URL, secondsPerChunk: Double = 60) throws {
        file = try AVAudioFile(forReading: url)
        source = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw ListenUpError.writeFailed("audio format") }
        self.target = target
        sourceFramesPerChunk = AVAudioFrameCount(max(1, Int(source.sampleRate * secondsPerChunk)))
    }

    func next() throws -> [Float]? {
        guard file.framePosition < file.length else { return nil }
        let remaining = AVAudioFrameCount(min(Int64(sourceFramesPerChunk), file.length - file.framePosition))
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: remaining) else {
            throw ListenUpError.writeFailed("audio buffer")
        }
        try file.read(into: input, frameCount: remaining)
        guard input.frameLength > 0,
              let converter = AVAudioConverter(from: source, to: target) else {
            throw ListenUpError.writeFailed("audio conversion")
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / source.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw ListenUpError.writeFailed("audio output buffer")
        }
        let state = AudioConverterInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            state.provide(status)
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData?[0] else {
            throw conversionError ?? ListenUpError.writeFailed("audio conversion")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

private final class AudioConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func provide(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
