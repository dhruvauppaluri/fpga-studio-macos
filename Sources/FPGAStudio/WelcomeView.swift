import AppKit
import FPGAStudioCore
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var workspace: WorkspaceController

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.07)], startPoint: .top, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.blue.gradient)
                            .frame(width: 72, height: 72)
                        Image(systemName: "cpu")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FPGA Studio")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Design, simulate, build, and program Cyclone V projects—natively on your Mac.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button("New Project") { workspace.showingNewProject = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        Button("Open Folder…") { workspace.chooseProject() }
                            .controlSize(.large)
                    }
                    Spacer()
                    StatusPill(icon: "shippingbox", label: toolSummary, color: workspace.toolHealth.allSatisfy(\.isAvailable) ? .green : .orange)
                }
                .padding(52)
                .frame(maxWidth: 560, alignment: .leading)

                Divider().padding(.vertical, 44)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Recent Projects")
                        .font(.headline)
                    if workspace.recentProjects.isEmpty {
                        ContentUnavailableView("No Recent Projects", systemImage: "clock", description: Text("Projects you open will appear here."))
                    } else {
                        ForEach(workspace.recentProjects, id: \.path) { url in
                            Button { workspace.openProject(at: url) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent).fontWeight(.medium)
                                        Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(10)
                            }
                            .buttonStyle(.plain)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    Spacer()
                    Text("Cyclone V support uses the experimental open-source Mistral backend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(44)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.regularMaterial)
        }
        .sheet(isPresented: $workspace.showingNewProject) { NewProjectSheet() }
        .alert("FPGA Studio", isPresented: errorBinding) { Button("OK") { workspace.lastError = nil } } message: { Text(workspace.lastError ?? "") }
    }

    private var toolSummary: String {
        guard !workspace.toolHealth.isEmpty else { return "Checking toolchain…" }
        let available = workspace.toolHealth.filter(\.isAvailable).count
        return "Toolchain: \(available) of \(workspace.toolHealth.count) tools ready"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { workspace.lastError != nil }, set: { if !$0 { workspace.lastError = nil } })
    }
}

struct StatusPill: View {
    let icon: String
    let label: String
    let color: Color
    var body: some View {
        Label(label, systemImage: icon)
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject private var workspace: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My FPGA Project"
    @State private var template: ProjectTemplate = .rv32i
    @State private var language: HDLLanguage = .systemVerilog
    @State private var parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a New Project").font(.title2.bold())
                    Text("A portable folder that works with Git and other editors.").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "folder.badge.plus").font(.system(size: 32)).foregroundStyle(.blue)
            }
            TextField("Project Name", text: $name).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                ForEach(ProjectTemplate.allCases) { item in
                    Button { template = item } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: item == .rv32i ? "cpu" : item == .blinky ? "lightbulb" : "doc")
                                .font(.title2).foregroundStyle(template == item ? .white : .blue)
                            Text(item.displayName).fontWeight(.semibold)
                            Text(item.summary).font(.caption).foregroundStyle(template == item ? .white.opacity(0.85) : .secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .padding(14)
                        .background(template == item ? Color.blue : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
            Picker("Language", selection: $language) {
                ForEach(HDLLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(template == .rv32i)
            HStack {
                Text(parent.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Choose Location…") { chooseParent() }
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { workspace.createProject(template: template, language: template == .rv32i ? .systemVerilog : language, name: name, parent: parent) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 720)
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }
}
