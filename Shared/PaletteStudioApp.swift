import OSLog
import PaletteKit
import SwiftUI
import SwiftData

@main
struct PaletteStudioApp: App {

    /// A single shared container so every window (including the visionOS volume) reads the same store.
    private let container: ModelContainer

    /// Set when the library couldn't be opened and the app is running on an empty in-memory store instead.
    @State private var libraryLoadFailed: Bool
    @State private var showingEvent = false

    /// Named so the menu bar's New Window can open it after ⌘N was given to New Perfect Palette.
    static let mainWindowID = "main"

    init() {
        // A screenshot run gets a throwaway seeded store; every other launch keeps the real library.
        if ScreenshotMode.isActive {
            container = Self.inMemoryContainer()
            ScreenshotMode.seed(container.mainContext)
            _libraryLoadFailed = State(initialValue: false)
            return
        }
        // As a unit-test host the app must not open the CloudKit store: its mirroring races the tests'
        // own containers and crashes the host on macOS. (UI tests launch a separate process without this.)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            container = Self.inMemoryContainer()
            _libraryLoadFailed = State(initialValue: false)
            return
        }
        do {
            // Synced through the app's iCloud container, so a palette made on one device reaches the others.
            container = try ModelContainer(for: Palette.self,
                                           configurations: ModelConfiguration(cloudKitDatabase: .automatic))
            _libraryLoadFailed = State(initialValue: false)
        } catch {
            // Crashing here would crash every launch. The store file is left untouched so it can be
            // recovered by a later build; this session just works on a scratch library.
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Palette Studio", category: "Library")
                .fault("Couldn't open the palette library: \(error, privacy: .public)")
            container = Self.inMemoryContainer()
            _libraryLoadFailed = State(initialValue: true)
        }
    }

    private static func inMemoryContainer() -> ModelContainer {
        // An in-memory store with no CloudKit has nothing on disk to fail on.
        try! ModelContainer(for: Palette.self,
                            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            MainView()
                .alert("Event Intro", isPresented: $showingEvent) {
                    Button("OK", role: .close) { }
                } message: {
                    Text("Now let's celebrate by designing a color palette in the style using the new features!")
                }
                .alert("Couldn't Load Your Palettes", isPresented: $libraryLoadFailed) {
                    Button("OK", role: .close) { }
                } message: {
                    Text("Your saved palettes weren't deleted, but they couldn't be opened right now. Anything you make before relaunching won't be saved. Don't delete the app — check for an update instead.")
                }
                .onOpenURL { url in
                    // /palette3d/ is the slug from before the rename; published event links still use it.
                    if url.path().hasSuffix("/appstoreevent") {
                        showingEvent = true
                    }
                }
                .screenshotModeStatus()
        }
        .modelContainer(container)
        .commands {
            PaletteCommands()
        }
        // The window the app should open at: room for the sphere and its inspector side by side.
        // Screenshots deliberately photograph this same size rather than one of their own.
        #if os(macOS)
        .defaultSize(width: 880, height: 560)
        #elseif os(visionOS)
        .defaultSize(width: 1024, height: 640)
        #endif
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .help) {
                AppLinks()
            }
        }
        #endif

        #if os(visionOS)
        WindowGroup("Display", id: "display", for: PersistentIdentifier.self) { $paletteID in
            VolumetricDisplayView(paletteID: paletteID)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1, height: 1, depth: 1, in: .meters)
        .modelContainer(container)
        #endif
    }
}
