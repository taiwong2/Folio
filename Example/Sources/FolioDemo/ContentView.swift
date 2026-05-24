import SwiftUI
import UniformTypeIdentifiers
import Folio

struct ContentView: View {
    @Environment(DemoState.self) private var state
    @State private var showingPicker = false
    @State private var showingInspector = false

    var body: some View {
        @Bindable var bound = state

        VStack(alignment: .leading, spacing: 16) {
            Text("Folio RAG Demo")
                .font(.title2.bold())

            backendSection(bound: $bound)

            Divider()

            embedderSection(bound: $bound)

            Divider()

            ingestSection

            Divider()

            askSection(bound: $bound)

            Divider()

            answerSection

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 640)
        .fileImporter(
            isPresented: $showingPicker,
            // `.text` is the parent UTI for plain text, markdown, source files, JSON, etc.
            // — broad enough that any text-like document can be picked. `UTType.markdown`
            // isn't exposed as a static, so this is the cleanest way to include `.md`.
            allowedContentTypes: [.pdf, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await state.ingestPickedFile(url: url) }
            case .failure(let error):
                state.status = "File picker failed: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showingInspector) {
            ChunkInspectorView(chunks: state.inspectedChunks, sourceName: state.currentSourceId)
        }
    }

    @ViewBuilder
    private func backendSection(bound: Bindable<DemoState>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generator").font(.headline)
            Picker("Backend", selection: bound.backend) {
                ForEach(DemoState.Backend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            if state.backend == .openAI {
                HStack {
                    TextField("Model (e.g. gpt-4o-mini)", text: bound.openAIModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    SecureField("OpenAI API key", text: bound.openAIKey)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Text("Runs entirely on-device when Foundation Models is available (iOS 26+/macOS 26+).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func embedderSection(bound: Bindable<DemoState>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Embedder").font(.headline)
            Picker("Embedder", selection: bound.embedderMode) {
                ForEach(DemoState.EmbedderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: state.embedderMode) { _, _ in
                // Switching back into Core ML re-triggers the warm-up so the
                // user doesn't pay the load cost on their first ask.
                state.warmUpEmbeddingGemmaIfNeeded()
            }

            Toggle(isOn: bound.useContextualPrefixes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contextual prefixes").font(.callout)
                    Text("Use Apple Foundation Models to write a short 'this chunk is about X' line per chunk before embedding. Better retrieval, ~1 s extra per chunk on first ingest.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            switch state.embedderMode {
            case .none:
                Text("Retrieval will use BM25 only — no vector search. Fast, no setup, but exact-word matches only.")
                    .font(.caption).foregroundStyle(.secondary)

            case .embeddingGemmaCoreML:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if state.embeddingGemmaReady {
                            Label("ready", systemImage: "checkmark.seal.fill")
                                .font(.caption2).foregroundStyle(.green)
                        } else {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("preparing model…").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    Text("Genuine on-device EmbeddingGemma 300M via Core ML + Apple Neural Engine. First use downloads the model bundle (~300 MB) to ~/Library/Application Support/Folio/models/. Warm-up runs in the background at app launch so your first ask is instant.")
                        .font(.caption).foregroundStyle(.secondary)
                }

            case .ollama:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Needs `ollama serve` running locally with `ollama pull embeddinggemma`.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Ollama model", text: bound.ollamaEmbeddingModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        TextField("Base URL", text: bound.ollamaBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }

            case .openAI:
                HStack {
                    TextField("OpenAI embedding model", text: bound.openAIEmbeddingModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Text("Uses the OpenAI API key from above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ingestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Document").font(.headline)
            Text(state.currentSourceId ?? "No document indexed yet.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Ingest sample") {
                    Task { await state.ingestSample() }
                }
                .disabled(state.isBusy)

                Button("Pick document…") {
                    showingPicker = true
                }
                .disabled(state.isBusy)

                Button("Inspect chunks") {
                    Task {
                        await state.loadChunks()
                        showingInspector = true
                    }
                }
                .disabled(state.isBusy || !state.isIngested)

                if state.isIngested {
                    Label("Indexed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            Text("Supported: PDF, plain text, markdown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func askSection(bound: Bindable<DemoState>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Question").font(.headline)
            TextField("Ask something about the indexed document…", text: bound.question)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Ask") {
                    Task { await state.ask() }
                }
                .disabled(state.isBusy || !state.isIngested)
                .keyboardShortcut(.return, modifiers: [.command])

                if state.isBusy {
                    ProgressView().controlSize(.small)
                }

                Text(state.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answer").font(.headline)
            ScrollView {
                Text(state.streamedAnswer.isEmpty ? "— streamed output appears here —" : state.streamedAnswer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(state.streamedAnswer.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)

            if !state.usedPassages.isEmpty {
                DisclosureGroup("Retrieved passages (\(state.usedPassages.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(state.usedPassages.enumerated()), id: \.offset) { (index, passage) in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("[\(index + 1)]").font(.caption.monospaced()).foregroundStyle(.tint)
                                        Text(passage.citations.first?.sourceName ?? passage.sourceId)
                                            .font(.caption.bold())
                                        if let page = passage.startPage {
                                            Text("p.\(page)").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(String(format: "bm25 %.2f  cos %@",
                                                    passage.bm25,
                                                    passage.cosine.map { String(format: "%.2f", $0) } ?? "—"))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(passage.excerpt.isEmpty ? passage.text : passage.excerpt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                        .textSelection(.enabled)
                                }
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .font(.subheadline)
            }

            if !state.citations.isEmpty {
                Text("Citations (\(state.citations.count))").font(.subheadline.bold())
                ForEach(Array(state.citations.enumerated()), id: \.offset) { (index, citation) in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(index + 1)]").font(.callout.monospaced()).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(citation.sourceName).font(.callout)
                            if let section = citation.sectionTitle {
                                Text(section).font(.caption).foregroundStyle(.secondary)
                            }
                            if let excerpt = citation.excerpt {
                                Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            } else if !state.usedPassages.isEmpty && !state.streamedAnswer.isEmpty {
                // The model returned an answer but didn't emit [N] markers. Don't
                // hide the citations region silently — say what happened so the
                // user knows the answer is still grounded in the retrieved
                // passages above (just not pinpointed sentence-by-sentence).
                VStack(alignment: .leading, spacing: 4) {
                    Label("No inline citations", systemImage: "questionmark.circle")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                    Text("The model answered without inline [N] markers — common with smaller on-device models. The answer is still grounded in the **Retrieved passages** above; the model just didn't pinpoint which one supports which claim. Cloud models (GPT-4, Claude) emit markers reliably.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

#Preview {
    ContentView().environment(DemoState())
}

/// Sheet that lists every chunk Folio stored for the current document so the user
/// can verify the chunker produced what they expect — and that text Folio "should"
/// have actually made it past PDFKit / markdown / plain-text extraction.
struct ChunkInspectorView: View {
    let chunks: [InspectableChunk]
    let sourceName: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inspecting chunks").font(.headline)
                    Text(sourceName ?? "—").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(chunks.count) chunk(s), \(totalChars) total chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            Divider()

            if chunks.isEmpty {
                Spacer()
                Text("No chunks. Either the document hasn't been ingested or extraction produced no text.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(chunks.enumerated()), id: \.offset) { (index, chunk) in
                            chunkCard(index: index + 1, chunk: chunk)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
    }

    private var totalChars: Int {
        chunks.reduce(0) { $0 + $1.text.count }
    }

    @ViewBuilder
    private func chunkCard(index: Int, chunk: InspectableChunk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(index)").font(.caption.monospaced()).foregroundStyle(.tint)
                if let page = chunk.page {
                    Text("p.\(page)").font(.caption2).foregroundStyle(.secondary)
                }
                if let section = chunk.sectionTitle {
                    Text(section).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(chunk.text.count) chars")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !chunk.contextPrefix.isEmpty {
                // Surface the contextual prefix as a distinct, labelled line so
                // the user can see what the prefix generator produced vs. the
                // raw chunk text Folio stored.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefix")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(chunk.contextPrefix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(chunk.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
