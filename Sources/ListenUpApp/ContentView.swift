import SwiftUI
import ListenUpAI
import ListenUpDomain
import ListenUpExport

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.showResults) {
                Label("새 녹음", systemImage: "record.circle").tag(false)
                Label("현재 결과", systemImage: "doc.text").tag(true)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if model.showResults { ResultView() } else { RecordingView() }
        }
    }
}

private struct RecordingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.isRecording ? "녹음 중" : "새 녹음")
                    .font(.largeTitle.bold())

                if model.isRecording {
                    recordingPanel
                } else {
                    setupForm
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text(model.notice).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var setupForm: some View {
        Form {
            Section("OpenAI API") {
                apiConfiguration
            }
            TextField("제목", text: $model.title)
                .accessibilityLabel("녹음 제목")
            Picker("용도", selection: $model.purpose) {
                ForEach(SessionPurpose.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("입력", selection: $model.inputSource) {
                Text("마이크").tag(InputSource.microphone)
                Text("선택한 앱 소리").tag(InputSource.systemAudio)
                Text("마이크와 앱 소리").tag(InputSource.microphoneAndSystem)
            }
            if model.requiresSystemAudio {
                HStack {
                    Picker("녹음할 앱", selection: $model.selectedApplicationID) {
                        Text("선택").tag(String?.none)
                        ForEach(model.availableApplications) { app in Text(app.name).tag(Optional(app.id)) }
                    }
                    Button("새로 고침") { Task { await model.refreshApplications() } }
                        .disabled(model.isBusy || model.captureActive)
                }
            }
            TextField("언어 (쉼표로 구분)", text: $model.languages)
            TextField("전문 용어 (쉼표로 구분)", text: $model.keywords)
            TextField("추가 문맥", text: $model.notes, axis: .vertical).lineLimit(3...6)
            LabeledContent("저장 폴더") {
                HStack {
                    Text(model.rootDirectory?.path ?? "선택되지 않음").lineLimit(1).truncationMode(.middle)
                    Button("선택…") { model.chooseRootDirectory() }
                        .disabled(model.isBusy || model.captureActive)
                }
            }
            HStack {
                Button("오디오 가져오기…", systemImage: "square.and.arrow.down") { Task { await model.importAudio() } }
                    .disabled(model.isBusy || model.captureActive)
                Button("세션 열기…", systemImage: "folder") { Task { await model.reopenSession() } }
                    .disabled(model.isBusy || model.captureActive)
                Spacer()
                Button("녹음 시작") { Task { await model.startRecording() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.isBusy || model.captureActive)
                    .accessibilityHint("선택한 입력 소스를 녹음합니다")
            }
        }
        .formStyle(.grouped)
    }

    private var apiConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                model.hasAPIKey ? "API 키 설정됨" : "API 키 필요",
                systemImage: model.hasAPIKey ? "checkmark.circle.fill" : "key.fill"
            )
            .foregroundStyle(model.hasAPIKey ? .green : .orange)
            if !model.hasAPIKey {
                SecureField("OpenAI API 키", text: $model.apiKeyDraft)
                Button("API 키 저장") { model.saveAPIKey() }
                    .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(model.apiNotice).font(.caption).foregroundStyle(.secondary)
            Text("전사할 오디오와 요약할 전사문이 OpenAI API로 전송됩니다. 결과 파일은 선택한 로컬 폴더에 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingPanel: some View {
        VStack(spacing: 24) {
            Text(AppModel.clock(model.elapsedMs)).font(.system(size: 48, weight: .semibold, design: .monospaced))
                .accessibilityLabel("녹음 시간 \(AppModel.clock(model.elapsedMs))")
            Text("확정된 오디오 조각 \(model.session?.tracks.count ?? 0)개")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("15초 뒤로 듣기", systemImage: "gobackward.15") { Task { await model.rewind() } }
                Button("다시 듣기 정지", systemImage: "stop.fill") { Task { await model.stopReplay() } }
                Button("실시간 위치", systemImage: "dot.radiowaves.left.and.right") { Task { await model.returnToLive() } }
            }
            HStack(spacing: 12) {
                Button("북마크", systemImage: "bookmark") { Task { await model.addBookmark() } }
                Spacer()
                Button("녹음 종료", systemImage: "stop.circle.fill", role: .destructive) { Task { await model.stopRecording() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            }
        }
        .padding(24)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ResultView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.session?.title ?? "현재 결과").font(.largeTitle.bold())
            if let session = model.session {
                HStack {
                    Label(session.purpose.displayName, systemImage: session.purpose == .lecture ? "graduationcap" : "person.3")
                    Text("•")
                    Text("오디오 \(session.tracks.count)개")
                    Text("•")
                    Text(processingStatusText(session.processingStatus))
                    Spacer()
                    Picker("결과 용도", selection: Binding(
                        get: { model.session?.purpose ?? model.purpose },
                        set: { value in Task { await model.changePurpose(value) } }
                    )) {
                        ForEach(SessionPurpose.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .frame(width: 180)
                    .disabled(model.isBusy || model.captureActive)
                }.foregroundStyle(.secondary)
                if session.summaryStale {
                    Label("용도, 교정본 또는 제외 구간이 바뀌어 기존 요약의 갱신이 필요합니다.", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
            } else {
                ContentUnavailableView("아직 녹음이 없습니다", systemImage: "waveform", description: Text("새 녹음을 완료하면 원문과 요약이 여기에 표시됩니다."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.session != nil {
                apiPanel
                if !model.resultNotice.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.session?.processingStatus == .failed ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(model.session?.processingStatus == .failed ? .red : .blue)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.resultNotice).textSelection(.enabled)
                            if model.session?.processingStatus == .failed || model.session?.processingStatus == .partial {
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
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.session?.processingStatus == .failed ? Color.red : Color.blue).opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Button("세션 폴더 열기", systemImage: "folder") { model.openSessionFolder() }
                    Button(model.hasCompleteTranscript ? "전사 완료" : (model.hasAPIKey ? "OpenAI 처리 시작" : "API 키 설정 후 처리"), systemImage: "waveform.and.magnifyingglass") { Task { await model.processSession() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.hasCompleteTranscript || !model.hasAPIKey || (model.session?.captureStatus != .stopped && model.session?.captureStatus != .interrupted))
                    Button(model.summary == nil ? "요약 생성" : "요약 다시 생성", systemImage: "arrow.clockwise") { Task { await model.regenerateSummary() } }
                        .disabled(model.isBusy || model.transcript == nil || !model.hasAPIKey)
                    Spacer()
                }
                if shouldShowProcessingIndicator {
                    ProgressView(model.processingProgress)
                }
                TabView {
                    transcriptEditor
                        .tabItem { Text("전체 전사") }
                    ScrollView { summaryContent.frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .tabItem { Text("요약") }
                }
                HStack {
                    Button("요약 복사") { model.copyResult(.summary) }.disabled(model.summary == nil)
                    Button("전체 전사 복사") { model.copyResult(.transcript) }.disabled(model.transcript == nil)
                    Button("요약 + 전체 복사") { model.copyResult(.combined) }.disabled(model.transcript == nil)
                }
            }
        }
        .padding(28)
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

    private var apiPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("OpenAI API", systemImage: "network")
                        .font(.headline)
                    Spacer()
                    Label(model.hasAPIKey ? "연결 설정됨" : "API 키 필요", systemImage: model.hasAPIKey ? "checkmark.circle.fill" : "key.fill")
                        .foregroundStyle(model.hasAPIKey ? .green : .orange)
                }
                if !model.hasAPIKey {
                    HStack {
                        SecureField("OpenAI API 키", text: $model.apiKeyDraft)
                        Button("저장") { model.saveAPIKey() }
                            .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Text("오디오는 \(model.transcriptionModelID), 요약은 \(model.summaryModelID) 모델로 처리합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.apiNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(4)
        }
    }

    private func processingStatusText(_ status: ProcessingStatus) -> String {
        switch status {
        case .notStarted: "전사 대기"
        case .preparing: "처리 준비 중"
        case .transcribing: "전사 중"
        case .summarizing: "요약 중"
        case .ready: "처리 완료"
        case .paused: "처리 일시정지됨"
        case .partial: "부분 완료"
        case .failed: "처리 실패"
        case .cancelled: "처리 취소됨"
        }
    }

    private var transcriptText: String {
        guard let transcript = model.transcript else { return "OpenAI API 키를 설정한 뒤 전사를 시작할 수 있습니다." }
        return transcript.segments.map { "[\(AppModel.clock($0.startMs))] \($0.text)" }.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var transcriptEditor: some View {
        if let transcript = model.transcript {
            VStack(alignment: .leading, spacing: 8) {
                Text("한 줄이 한 전사 구간입니다. 문장을 교정해도 시간 범위와 원본 리비전은 보존됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.transcriptDraft)
                    .font(.body.monospaced())
                    .frame(minHeight: 170)
                    .border(Color(nsColor: .separatorColor))
                HStack {
                    Button("교정본 저장", systemImage: "checkmark.circle") { Task { await model.saveTranscriptCorrection() } }
                        .disabled(model.isBusy)
                    Spacer()
                    Text("근거 구간 재생").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(transcript.segments) { segment in
                            Button("\(AppModel.clock(segment.startMs))") { Task { await model.replaySegment(segment) } }
                                .help(segment.text)
                        }
                    }
                }
            }
            .padding()
        } else {
            Text(transcriptText).frame(maxWidth: .infinity, alignment: .leading).padding()
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = model.summary {
            let document = MarkdownExporter().summaryDocument(summary, title: model.session?.title)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(.headline)
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(section.numbered ? "\(index + 1)." : "•")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.text).textSelection(.enabled)
                                    if let detail = item.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            Text("전사가 끝나면 OpenAI API로 요약을 생성합니다.")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("저장 위치") {
                LabeledContent("세션") { Text(model.rootDirectory?.path ?? "선택되지 않음").lineLimit(1) }
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
                Text(model.apiNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
