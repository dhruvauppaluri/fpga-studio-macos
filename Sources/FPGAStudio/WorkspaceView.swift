import FPGAStudioCore
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            VSplitView {
                EditorArea()
                    .frame(minHeight: 320)
                BottomPanel()
                    .frame(minHeight: 160, idealHeight: 230)
            }
        }
        .inspector(isPresented: $workspace.showingInspector) {
            ProjectInspector()
                .inspectorColumnWidth(min: 250, ideal: 290, max: 360)
        }
        .navigationTitle(workspace.project?.name ?? "FPGA Studio")
        .toolbar { workspaceToolbar }
        .sheet(isPresented: $workspace.showingNewProject) { NewProjectSheet() }
        .sheet(isPresented: $workspace.showingFlashConfirmation) { FlashConfirmationView() }
        .sheet(isPresented: $workspace.showingSimulationTrust) { SimulationTrustView() }
        .alert("FPGA Studio", isPresented: errorBinding) {
            Button("OK") { workspace.lastError = nil }
        } message: { Text(workspace.lastError ?? "") }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { workspace.perform(.validate) } label: { Label("Validate", systemImage: "checkmark.circle") }
                .disabled(!workspace.canRun)
            Button { workspace.simulateSelectedTest() } label: { Label("Simulate", systemImage: "waveform.path.ecg") }
                .disabled(!workspace.canSimulate)
            Button { workspace.perform(.build) } label: { Label("Build", systemImage: "hammer") }
                .disabled(!workspace.canRun)
            Divider()
            Button { workspace.perform(.programSRAM) } label: { Label("Program SRAM", systemImage: "bolt.horizontal.circle") }
                .disabled(!workspace.canRun)
            Menu {
                Button("Program SRAM") { workspace.perform(.programSRAM) }
                Divider()
                Button("Program Flash…") { workspace.prepareFlash() }
            } label: { Image(systemName: "chevron.down.circle") }
            .disabled(!workspace.canRun)
        }
        ToolbarItem(placement: .status) {
            if workspace.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stageLabel).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { workspace.cancel() }.buttonStyle(.borderless).disabled(!workspace.canCancel)
                }
            } else {
                Label(workspace.boardConnected ? "C5G Connected" : "C5G Offline", systemImage: workspace.boardConnected ? "cable.connector" : "cable.connector.slash")
                    .font(.caption).foregroundStyle(workspace.boardConnected ? .green : .secondary)
            }
        }
        ToolbarItem {
            Button { workspace.showingInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }

    private var stageLabel: String { workspace.stage.rawValue.replacingOccurrences(of: "programming", with: "Programming ").capitalized }
    private var errorBinding: Binding<Bool> { Binding(get: { workspace.lastError != nil }, set: { if !$0 { workspace.lastError = nil } }) }
}

