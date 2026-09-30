import SwiftUI
import UniformTypeIdentifiers

@main
struct AppWrapperApp: App {
    var body: some Scene {
        WindowGroup("AppWrapper") { ContentView() }
            .defaultSize(width: 760, height: 480)
    }
}

struct ContentView: View {
    @State private var wrappers = Wrapper.all()
    @State private var selection: String?
    @State private var draft = Wrapper()
    @State private var busy = false
    @State private var error: String?
    @State private var searchingIcons = false
    @State private var iconVersion = 0  // bump to re-read the custom icon file

    var body: some View {
        NavigationSplitView {
            List(wrappers, selection: $selection) { w in
                Label {
                    Text(w.name)
                } icon: {
                    Image(nsImage: Wrapper.appIcon(w.url!))
                        .resizable().frame(width: 20, height: 20)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .toolbar {
                Button { selection = nil; draft = Wrapper() } label: { Image(systemName: "plus") }
                    .help("New wrapper")
            }
        } detail: {
            editor
        }
        .onChange(of: selection) { _, id in
            draft = wrappers.first { $0.id == id } ?? Wrapper()
        }
        .alert("Couldn't build wrapper", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var editor: some View {
        Form {
            LabeledContent("Source app") {
                HStack {
                    if let src = draft.source {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: src.path)).resizable().frame(width: 20, height: 20)
                        Text(src.lastPathComponent)
                    }
                    Button("Choose…", action: chooseSource)
                }
            }
            TextField("Name", text: $draft.name, prompt: Text("e.g. Slack Work"))
            Toggle("Separate data (logins, settings, cache)", isOn: $draft.isolated)
            iconSection
            Section {
                TextEditor(text: $draft.envText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
            } header: {
                Text("Environment variables")
            } footer: {
                Text("One KEY=value per line. Wrappers live in ~/Applications, drag them to the Dock like any app.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let url = draft.url {
                    Button("Launch") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Delete", role: .destructive) { delete(url) }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(draft.url == nil ? "Create" : "Save & Rebuild", action: build)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || draft.source == nil || draft.name.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private var iconSection: some View {
        Section("Icon") {
            HStack(alignment: .top, spacing: 16) {
                let _ = iconVersion
                Group {
                    if let icon = draft.renderIcon() {
                        Image(nsImage: icon).resizable()
                    } else if let src = draft.source {
                        Image(nsImage: Wrapper.appIcon(src)).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                    }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading) {
                    HStack {
                        TextField("Badge", text: $draft.badge, prompt: Text("e.g. WORK"))
                            .onChange(of: draft.badge) { _, v in
                                let clean = String(v.uppercased().prefix(6))
                                if clean != v { draft.badge = clean }
                            }
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: draft.badgeColor) },
                            set: { draft.badgeColor = NSColor($0) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                    HStack {
                        Button("Search macosicons.com…") { searchingIcons = true }
                        Button("Choose Image…", action: chooseIcon)
                        if FileManager.default.fileExists(atPath: draft.customIconFile.path) {
                            Button("Reset") {
                                try? FileManager.default.removeItem(at: draft.customIconFile)
                                iconVersion += 1
                            }
                        }
                    }
                    .disabled(draft.source == nil)
                }
            }
        }
        .sheet(isPresented: $searchingIcons) {
            IconSearchView(initialQuery: draft.source?.deletingPathExtension().lastPathComponent ?? "") { url in
                Task {
                    do { try setCustomIcon(try await URLSession.shared.data(from: url).0) }
                    catch { self.error = "Icon download failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try setCustomIcon(try Data(contentsOf: url)) } catch { self.error = error.localizedDescription }
    }

    private func setCustomIcon(_ data: Data) throws {
        guard NSImage(data: data) != nil else { throw Wrapper.BuildError(errorDescription: "That file isn't an image.") }
        let file = draft.customIconFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        iconVersion += 1
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.source = url.resolvingSymlinksInPath()  // /Applications/Safari.app is a symlink
        if draft.name.isEmpty { draft.name = url.deletingPathExtension().lastPathComponent + " 2" }
    }

    private func build() {
        busy = true
        let draft = draft
        Task.detached {
            let result = Result { try draft.build() }
            await MainActor.run {
                busy = false
                switch result {
                case .success: reload(select: draft.id)
                case .failure(let e): error = e.localizedDescription
                }
            }
        }
    }

    private func delete(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(draft.name)” to the Trash?"
        alert.informativeText = "Its data folder (\(draft.homeDir.path)) is left in place."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload(select: nil)
    }

    private func reload(select id: String?) {
        wrappers = Wrapper.all()
        selection = id
        draft = wrappers.first { $0.id == id } ?? Wrapper()
    }
}
