import Combine
import PaletteKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct PaletteEditorView: View {

    @Bindable var palette: Palette

    @State private var exportError: String?
    @State private var showingDiscardConfirmation = false

    @State private var generator = PaletteGenerator()
    @State private var paletteText = ""
    /// A phone's inspector is a sheet, raised in `.task` once the push has landed; elsewhere it's a column, there from the start.
    @State private var showingInspector = !Self.isPhone
    /// Where the inspector's sheet starts, in window coordinates, or `nil` while it's a column or not on screen.
    @State private var sheetTop: CGFloat?
    /// Where the display's safe area ends, in the same coordinates, so the sheet's overlap can be measured.
    @State private var displayBottom: CGFloat = 0

    /// How much of the display the sheet covers. Measured edge to edge rather than taken from the
    /// sheet's height, which also counts the home indicator inset the display already avoids.
    private var sheetOverlap: CGFloat {
        guard horizontalSizeClass == .compact, let sheetTop else { return 0 }
        return max(0, displayBottom - sheetTop)
    }
    /// Held here rather than in `DisplayView` so the menu bar's commands can reach them.
    @State private var displayMode: DisplayView.DisplayMode = .sphere
    @State private var showingAddColor = false
    @State private var selectedDetent: PresentationDetent = .medium

    /// The state the last undo step ended at — where the next one starts from.
    @State private var committedState: Palette.EditState?
    /// While the text editor is focused, edits accumulate into one undo step, registered on commit.
    @State private var isEditingText = false
    /// Mirrors the undo manager, which isn't observable, for the Undo/Redo buttons.
    @State private var canUndo = false
    @State private var canRedo = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    #if canImport(UIKit)
    private static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    #else
    private static let isPhone = false
    #endif

    /// The inspector is no longer gated on the parameters: a palette that can't be regenerated still has
    /// an analysis to show there.
    private var inspectorPresented: Binding<Bool> {
        Binding(get: { showingInspector }, set: { showingInspector = $0 })
    }

    private var inspector: some View {
        PaletteInspectorView(generator: generator,
                             colors: palette.colors,
                             canEditParameters: palette.canEditParameters)
    }

    private var display: some View {
        DisplayView(
            generator: generator,
            paletteColors: $palette.colors,
            paletteText: $paletteText,
            displayMode: $displayMode,
            showingAddColor: $showingAddColor,
            onManualEdit: palette.markCustomized,
            onTextEditingChanged: { isEditingText = $0 })
    }

    var body: some View {
        editor
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle($palette.name)
            #if !os(visionOS)
            // visionOS has no navigation subtitle; the count is carried by the grid there instead.
            .navigationSubtitle("^[\(palette.colors.count) Colors](inflect: true)")
            #endif
            .toolbar {
                #if os(visionOS)
                ToolbarItem {
                    Button("Open in Volume", systemImage: "cube.transparent") {
                        openWindow(id: "display", value: palette.persistentModelID)
                    }
                }
                #endif
                #if os(iOS) || os(macOS)
                if #available(iOS 27, macOS 26.1, *) {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Export", systemImage: "square.and.arrow.up") {
                            exportMenu
                        }
                    }
                    // Export is the primary action here; keep it in the bar while other items overflow first.
                    .visibilityPriority(.high)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Export", systemImage: "square.and.arrow.up") {
                            exportMenu
                        }
                    }
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        exportMenu
                    }
                }
                #endif

                #if !os(macOS)
                // macOS has Edit ▸ Undo; elsewhere a keyboard or a shake isn't always at hand.
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                        .disabled(!canUndo)
                    Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                        .disabled(!canRedo)
                }
                #endif

                // Only a customized perfect palette can be reverted to its generated colors.
                if palette.parameters != nil && palette.isCustomized {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Discard Manual Edits", systemImage: "arrow.counterclockwise") {
                            showingDiscardConfirmation = true
                        }
                        .confirmationDialog("Discard Manual Edits?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                            Button("Discard & Regenerate", role: .destructive, action: discardManualEdits)
                        } message: {
                            Text("This regenerates the palette from its parameters, discarding your color edits and names.")
                        }
                    }
                }
            }
            .alert("Export Failed", item: $exportError) { _ in
                Button("OK") { }
            } message: { message in
                Text(message)
            }
            .onChange(of: generator.parameters) { _, parameters in
                regenerate(parameters)
            }
            .onChange(of: palette.parameters) { _, parameters in
                // An undo can restore older parameters; the generator follows, finding nothing to regenerate.
                if let parameters, parameters != generator.parameters {
                    generator.parameters = parameters
                }
            }
            .onChange(of: palette.editState) {
                if !isEditingText { commitUndoStep() }
            }
            .onChange(of: isEditingText) { _, isEditing in
                if !isEditing { commitUndoStep() }
            }
            .onReceive(undoStackChanges) { _ in
                canUndo = undoManager?.canUndo ?? false
                canRedo = undoManager?.canRedo ?? false
            }
            .focusedSceneValue(\.paletteEditor, focus)
            .onAppear(perform: load)
            .task {
                // A sheet presented while the push is still animating is silently dropped, leaving
                // `showingInspector` true with nothing on screen and no button to bring it back.
                guard !showingInspector else { return }
                try? await Task.sleep(for: .milliseconds(500))
                showingInspector = true
            }
            .onDisappear {
                // Steps outlive the editor on the window's undo manager, where one could land on a
                // palette since deleted from the list.
                undoManager?.removeAllActions(withTarget: palette)
            }
    }

    /// What the menu bar's editor commands act on, while this editor is frontmost in its window.
    private var focus: PaletteEditorFocus {
        #if os(macOS)
        PaletteEditorFocus(palette: palette, colorSpace: generator.parameters.colorSpace,
                           displayMode: $displayMode, showingAddColor: $showingAddColor,
                           exportColorList: exportColorList)
        #else
        PaletteEditorFocus(palette: palette, colorSpace: generator.parameters.colorSpace,
                           displayMode: $displayMode, showingAddColor: $showingAddColor)
        #endif
    }

    private var undoStackChanges: some Publisher<Notification, Never> {
        let center = NotificationCenter.default
        return Publishers.Merge3(
            center.publisher(for: .NSUndoManagerDidCloseUndoGroup, object: undoManager),
            center.publisher(for: .NSUndoManagerDidUndoChange, object: undoManager),
            center.publisher(for: .NSUndoManagerDidRedoChange, object: undoManager))
    }

    private var exportMenu: some View {
        #if os(macOS)
        PaletteExportMenu(palette: palette, colorSpace: generator.parameters.colorSpace, exportColorList: exportColorList)
        #else
        PaletteExportMenu(palette: palette, colorSpace: generator.parameters.colorSpace)
        #endif
    }

    #if os(macOS)
    private func exportColorList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = palette.name
        if let clr = UTType(filenameExtension: "clr") {
            panel.allowedContentTypes = [clr]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try palette.snapshot().writeCLR(to: url, colorSpace: generator.parameters.colorSpace)
        } catch {
            exportError = error.localizedDescription
        }
    }
    #endif

    /// iOS and visionOS forms inset their rows and size their steppers well past the Mac's, so the
    /// parameters need a wider panel there to keep each label and value on one line.
    #if os(macOS)
    private static let inspectorWidth: CGFloat = 360
    #else
    private static let inspectorWidth: CGFloat = 420
    #endif

    @ViewBuilder
    private var editor: some View {
        #if os(visionOS)
        // visionOS has no `.inspector`; place the parameters alongside the display instead.
        HStack(spacing: 0) {
            display
            inspector
                .frame(width: Self.inspectorWidth)
        }
        #else
        display
            // Keep the display clear of the sheet, so the sphere centers in what's left visible.
            .safeAreaPadding(.bottom, sheetOverlap)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { displayBottom = $0 }
            .inspector(isPresented: inspectorPresented) {
                inspector
                    // A sheet's grabber floats over its content; keep the header's picker clear of it.
                    .safeAreaPadding(.top, horizontalSizeClass == .compact ? 12 : 0)
                    .presentationDetents([.height(64), .medium, .large], selection: $selectedDetent)
                    .presentationBackgroundInteraction(.enabled)
                    .interactiveDismissDisabled(Self.isPhone)
                    .inspectorColumnWidth(min: Self.inspectorWidth, ideal: Self.inspectorWidth)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .global).minY - $0.safeAreaInsets.top
                    } action: { sheetTop = $0 }
                    .onDisappear { sheetTop = nil }
            }
            .toolbar {
                // Ungated: closing the inspector on a palette with no parameters would otherwise strand it.
                if !showingInspector {
                    ToolbarItem {
                        Button("Inspector", systemImage: "sidebar.trailing") {
                            showingInspector = true
                        }
                    }
                }
            }
        #endif
    }

    private func load() {
        if let parameters = palette.parameters {
            generator.parameters = parameters
        }
        // Parameters are why you opened the editor; the analysis isn't, so it starts as a sliver.
        selectedDetent = palette.canEditParameters ? .medium : .height(64)
        paletteText = PaletteColor.cssText(palette.colors, colorSpace: generator.parameters.colorSpace, convertedToP3: false)
        committedState = palette.editState
    }

    /// Records everything since the last step — one color edit, one parameter change, or a whole
    /// typing session — as a single undo step. Observing the palette, rather than wrapping each
    /// mutation, catches every edit path in `DisplayView` along with the `isCustomized` it sets.
    private func commitUndoStep() {
        let current = palette.editState
        if let committedState, let undoManager {
            palette.registerUndo(from: committedState, with: undoManager) { restored in
                self.committedState = restored
            }
        }
        committedState = current
    }

    private func regenerate(_ parameters: PaletteGenerator.Parameters) {
        guard palette.canEditParameters else { return }

        let colors = generator.generate()
        paletteText = PaletteColor.cssText(colors, colorSpace: parameters.colorSpace, convertedToP3: false)

        // Skip no-op writes (e.g. seeding the generator on appear) so the modified date doesn't churn.
        guard palette.parameters != parameters || palette.colors != colors else { return }
        palette.parameters = parameters
        palette.colors = colors
        palette.dateModified = .now
    }

    private func discardManualEdits() {
        palette.discardManualEdits()
        paletteText = PaletteColor.cssText(palette.colors, colorSpace: palette.colorSpace, convertedToP3: false)
    }
}
