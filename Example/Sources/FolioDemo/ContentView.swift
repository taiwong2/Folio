import SwiftUI
import Folio

struct ContentView: View {
    @Environment(DemoState.self) private var state

    var body: some View {
        @Bindable var bound = state

        VStack(alignment: .leading, spacing: 16) {
            Text("Folio RAG Demo")
                .font(.title2.bold())

            backendSection(bound: $bound)

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

    private var ingestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample document").font(.headline)
            Text(SampleDocument.name).foregroundStyle(.secondary)
            HStack {
                Button(state.isIngested ? "Re-ingest" : "Ingest sample") {
                    Task { await state.ingestSample() }
                }
                .disabled(state.isBusy)

                if state.isIngested {
                    Label("Indexed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private func askSection(bound: Bindable<DemoState>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Question").font(.headline)
            TextField("Ask something about the sample…", text: bound.question)
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
            .frame(maxHeight: 220)

            if !state.citations.isEmpty {
                Text("Citations").font(.subheadline.bold())
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
            }
        }
    }
}

#Preview {
    ContentView().environment(DemoState())
}