private struct ProjectSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceController

    var body: some View {
        List {
            if let project = workspace.project {
                Section("Project") {
                    ForEach(project.sources) { source in
                        Button { workspace.openSource(source) } label: {
                            Label(source.path, systemImage: source.isTestbench ? "testtube.2" : "doc.text")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(workspace.selectedDocumentID == source.id ? Color.accentColor : .primary)
                        .contextMenu { Button("Open") { workspace.openSource(source) } }
                    }
                }
                Section("Test Targets") {
                    ForEach(project.tests) { test in
                        Button {
                            workspace.selectedTestID = test.id
                            workspace.selectedBottomTab = "Simulation"
                        } label: {
                            HStack {
                                Label(test.name, systemImage: "play.square")
                                Spacer()
                                if workspace.selectedTestID == test.id { Image(systemName: "checkmark").foregroundStyle(.blue) }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if !workspace.artifacts.isEmpty {
                    Section("Build History") {
                        ForEach(workspace.artifacts) { artifact in
                            Label(artifact.kind, systemImage: artifact.kind.contains("RBF") ? "shippingbox.fill" : "doc.badge.gearshape")
                        }
                    }
                }
                Section("Device") {
                    Button { workspace.perform(.detectDevice) } label: {
                        HStack {
                            Label("Terasic C5G", systemImage: "cpu")
                            Spacer()
                            Circle().fill(workspace.boardConnected ? .green : .secondary).frame(width: 7, height: 7)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { workspace.closeProject() } label: { Image(systemName: "xmark.circle") }.help("Close Project").disabled(workspace.isRunning)
                Button { workspace.showingNewProject = true } label: { Image(systemName: "plus") }.help("New Project")
                Spacer()
            }
            .buttonStyle(.borderless).padding(10).background(.bar)
        }
    }
}

private struct EditorArea: View {
    @EnvironmentObject private var workspace: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspace.documents) { document in
                            Button { workspace.selectedDocumentID = document.id } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "doc.text").font(.caption)
                                    Text(document.title)
                                    if document.isDirty { Circle().frame(width: 6, height: 6) }
                                }
                                .padding(.horizontal, 13).frame(height: 36)
                                .background(workspace.selectedDocumentID == document.id ? Color(nsColor: .textBackgroundColor) : .clear)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 10)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find", text: $workspace.searchText).textFieldStyle(.plain).frame(width: 150).padding(.trailing, 10)
            }
            .background(.bar)
            Divider()
            if let document = workspace.selectedDocument {
                CodeEditor(text: Binding(get: { document.text }, set: { workspace.updateSelectedText($0) }), language: document.language, searchText: workspace.searchText)
                    .id(document.id)
            } else {
                ContentUnavailableView("No Source Selected", systemImage: "doc.text", description: Text("Choose a file in the project navigator."))
            }
        }
    }
}

private struct BottomPanel: View {
    @EnvironmentObject private var workspace: WorkspaceController
    private let tabs = ["Issues", "Build Log", "Simulation", "Waveform", "Programmer"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $workspace.selectedBottomTab) {
                    ForEach(tabs, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                Spacer()
                if workspace.selectedBottomTab == "Issues" {
                    Text("\(workspace.diagnostics.filter { $0.severity == .error }.count) errors · \(workspace.diagnostics.filter { $0.severity == .warning }.count) warnings")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 10).frame(height: 38).background(.bar)
            Divider()
            Group {
                switch workspace.selectedBottomTab {
                case "Issues": IssuesView()
                case "Build Log": LogView(title: "Build output")
                case "Simulation": SimulationView()
                case "Waveform": WaveformView(document: workspace.waveform)
                default: ProgrammerView()
                }
            }
        }
    }
}

private struct IssuesView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    var body: some View {
        if workspace.diagnostics.isEmpty {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle", description: Text("Validation and tool diagnostics appear here."))
        } else {
            List(workspace.diagnostics) { diagnostic in
                Button { navigate(diagnostic) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(diagnostic.severity == .error ? .red : diagnostic.severity == .warning ? .orange : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.message).lineLimit(2)
                            Text([diagnostic.tool, diagnostic.file, diagnostic.line.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain)
            }.listStyle(.plain)
        }
    }
    private func navigate(_ diagnostic: Diagnostic) {
        guard let file = diagnostic.file, let source = workspace.project?.sources.first(where: { file.hasSuffix($0.path) || $0.path == file }) else { return }
        workspace.openSource(source)
    }
}

private struct LogView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    let title: String
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(workspace.log.isEmpty ? "\(title) will appear here." : workspace.log)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

private struct SimulationView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    var body: some View {
        VStack(spacing: 12) {
            if let project = workspace.project, !project.tests.isEmpty {
                HStack {
                    Picker("Target", selection: $workspace.selectedTestID) {
                        ForEach(project.tests) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 360)
                    Button("Run") { workspace.simulateSelectedTest() }.disabled(!workspace.canSimulate)
                    Spacer()
                }.padding([.horizontal, .top], 12)
                LogView(title: "Simulation output")
            } else {
                ContentUnavailableView("No Simulation Target", systemImage: "waveform", description: Text("Add a single-language test target to fpga-project.json."))
            }
        }
    }
}

private struct ProgrammerView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Terasic Cyclone V GX Starter Kit", systemImage: "cpu")
                    .font(.headline)
                Text(workspace.boardConnected ? "USB-Blaster and JTAG chain detected" : "Connect the board and detect its JTAG chain before programming.")
                    .foregroundStyle(.secondary)
                Text(workspace.latestBitstream?.lastPathComponent ?? "No .rbf build artifact")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Detect") { workspace.perform(.detectDevice) }.disabled(!workspace.canRun)
            Button("Program SRAM") { workspace.perform(.programSRAM) }.buttonStyle(.borderedProminent).disabled(!workspace.canRun)
            Button("Flash…") { workspace.prepareFlash() }.disabled(!workspace.canRun)
        }.padding(20)
    }
}

