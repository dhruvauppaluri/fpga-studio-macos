import AppKit
import XCTest
@testable import FPGAStudio

@MainActor
private final class EditorBuffer {
    var text: String
    init(_ text: String) { self.text = text }
}

@MainActor
final class CodeEditorTests: XCTestCase {
    func testTrailingNewlineGetsAnImmediateExtraLineFragment() {
        let editor = CodeEditorContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        editor.layoutSubtreeIfNeeded()
        editor.textView.string = "module top;\n"
        editor.gutterView.rebuildIndex(for: editor.textView.string)
        editor.layoutSubtreeIfNeeded()

        XCTAssertEqual(editor.gutterView.lineIndex.lineCount, 2)
        let finalLine = editor.gutterView.lineFragmentRect(forLineNumber: 2)
        XCTAssertNotNil(finalLine)
        XCTAssertEqual(finalLine, editor.textView.layoutManager?.extraLineFragmentRect)
    }

    func testEditorPreservesWrappedNativeTextKitLayout() {
        let editor = CodeEditorContainerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        editor.layoutSubtreeIfNeeded()

        XCTAssertFalse(editor.scrollView.hasHorizontalScroller)
        XCTAssertFalse(editor.textView.isHorizontallyResizable)
        XCTAssertTrue(editor.textView.textContainer?.widthTracksTextView == true)
    }

    func testEditorRendersInLightAndDarkAppearances() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let editor = CodeEditorContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            editor.appearance = NSAppearance(named: appearanceName)
            editor.textView.string = "module top;\nendmodule\n"
            editor.gutterView.rebuildIndex(for: editor.textView.string)
            editor.layoutSubtreeIfNeeded()
            editor.displayIfNeeded()

            let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds)
            XCTAssertNotNil(bitmap, "Editor should render in \(appearanceName.rawValue)")
            if let bitmap {
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            }
        }
    }

    func testSixDigitLineCountWidensTheGutter() {
        let editor = CodeEditorContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let originalWidth = editor.gutterView.preferredWidth
        let text = String(repeating: "x\n", count: 100_000)
        editor.gutterView.rebuildIndex(for: text)

        XCTAssertEqual(editor.gutterView.lineIndex.lineCount, 100_001)
        XCTAssertGreaterThan(editor.gutterView.preferredWidth, originalWidth)
    }

    func testClearingSearchRemovesPreviousHighlightBackgrounds() {
        let editor = CodeEditor(
            documentID: "top.sv",
            text: "module top; endmodule",
            language: .systemVerilog,
            searchText: "module",
            didEdit: { _ in },
            registerBuffer: { _, _ in },
            unregisterBuffer: { _ in }
        )
        let coordinator = CodeEditor.Coordinator(editor)
        let container = CodeEditorContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        container.textView.string = editor.text
        coordinator.attach(textView: container.textView, containerView: container)
        coordinator.updateSearch(in: container.textView)

        XCTAssertNotNil(container.textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        coordinator.parent.searchText = ""
        coordinator.updateSearch(in: container.textView)
        XCTAssertNil(container.textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        coordinator.detach()
    }

    func testAutosaveCoalescesEditsAndWritesAfterIdleDelay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("top.sv")
        try Data("original".utf8).write(to: url)

        let workspace = WorkspaceController()
        workspace.documents = [.init(id: "top.sv", url: url, language: .systemVerilog, text: "original")]
        workspace.selectedDocumentID = "top.sv"
        let buffer = EditorBuffer("first")
        workspace.registerEditorBuffer(documentID: "top.sv") { buffer.text }
        workspace.editorDidChange(documentID: "top.sv")
        XCTAssertTrue(workspace.documents[0].isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")

        try await Task.sleep(for: .milliseconds(100))
        buffer.text = "second"
        workspace.editorDidChange(documentID: "top.sv")
        try await Task.sleep(for: .milliseconds(450))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second")
        XCTAssertFalse(workspace.documents[0].isDirty)
    }

    func testExplicitFlushCapturesTheLiveEditorBeforeAWorkflowBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("top.sv")
        try Data("old".utf8).write(to: url)

        let workspace = WorkspaceController()
        workspace.documents = [.init(id: "top.sv", url: url, language: .systemVerilog, text: "old")]
        workspace.selectedDocumentID = "top.sv"
        let buffer = EditorBuffer("latest")
        workspace.registerEditorBuffer(documentID: "top.sv") { buffer.text }
        workspace.editorDidChange(documentID: "top.sv")

        let firstFlush = await workspace.flushPendingEdits()
        XCTAssertTrue(firstFlush)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "latest")
        XCTAssertEqual(workspace.documents[0].text, "latest")
        XCTAssertFalse(workspace.documents[0].isDirty)

        buffer.text = "newer"
        workspace.editorDidChange(documentID: "top.sv")
        let secondFlush = await workspace.flushPendingEdits()
        XCTAssertTrue(secondFlush)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "newer")
    }

    func testSaveFailureKeepsDocumentDirtyAndReportsTheFile() async {
        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-missing-\(UUID().uuidString)")
        let url = missingRoot.appendingPathComponent("top.sv")
        let workspace = WorkspaceController()
        workspace.documents = [.init(id: "top.sv", url: url, language: .systemVerilog, text: "old")]
        workspace.selectedDocumentID = "top.sv"
        workspace.registerEditorBuffer(documentID: "top.sv") { "latest" }
        workspace.editorDidChange(documentID: "top.sv")

        let flushed = await workspace.flushPendingEdits()
        XCTAssertFalse(flushed)
        XCTAssertTrue(workspace.documents[0].isDirty)
        XCTAssertTrue(workspace.lastError?.contains("top.sv") == true)
    }
}
