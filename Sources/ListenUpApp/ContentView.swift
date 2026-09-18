import SwiftUI
import ListenUpAI
import ListenUpDomain
import ListenUpExport

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.showResults) {
                Section {
                    Label("새 녹음", systemImage: "record.circle")
                        .tag(false)
                    Label("현재 결과", systemImage: "doc.text")
                        .tag(true)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("ListenUp")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if model.showResults { ResultView() } else { RecordingView() }
        }
    }
}

private struct RecordingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader

                if model.isRecording {
                    recordingPanel
                } else {
                    apiConfiguration
                    sessionSetup
                    audioSetup
                    recordingActions
                }

                if !model.notice.isEmpty {
                    NoticeBanner(message: model.notice, kind: noticeKind)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isRecording ? "녹음 중" : "새 녹음")
                .font(.system(size: 32, weight: .bold))
            Text(model.isRecording
                 ? "입력 레벨을 확인하며 녹음하세요. 다른 앱을 사용해도 녹음은 계속됩니다."
                 : "강의나 회의를 녹음한 뒤 전체 전사와 목적에 맞는 요약을 만듭니다.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionSetup: some View {
        SectionCard(
            title: "녹음 정보",
            subtitle: "제목과 용도는 파일 이름과 요약 형식을 정하는 데 사용됩니다.",
            systemImage: model.purpose == .lecture ? "graduationcap" : "person.3"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("제목").font(.subheadline.weight(.medium))
                    TextField("예: 9월 정기회의", text: $model.title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("녹음 제목")
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("용도").font(.subheadline.weight(.medium))
                    Picker("용도", selection: $model.purpose) {
                        ForEach(SessionPurpose.allCases, id: \.self) { purpose in
                            Text(purpose.displayName).tag(purpose)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    private var audioSetup: some View {
        SectionCard(
            title: "녹음할 소리",
            subtitle: "어디에서 들리는 소리를 담을지 선택하세요.",
            systemImage: "waveform"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("녹음할 소리", selection: $model.inputSource) {
                    Text("마이크만").tag(InputSource.microphone)
                    Text("앱 소리만").tag(InputSource.systemAudio)
                    Text("마이크 + 앱 소리").tag(InputSource.microphoneAndSystem)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Label(inputSourceDescription, systemImage: inputSourceIcon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if model.requiresSystemAudio {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("소리를 녹음할 앱")
                            .font(.subheadline.weight(.medium))

                        if model.screenCapturePermissionBlocked {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(
                                    "앱 목록을 보려면 화면 및 시스템 오디오 녹음 권한이 필요합니다.",
                                    systemImage: "exclamationmark.shield.fill"
                                )
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.orange)

                                Text("설정에서 ListenUp 권한을 껐다가 다시 켠 뒤 앱을 완전히 종료하고 다시 여세요.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    Button("권한 다시 확인", systemImage: "arrow.clockwise") {
                                        Task { await model.refreshApplications() }
                                    }
                                    .disabled(model.isBusy || model.captureActive)

                                    Button("시스템 설정 열기", systemImage: "gearshape") {
                                        model.openScreenCaptureSettings()
                                    }

                                    Button("ListenUp 종료", systemImage: "power") {
                                        model.quitForScreenCapturePermissionChange()
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        } else {
                            HStack(spacing: 10) {
                                Picker("소리를 녹음할 앱", selection: $model.selectedApplicationID) {
                                    Text("앱을 선택하세요").tag(String?.none)
                                    ForEach(model.availableApplications) { app in
                                        Text(app.name).tag(Optional(app.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)

                                Button {
                                    Task { await model.refreshApplications() }
                                } label: {
                                    Label("목록 새로 고침", systemImage: "arrow.clockwise")
                                }
                                .disabled(model.isBusy || model.captureActive)
                            }

                            Text("실행 중인 앱만 표시됩니다. Zoom, Teams, Chrome처럼 소리가 재생될 앱을 먼저 실행하세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .task {
                        await model.loadApplicationsIfNeeded()
                    }
                }
            }
        }
    }

    private var recordingActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("오디오 파일 가져오기…", systemImage: "square.and.arrow.down") {
                    Task { await model.importAudio() }
                }
                .disabled(model.isBusy || model.captureActive || model.rootDirectory == nil)

                Button("기존 세션 열기…", systemImage: "folder") {
                    Task { await model.reopenSession() }
                }
                .disabled(model.isBusy || model.captureActive)

                Spacer()

                Button("녹음 시작", systemImage: "record.circle.fill") {
                    Task { await model.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canStartRecording)
                .accessibilityHint("선택한 소리를 녹음합니다")
            }

            Text("녹음 작업 파일은 앱 내부에 보관되며, 결과 파일은 ‘결과물 내보내기’를 선택할 때만 생성됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = readinessMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var apiConfiguration: some View {
        SectionCard(
            title: "OpenAI",
            subtitle: model.hasAPIKey
                ? "녹음이 끝나면 OpenAI API로 전사와 요약을 처리합니다."
                : "전사와 요약을 만들려면 API 키를 한 번 설정해야 합니다.",
            systemImage: "network"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        model.hasAPIKey ? "연결 설정됨" : "API 키 필요",
                        systemImage: model.hasAPIKey ? "checkmark.circle.fill" : "key.fill"
                    )
                    .foregroundStyle(model.hasAPIKey ? .green : .orange)
                    Spacer()
                    SettingsLink {
                        Label("설정", systemImage: "gearshape")
                    }
                }

                if !model.hasAPIKey {
                    HStack {
                        SecureField("OpenAI API 키", text: $model.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("저장") { model.saveAPIKey() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Text(model.apiNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var recordingPanel: some View {
        SectionCard(
            title: model.title,
            subtitle: model.purpose == .lecture ? "강의 녹음" : "회의 녹음",
            systemImage: "record.circle.fill"
        ) {
            VStack(spacing: 24) {
                Text(AppModel.clock(model.elapsedMs))
                    .font(.system(size: 50, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("녹음 시간 \(AppModel.clock(model.elapsedMs))")

                VStack(spacing: 12) {
                    if model.requiresMicrophone {
                        RecordingLevelMeter(label: "마이크", level: model.microphoneLevel)
                    }
                    if model.requiresSystemAudio {
                        RecordingLevelMeter(label: "앱 소리", level: model.systemAudioLevel)
                    }
                }

                if model.elapsedMs >= 3_000 && model.recordingLevelIsLow {
                    Label("소리가 거의 감지되지 않습니다. 입력 장치와 음량을 확인하세요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                VStack(spacing: 10) {
                    Button(role: .destructive) {
                        Task { await model.stopRecording() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 74, height: 74)
                            .background(.red, in: Circle())
                            .shadow(color: .red.opacity(0.24), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)

                    Text("녹음 종료")
                        .font(.headline)
                }

                Text("저장된 오디오 조각 \(model.session?.tracks.count ?? 0)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var canStartRecording: Bool {
        !model.isBusy && !model.captureActive && readinessMessage == nil
    }

    private var readinessMessage: String? {
        if model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "제목을 입력하면 녹음을 시작할 수 있습니다."
        }
        if model.rootDirectory == nil {
            return "앱 내부 저장소를 준비하지 못했습니다. 앱을 다시 실행해 주세요."
        }
        if model.requiresSystemAudio && model.selectedApplication == nil {
            return model.screenCapturePermissionBlocked
                ? "화면 및 시스템 오디오 녹음 권한을 허용한 뒤 ListenUp을 다시 열어 주세요."
                : "소리를 녹음할 앱을 선택하면 녹음을 시작할 수 있습니다."
        }
        return nil
    }

    private var inputSourceDescription: String {
        switch model.inputSource {
        case .microphone:
            return "대면 회의나 오프라인 강의를 녹음할 때 적합합니다."
        case .systemAudio:
            return "선택한 앱에서 재생되는 소리만 녹음합니다. 내 목소리는 포함되지 않습니다."
        case .microphoneAndSystem:
            return "온라인 회의의 앱 소리와 내 목소리를 함께 녹음합니다."
        case .importedFile:
            return "가져온 오디오 파일을 사용합니다."
        }
    }

    private var inputSourceIcon: String {
        switch model.inputSource {
        case .microphone: return "mic"
        case .systemAudio: return "app.badge.waveform"
        case .microphoneAndSystem: return "waveform.badge.mic"
        case .importedFile: return "waveform"
        }
    }

    private var noticeKind: NoticeBanner.Kind {
        if model.notice.contains("못했") || model.notice.contains("오류") || model.notice.contains("실패") {
            return .error
        }
        return .information
    }
}

private struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedResultTab: ResultTab = .transcript

    private enum ResultTab: Hashable {
        case transcript
        case summary
    }

    var body: some View {
        Group {
            if let session = model.session {
                if isAwaitingProcessing(session) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            resultHeader(session)
                            recordingReadyPanel(session)
                        }
                        .padding(.horizontal, 36)
                        .padding(.vertical, 30)
                        .frame(maxWidth: 1240, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    GeometryReader { proxy in
                        ScrollView {
                            completedResult(session, availableHeight: proxy.size.height)
                                .frame(width: proxy.size.width)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "아직 녹음이 없습니다",
                    systemImage: "waveform",
                    description: Text("새 녹음을 마치거나 오디오 파일을 가져오면 전체 전사와 요약이 여기에 표시됩니다.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func isAwaitingProcessing(_ session: Session) -> Bool {
        session.processingStatus == .notStarted && model.transcript == nil
    }

    private func completedResult(_ session: Session, availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            resultHeader(session)
            apiBar

            if session.summaryStale {
                NoticeBanner(
                    message: "용도나 교정본이 바뀌었습니다. 최신 내용으로 요약을 다시 생성해 주세요.",
                    kind: .warning
                )
            }

            if !model.resultNotice.isEmpty {
                resultNotice(session)
            }

            actionBar(session)

            if shouldShowProcessingIndicator {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.processingProgress)
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityElement(children: .combine)
            }

            resultTabs
                .frame(height: max(260, availableHeight - 360))
            copyAction
            exportBar(session)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 22)
        .frame(maxWidth: 1240, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func resultHeader(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title)
                .font(.system(size: 32, weight: .bold))
                .lineLimit(2)

            HStack(spacing: 10) {
                Label(session.purpose.displayName, systemImage: session.purpose == .lecture ? "graduationcap" : "person.3")
                Text("·")
                Label("오디오 \(session.tracks.count)개", systemImage: "waveform")
                StatusPill(text: processingStatusText(session.processingStatus), color: statusColor(session.processingStatus))
                Spacer()
                Picker("요약 형식", selection: Binding(
                    get: { model.session?.purpose ?? model.purpose },
                    set: { value in Task { await model.changePurpose(value) } }
                )) {
                    ForEach(SessionPurpose.allCases, id: \.self) { purpose in
                        Text(purpose.displayName).tag(purpose)
                    }
                }
                .frame(width: 160)
                .disabled(model.isBusy || model.captureActive)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func recordingReadyPanel(_ session: Session) -> some View {
        SectionCard(
            title: "녹음이 저장되었습니다",
            subtitle: "녹음을 확인한 뒤 전사와 요약을 시작하세요.",
            systemImage: "checkmark.circle.fill"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppModel.clock(model.recordingDurationMs))
                            .font(.title2.monospacedDigit().weight(.semibold))
                        Text("\(inputSourceName(session.inputSource)) · 오디오 조각 \(session.tracks.count)개")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                NoticeBanner(
                    message: model.recordingLevelIsLow
                        ? "입력 소리가 매우 작았습니다. 녹음을 확인하고 필요하면 입력 장치나 음량을 조정한 뒤 다시 녹음하세요."
                        : "녹음이 앱 내부에 안전하게 보관되었습니다. 파일은 원할 때만 내보낼 수 있습니다.",
                    kind: model.recordingLevelIsLow ? .warning : .information
                )

                HStack(spacing: 10) {
                    Button(model.previewPlaying ? "재생 중지" : "녹음 확인", systemImage: model.previewPlaying ? "stop.fill" : "play.fill") {
                        Task { await model.toggleRecordingPreview() }
                    }
                    if session.inputSource != .importedFile {
                        Button("녹음 다시하기", systemImage: "arrow.counterclockwise.circle") {
                            Task { await model.restartRecording() }
                        }
                        .help("기존 녹음은 유지하고 같은 설정으로 새 녹음을 시작합니다.")
                        .accessibilityHint("기존 녹음을 유지하고 같은 제목과 설정으로 새 녹음을 시작합니다")
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: model.hasAPIKey ? "checkmark.circle.fill" : "key.fill")
                        .foregroundStyle(model.hasAPIKey ? .green : .orange)
                    Text(model.hasAPIKey ? "OpenAI 연결 설정됨" : "전사하려면 OpenAI API 키가 필요합니다.")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    SettingsLink {
                        Label("API 설정", systemImage: "gearshape")
                    }
                }

                if model.hasAPIKey {
                    Button {
                        Task { await model.processSession() }
                    } label: {
                        Label("전사와 요약 시작", systemImage: "waveform.and.magnifyingglass")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                } else {
                    SettingsLink {
                        Label("API 키 설정", systemImage: "key.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                HStack {
                    Spacer()
                    Button("새 녹음", systemImage: "record.circle") {
                        Task { await model.prepareAnotherRecording() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func inputSourceName(_ source: InputSource) -> String {
        switch source {
        case .microphone: "마이크"
        case .systemAudio: "앱 소리"
        case .microphoneAndSystem: "마이크 + 앱 소리"
        case .importedFile: "가져온 오디오"
        }
    }

    private var apiBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(model.hasAPIKey ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasAPIKey ? "OpenAI 연결 설정됨" : "OpenAI API 키 필요")
                    .font(.subheadline.weight(.semibold))
                Text("전사 \(model.transcriptionModelID) · 요약 \(model.summaryModelID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Label("API 설정", systemImage: "gearshape")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }

    private func resultNotice(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NoticeBanner(
                message: model.resultNotice,
                kind: session.processingStatus == .failed ? .error : .information
            )
            if session.processingStatus == .failed || session.processingStatus == .partial {
                Button("다시 시도", systemImage: "arrow.clockwise") {
                    Task {
                        if model.hasCompleteTranscript { await model.regenerateSummary() }
                        else { await model.processSession() }
                    }
                }
                .disabled(model.isBusy || model.captureActive || !model.hasAPIKey)
            }
        }
    }

    private func actionBar(_ session: Session) -> some View {
        HStack(spacing: 10) {
            if model.hasCompleteTranscript {
                Label("전사 완료", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
            } else {
                Button(model.hasAPIKey ? "전사와 요약 시작" : "API 키 설정 후 처리", systemImage: "waveform.and.magnifyingglass") {
                    Task { await model.processSession() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || !model.hasAPIKey || (session.captureStatus != .stopped && session.captureStatus != .interrupted))
            }

            Button(model.summary == nil ? "요약 생성" : "요약 다시 생성", systemImage: "arrow.clockwise") {
                Task { await model.regenerateSummary() }
            }
            .disabled(model.isBusy || model.transcript == nil || !model.hasAPIKey)

            Spacer()
        }
    }

    private var resultTabs: some View {
        TabView(selection: $selectedResultTab) {
            transcriptEditor
                .tabItem { Label("전체 전사", systemImage: "text.alignleft") }
                .tag(ResultTab.transcript)
            ScrollView {
                summaryContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .tabItem { Label("요약", systemImage: "list.bullet.rectangle") }
            .tag(ResultTab.summary)
        }
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    private var copyAction: some View {
        HStack(spacing: 10) {
            Text(selectedResultTab == .transcript
                 ? "시간 정보 없이 받아쓰기 텍스트만 복사됩니다."
                 : "Markdown 형식으로 복사됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()

            Button(
                selectedResultTab == .transcript ? "전체 전사 복사" : "요약 복사",
                systemImage: "doc.on.doc"
            ) {
                model.copyResult(selectedResultTab == .transcript ? .transcript : .summary)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedResultTab == .transcript ? model.transcript == nil : model.summary == nil)
        }
    }

    private func exportBar(_ session: Session) -> some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                Text("녹음 M4A와 요약·전체 전사 HTML을 ZIP으로 내보냅니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("결과물 내보내기", systemImage: "square.and.arrow.up") {
                    Task { await model.exportResultBundle() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy || model.captureActive || model.transcript == nil || model.summary == nil || session.tracks.isEmpty)
            }
        }
    }

    private var shouldShowProcessingIndicator: Bool {
        guard !model.processingProgress.isEmpty,
              let status = model.session?.processingStatus else { return false }
        switch status {
        case .preparing, .transcribing, .summarizing:
            return true
        case .notStarted, .ready, .paused, .partial, .failed, .cancelled:
            return false
        }
    }

    private func processingStatusText(_ status: ProcessingStatus) -> String {
        switch status {
        case .notStarted: "전사 대기"
        case .preparing: "처리 준비 중"
        case .transcribing: "전사 중"
        case .summarizing: "요약 중"
        case .ready: "처리 완료"
        case .paused: "처리 일시정지"
        case .partial: "부분 완료"
        case .failed: "처리 실패"
        case .cancelled: "처리 취소"
        }
    }

    private func statusColor(_ status: ProcessingStatus) -> Color {
        switch status {
        case .ready: return .green
        case .failed: return .red
        case .partial, .paused: return .orange
        case .preparing, .transcribing, .summarizing: return .blue
        case .notStarted, .cancelled: return .secondary
        }
    }

    private var transcriptText: String {
        guard let transcript = model.transcript else {
            guard let status = model.session?.processingStatus else { return "전사할 녹음이 없습니다." }
            switch status {
            case .preparing, .transcribing:
                return model.processingProgress.isEmpty ? "전사를 준비하고 있습니다." : model.processingProgress
            case .summarizing:
                return "전사는 완료되었고 요약을 만들고 있습니다."
            case .failed:
                return "전사를 만들지 못했습니다. 위 오류를 확인한 뒤 다시 시도하세요."
            case .cancelled:
                return "전사가 취소되었습니다. 준비되면 다시 시작할 수 있습니다."
            case .notStarted:
                return model.hasAPIKey
                    ? "전사와 요약 시작을 눌러 처리를 시작하세요."
                    : "OpenAI API 키를 설정한 뒤 전사를 시작할 수 있습니다."
            case .ready, .paused, .partial:
                return "저장된 전사를 불러오지 못했습니다. 세션을 다시 열어 보세요."
            }
        }
        return transcript.segments.map { "[\(AppModel.clock($0.startMs))] \($0.text)" }.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var transcriptEditor: some View {
        if let transcript = model.transcript {
            VStack(alignment: .leading, spacing: 10) {
                Text("문장을 교정해도 시간 정보와 원본 전사는 유지됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.transcriptDraft)
                    .font(.body.monospaced())
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                HStack {
                    Button("교정본 저장", systemImage: "checkmark.circle") {
                        Task { await model.saveTranscriptCorrection() }
                    }
                    .disabled(model.isBusy)
                    Spacer()
                    Text("시간을 누르면 해당 구간을 재생합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(transcript.segments) { segment in
                            Button(AppModel.clock(segment.startMs)) {
                                Task { await model.replaySegment(segment) }
                            }
                            .help(segment.text)
                        }
                    }
                }
            }
            .padding(20)
        } else {
            ContentUnavailableView(
                "전체 전사가 없습니다",
                systemImage: "text.alignleft",
                description: Text(transcriptText)
            )
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = model.summary {
            let document = MarkdownExporter().summaryDocument(summary, title: model.session?.title)
            VStack(alignment: .leading, spacing: 24) {
                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.title3.weight(.semibold))
                        SummaryItemsView(items: section.items, numbered: section.numbered)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "요약이 없습니다",
                systemImage: "list.bullet.rectangle",
                description: Text(model.transcript == nil ? "전사가 끝나면 요약을 생성할 수 있습니다." : "요약 생성을 눌러 목적에 맞는 문서를 만드세요.")
            )
        }
    }
}

private struct SummaryItemsView: View {
    let items: [SummaryDocumentItem]
    let numbered: Bool
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: depth == 0 ? 9 : 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 9) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: numbered ? 20 : 10, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 5) {
                        Text((try? AttributedString(markdown: item.text)) ?? AttributedString(item.text))
                            .textSelection(.enabled)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !item.children.isEmpty {
                            SummaryItemsView(items: item.children, numbered: false, depth: depth + 1)
                                .padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }
}

private struct RecordingLevelMeter: View {
    let label: String
    let level: Float

    private var clampedLevel: CGFloat { CGFloat(min(1, max(0, level))) }
    private var stateText: String {
        if level < 0.08 { return "소리 없음" }
        if level < 0.25 { return "작음" }
        if level > 0.9 { return "너무 큼" }
        return "적정"
    }
    private var meterColor: Color {
        if level < 0.25 { return .orange }
        if level > 0.9 { return .red }
        return .green
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .frame(width: 54, alignment: .trailing)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(meterColor.gradient)
                        .frame(width: max(4, proxy.size.width * clampedLevel))
                        .animation(.linear(duration: 0.08), value: clampedLevel)
                }
            }
            .frame(height: 12)

            Text(stateText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(meterColor)
                .frame(width: 50, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) 입력 음량")
        .accessibilityValue(stateText)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }
}

private struct NoticeBanner: View {
    enum Kind {
        case information, warning, error

        var color: Color {
            switch self {
            case .information: .blue
            case .warning: .orange
            case .error: .red
            }
        }

        var icon: String {
            switch self {
            case .information: "info.circle.fill"
            case .warning: "exclamationmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    let message: String
    let kind: Kind

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.icon)
                .foregroundStyle(kind.color)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("OpenAI API 키") {
                HStack {
                    SecureField(model.hasAPIKey ? "새 API 키로 변경" : "OpenAI API 키", text: $model.apiKeyDraft)
                    Button(model.hasAPIKey ? "변경" : "저장") { model.saveAPIKey() }
                        .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                }
                HStack {
                    Label(model.hasAPIKey ? "키체인에 저장됨" : "설정되지 않음", systemImage: model.hasAPIKey ? "checkmark.circle.fill" : "key.fill")
                        .foregroundStyle(model.hasAPIKey ? .green : .orange)
                    Spacer()
                    Button("연결 확인") { Task { await model.testAPIConnection() } }
                        .disabled(!model.hasAPIKey || model.isBusy)
                    if model.hasAPIKey {
                        Button("키 삭제", role: .destructive) { model.removeAPIKey() }
                            .disabled(model.isBusy)
                    }
                }
                Text(model.apiNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("API 모델") {
                Picker("전사", selection: $model.transcriptionModelID) {
                    Text("GPT-Transcribe · 정확도 권장").tag(OpenAIConfiguration.defaultTranscriptionModel)
                    Text("GPT-4o Mini Transcribe · 저비용").tag(OpenAIConfiguration.economicalTranscriptionModel)
                }
                Picker("요약", selection: $model.summaryModelID) {
                    Text("GPT-5.6 Luna · 빠르고 저비용").tag(OpenAIConfiguration.defaultSummaryModel)
                    Text("GPT-5.6 Terra · 품질 우선").tag(OpenAIConfiguration.qualitySummaryModel)
                }
                Text("처리할 때 오디오와 전사문이 OpenAI API로 전송됩니다. 요약 요청은 응답 저장 옵션(store)을 끈 상태로 전송합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
