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
                    storageSetup
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
                 ? "녹음은 계속 진행됩니다. 필요한 부분을 다시 들으며 북마크를 남길 수 있습니다."
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
                    .task {
                        await model.loadApplicationsIfNeeded()
                    }
                }
            }
        }
    }

    private var storageSetup: some View {
        SectionCard(
            title: "저장 위치",
            subtitle: "오디오, 전체 전사와 요약을 선택한 폴더 안에 함께 보관합니다.",
            systemImage: "folder"
        ) {
            HStack(spacing: 12) {
                Image(systemName: model.rootDirectory == nil ? "folder.badge.questionmark" : "checkmark.circle.fill")
                    .foregroundStyle(model.rootDirectory == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.rootDirectory?.lastPathComponent ?? "저장 폴더를 선택하세요")
                        .font(.subheadline.weight(.medium))
                    if let path = model.rootDirectory?.path {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button(model.rootDirectory == nil ? "폴더 선택…" : "변경…") {
                    model.chooseRootDirectory()
                }
                .disabled(model.isBusy || model.captureActive)
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
            VStack(spacing: 26) {
                Text(AppModel.clock(model.elapsedMs))
                    .font(.system(size: 50, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("녹음 시간 \(AppModel.clock(model.elapsedMs))")

                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("녹음 중")
                    Text("·")
                    Text("저장된 오디오 조각 \(model.session?.tracks.count ?? 0)개")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("15초 전부터 듣기", systemImage: "gobackward.15") { Task { await model.rewind() } }
                    Button("다시 듣기 정지", systemImage: "stop.fill") { Task { await model.stopReplay() } }
                    Button("현재 위치로", systemImage: "dot.radiowaves.left.and.right") { Task { await model.returnToLive() } }
                }

                Divider()

                HStack {
                    Button("북마크", systemImage: "bookmark") { Task { await model.addBookmark() } }
                    Spacer()
                    Button("녹음 종료", systemImage: "stop.circle.fill", role: .destructive) {
                        Task { await model.stopRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }
            }
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
            return "저장 폴더를 선택하면 녹음을 시작할 수 있습니다."
        }
        if model.requiresSystemAudio && model.selectedApplication == nil {
            return "소리를 녹음할 앱을 선택하면 녹음을 시작할 수 있습니다."
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

    var body: some View {
        Group {
            if let session = model.session {
                VStack(alignment: .leading, spacing: 18) {
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
                    copyActions
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
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
            Button("세션 폴더 열기", systemImage: "folder") { model.openSessionFolder() }

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

            Button("결과물 내보내기", systemImage: "square.and.arrow.up") {
                Task { await model.exportResultBundle() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || model.captureActive || model.transcript == nil || model.summary == nil || session.tracks.isEmpty)

            Spacer()
        }
    }

    private var resultTabs: some View {
        TabView {
            transcriptEditor
                .tabItem { Label("전체 전사", systemImage: "text.alignleft") }
            ScrollView {
                summaryContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .tabItem { Label("요약", systemImage: "list.bullet.rectangle") }
        }
        .frame(minHeight: 430)
    }

    private var copyActions: some View {
        HStack(spacing: 10) {
            Text("Notion에 붙여넣기 좋은 형식으로 복사됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("전체 전사 복사") { model.copyResult(.transcript) }
                .disabled(model.transcript == nil)
            Button("요약 복사") { model.copyResult(.summary) }
                .disabled(model.summary == nil)
            Button("요약 + 전체 복사", systemImage: "doc.on.doc") { model.copyResult(.combined) }
                .buttonStyle(.borderedProminent)
                .disabled(model.transcript == nil)
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
        guard let transcript = model.transcript else { return "OpenAI API 키를 설정한 뒤 전사를 시작할 수 있습니다." }
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
                    .frame(minHeight: 240)
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
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 9) {
                                Text(section.numbered ? "\(index + 1)." : "•")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: section.numbered ? 20 : 10, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.text).textSelection(.enabled)
                                    if let detail = item.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
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
            Section("저장 위치") {
                LabeledContent("세션") {
                    Text(model.rootDirectory?.path ?? "선택되지 않음")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("폴더 변경…") { model.chooseRootDirectory() }
                    .disabled(model.isBusy || model.captureActive)
            }
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