private struct ProjectInspector: View {
    @EnvironmentObject private var workspace: WorkspaceController
    @State private var pinSearch = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                InspectorSection("Target") {
                    LabeledContent("Board", value: workspace.board.displayName)
                    LabeledContent("Device", value: workspace.board.device)
                    LabeledContent("Top", value: workspace.project?.top ?? "—")
                    LabeledContent("Clock", value: String(format: "%.1f MHz", workspace.project?.synthesis.clockMHz ?? 0))
                }
                InspectorSection("Backend") {
                    Label("Experimental", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(workspace.board.experimentalNotice).font(.caption).foregroundStyle(.secondary)
                }
                InspectorSection("Conservative Synthesis") {
                    Toggle("M10K block RAM", isOn: .constant(workspace.project?.synthesis.enableBlockRAM ?? false)).disabled(true)
                    Toggle("LUT RAM", isOn: .constant(workspace.project?.synthesis.enableLUTRAM ?? false)).disabled(true)
                    Toggle("DSP inference", isOn: .constant(workspace.project?.synthesis.enableDSP ?? false)).disabled(true)
                    Text("Edit the versioned manifest to opt into experimental resources.").font(.caption).foregroundStyle(.secondary)
                }
                InspectorSection("Pin Assignments") {
                    TextField("Search signals or pins", text: $pinSearch).textFieldStyle(.roundedBorder)
                    ForEach(filteredAssignments) { assignment in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(assignment.signal).font(.caption.bold())
                                Text(workspace.board.pins.first(where: { $0.packagePin == assignment.packagePin })?.description ?? "Unvalidated package pin")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu(assignment.packagePin) {
                                ForEach(compatiblePins(for: assignment.signal)) { pin in
                                    Button("\(pin.signal) · \(pin.packagePin)") { workspace.assign(assignment.signal, to: pin) }
                                }
                            }.menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    if filteredAssignments.isEmpty { Text("No matching QSF assignments").font(.caption).foregroundStyle(.secondary) }
                    Text("Duplicate, unknown, and direction-incompatible assignments are rejected before synthesis.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
        }
    }
    private var filteredAssignments: [PinAssignment] {
        _ = workspace.constraintsRevision
        let assignments = workspace.constraintAssignments
        return pinSearch.isEmpty ? assignments : assignments.filter { $0.signal.localizedCaseInsensitiveContains(pinSearch) || $0.packagePin.localizedCaseInsensitiveContains(pinSearch) }
    }
    private func compatiblePins(for signal: String) -> [BoardPin] {
        let base = signal.split(separator: "[").first.map(String.init) ?? signal
        guard let direction = workspace.topPortDirections[base], direction != .bidirectional else { return workspace.board.pins }
        return workspace.board.pins.filter { $0.direction == direction || $0.direction == .bidirectional }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlashConfirmationView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Program Persistent Flash").font(.title2.bold())
                    Text("This writes the C5G EPCQ configuration device.").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Board", value: workspace.board.displayName)
                    LabeledContent("Artifact", value: workspace.flashCandidate?.url.lastPathComponent ?? "Unavailable")
                    LabeledContent("Modified", value: workspace.flashCandidate?.modifiedAt.formatted(date: .abbreviated, time: .standard) ?? "Unavailable")
                    LabeledContent("Size", value: workspace.flashCandidate.map { ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file) } ?? "Unavailable")
                    LabeledContent("SHA-256", value: String(workspace.bitstreamSHA256.prefix(20)) + "…")
                }.font(.callout).padding(6)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Set the RUN/PROG switch as described by the C5G manual.", systemImage: "switch.2")
                Label("Keep USB and board power connected throughout the write.", systemImage: "powerplug")
                Label("If configuration fails, return to SRAM programming with a recovery-safe LED design.", systemImage: "arrow.counterclockwise")
            }.font(.callout)
            Toggle("I verified the board, switch position, and power connection.", isOn: $understood)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Write Flash") { workspace.confirmFlash() }.buttonStyle(.borderedProminent).tint(.orange).disabled(!understood)
            }
        }.padding(26).frame(width: 570)
    }
}

private struct SimulationTrustView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Trust This Project?").font(.title2.bold())
                    Text("Simulation executes project-supplied HDL on this Mac.").foregroundStyle(.secondary)
                }
            }
            Text("HDL testbenches, simulator extensions, and imported build files can read or write files using your account. Only simulate projects from people you trust, and review changes before running them.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Trust and Simulate") { workspace.trustProjectAndSimulate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 540)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    var body: some View {
        TabView {
            Form {
                Section("Managed Toolchain") {
                    ForEach(workspace.toolHealth) { tool in
                        HStack {
                            Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(tool.isAvailable ? .green : .orange)
                            VStack(alignment: .leading) {
                                Text(tool.name)
                                Text(tool.resolvedURL?.path ?? "Not installed").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(tool.expectedVersion).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Button("Check Again") { workspace.refreshToolchain() }
                    Button("Install Toolchain Archive…") { workspace.chooseToolchainArchive() }
                }
            }.padding(20).tabItem { Label("Toolchain", systemImage: "shippingbox") }
            Form {
                Section("Cyclone V GX") {
                    Text(workspace.board.experimentalNotice)
                    Link("Open-source backend documentation", destination: URL(string: "https://github.com/YosysHQ/nextpnr")!)
                }
            }.padding(20).tabItem { Label("Hardware", systemImage: "cpu") }
        }
    }
}
