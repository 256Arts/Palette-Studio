import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// Drives the app through the screens that become App Store screenshots and attaches each one to the
/// result bundle, where `Scripts/screenshots.sh` extracts them.
///
/// One test rather than one per screen: the shots are a walk through a single launch, and splitting
/// them would pay the launch — and the reseed — every time.
@MainActor
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    /// Whether the walk turned the device on its side, which the capture has to undo.
    ///
    /// Tracked here rather than read back from `XCUIDevice.shared.orientation`, which a simulator
    /// answers as portrait however the UI is laid out.
    private var isLandscape = false

    func testCaptureAppStoreScreenshots() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-screenshotMode"]
        app.launch()

        #if os(macOS)
        // A launch stays in the background unless its launcher is frontmost, and the shot is of the
        // frontmost window. Before the window check: activating can bring up the held window, so
        // pressing ⌘N first would make a second one, tabbed with it under "Prefer tabs: Always".
        app.activate()
        openWindowIfNeeded()
        #elseif os(iOS)
        turnToRequestedOrientation()
        #endif

        checkSeedIsThrowaway()

        // The library is the landing tab, so it is ready as soon as a seeded row exists.
        let featuredRow = control("PaletteRow.Sunset Study")
        guard waitFor(featuredRow, "the seeded library", shot: "01-library", timeout: 30) else { return }
        settle()
        capture("01-library")

        activate(control("Pairs"), "Pairs tab", shot: "04-pairs")
        // Compact width makes Mix, Gradient and Stats take turns; regular width shows them all and
        // has no picker, so there is nothing to tap.
        let gradient = control("Gradient")
        if gradient.waitForExistence(timeout: 2) { press(gradient) }
        settle(seconds: 4)   // the ramps come back from an offscreen WKWebView, not from SwiftUI
        capture("04-pairs")

        activate(control("Color"), "Color tab", shot: "05-color")
        settle()
        capture("05-color")

        activate(control("Palettes"), "Palettes tab", shot: "02-editor-sphere")
        activate(control("PaletteRow.Sunset Study"), "featured palette row", shot: "02-editor-sphere")
        settle(seconds: 4)   // the sphere is RealityKit; give it frames to draw
        capture("02-editor-sphere")

        // Zughy 32's even ramps read better as swatches than the generated palette does.
        goBack(shot: "03-editor-grid")
        activate(control("PaletteRow.Zughy 32"), "Zughy 32 palette row", shot: "03-editor-grid")
        activate(control("Grid"), "Grid display mode", shot: "03-editor-grid")
        settle()
        capture("03-editor-grid")
    }

    // MARK: - The seed

    /// What the app said it seeded, read out of the accessibility tree.
    ///
    /// The app hangs `ScreenshotMode.status` on its root view (`.screenshotModeStatus()`). A walk
    /// that cannot find it is running against a build that has not adopted that modifier, which is
    /// worth saying plainly rather than reporting as an empty seed.
    private var seedStatus: String {
        let label = app.descendants(matching: .any)["ScreenshotMode.Status"]
        guard label.waitForExistence(timeout: 30) else {
            return "no ScreenshotMode.Status element — add .screenshotModeStatus() to the app's root view"
        }
        // A SwiftUI `Text` reaches XCUITest as the element's *value* on macOS and as its *label* on
        // iOS, so take whichever is filled in rather than betting on one.
        if let value = label.value as? String, !value.isEmpty { return value }
        return label.label
    }

    /// Stops the walk when the app did not seed the throwaway store.
    ///
    /// `ScreenshotMode.seed` refuses to write to a store that is on disk or still synced with
    /// CloudKit, because a screenshot run that reached the real store writes demo palettes into
    /// the user's own. The walk that followed would then photograph an empty app and fail on a
    /// missing row, which says nothing about why. Read the reason instead, before the first shot.
    private func checkSeedIsThrowaway() {
        let status = seedStatus
        print("SCREENSHOT MODE: \(status)")
        guard status.hasPrefix("ready") else {
            attach(XCTAttachment(string: app.debugDescription), named: "element-tree")
            return XCTFail("the app did not seed a throwaway store, so there is nothing to photograph — \(status)")
        }
    }

    private static var platform: String {
        #if os(macOS)
        "macOS"
        #elseif targetEnvironment(macCatalyst)
        "Mac Catalyst"
        #elseif os(visionOS)
        "visionOS"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }

    /// Which simulator this was, for a failure read days after the run's own log is gone.
    private static var device: String {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "this machine"
    }

    #if os(macOS)
    /// Opens a window when the launch came up without one.
    ///
    /// `XCUIApplication.launch()` launches a Mac app in the *background*, and AppKit gives a
    /// background launch no window — it holds it until the user arrives. The app comes up as a menu
    /// bar and nothing else, every lookup in the walk comes back empty, and the run dies on the
    /// first wait with the seed sitting in a store no window is showing. `activate()` is not what
    /// AppKit waits for: only a reopen, the event a Dock icon click sends, builds the window, and a
    /// test runner has no way to send one — so the walk asks for the window itself, with the app's
    /// own New Window.
    ///
    /// Whether a launch gets away without this depends on who started the run: LaunchServices
    /// activates a launched app only while the process that launched it is frontmost, so the same
    /// walk comes up with a window when it is run by hand from a frontmost Terminal and with
    /// nothing but a menu bar when an agent runs it in the background.
    ///
    /// Waits first rather than counting windows straight after `launch()`, which returns on idle
    /// and can beat the window into the accessibility tree — ⌘N would then open a second, empty one
    /// and the walk would photograph that.
    private func openWindowIfNeeded() {
        if app.windows.firstMatch.waitForExistence(timeout: 10) { return }
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "the app launched with no window and ⌘N opened none")
    }
    #endif

    // MARK: - Driving

    /// Tabs and toolbar segments surface as different element types per platform, so look through the
    /// types that can actually be activated rather than guessing one. visionOS can list a tab twice
    /// (the tab bar ornament and its sidebar), so the first match is taken.
    private func control(_ label: String) -> XCUIElement {
        for query in [app.buttons, app.radioButtons, app.descendants(matching: .tab)] {
            let element = query[label].firstMatch
            if element.exists { return element }
        }
        return app.buttons[label]   // nothing matched; let the caller's assertion name the miss
    }

    private func activate(_ element: XCUIElement, _ description: String, shot: String) {
        guard waitFor(element, description, shot: shot, timeout: 15) else { return }
        press(element)
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// Pops the pushed editor back to the library. The back button is the navigation bar's first
    /// button on iOS and visionOS; macOS puts it in the toolbar as "Back".
    private func goBack(shot: String) {
        #if os(macOS)
        activate(app.toolbars.buttons["Back"].firstMatch, "the editor's back button", shot: shot)
        #else
        activate(app.navigationBars.buttons.firstMatch, "the editor's back button", shot: shot)
        #endif
    }

    /// Waits for `element`, naming everything a failure needs to explain itself: the platform, the
    /// device, what it was waiting for, which shot it was heading toward, and what the seed reported
    /// — so a miss reads as more than "seeded content never appeared".
    @discardableResult
    private func waitFor(_ element: XCUIElement, _ description: String, shot: String, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            attach(XCTAttachment(string: app.debugDescription), named: "element-tree")
            XCTFail("""
                never found \(description) heading into \(shot) on \(Self.platform), \(Self.device).
                The app reported: \(seedStatus)
                The screen at the time is attached as element-tree.
                """)
            return false
        }
        return true
    }

    #if os(iOS)
    /// Turns the device the way the runner asked (`IPAD_ORIENTATION`, landscape by default on iPad).
    ///
    /// After `launch()`, not before: a rotation set before the app is up is silently dropped, and
    /// the set comes back portrait. The runner checks every shot's shape, so that fails the run.
    private func turnToRequestedOrientation() {
        guard ProcessInfo.processInfo.environment["SCREENSHOT_ORIENTATION"] == "landscape" else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        isLandscape = true
        settle()
    }
    #endif

    /// Animations and async content have no element to wait on, so the shots pause instead.
    private func settle(seconds: TimeInterval = 2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - Capturing

    private func capture(_ name: String) {
        // Every capture below photographs the whole screen, or the frontmost window — never this
        // app in particular. So an app that has lost the foreground yields another app's UI, filed
        // under this app's name, at the right size, with nothing to notice. The shared runner holds
        // a machine-wide lock so that cannot happen; this is the check that it held.
        XCTAssertEqual(app.state, .runningForeground,
                       "\(name): the app under test was not frontmost — another app has this device")
        #if os(macOS) || os(visionOS)
        // visionOS too: it has no screen for `XCUIScreen` to return (the call comes back 1x1), so
        // the script photographs the simulator instead.
        captureWindow(named: name)
        #else
        // The simulator's screen already *is* the store's canvas, at the exact required pixel size.
        attach(upright(XCUIScreen.main.screenshot()), named: name)
        #endif
    }

    /// The screenshot, turned the way the device is being held.
    ///
    /// `XCUIScreen.main.screenshot()` photographs the *physical* screen: a rotated device comes back
    /// as a portrait buffer carrying its quarter turn as metadata, which `XCTAttachment(screenshot:)`
    /// writes out content-on-its-side. Redrawing bakes the metadata into the pixels — `UIImage.size`
    /// is already the turned size and `draw(at:)` honours the orientation, so no manual rotation.
    private func upright(_ screenshot: XCUIScreenshot) -> XCTAttachment {
        #if os(iOS)
        guard isLandscape else { return XCTAttachment(screenshot: screenshot) }
        let image = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale   // keep the pixel count the store checks against
        format.opaque = true
        return XCTAttachment(image: UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        })
        #else
        XCTAttachment(screenshot: screenshot)
        #endif
    }

    private func attach(_ attachment: XCTAttachment, named name: String) {
        attachment.name = name
        attachment.lifetime = .keepAlways   // attachments on a passing test are discarded otherwise
        add(attachment)
    }

    #if os(macOS) || os(visionOS)

    /// Asks the shell running the tests to photograph the window, and waits for it.
    ///
    /// The good capture is `screencapture -l`, which reads the window's own buffer: correctly masked
    /// to the rounded corners, with real alpha and the system's own shadow. (`XCUIElement.screenshot()`
    /// crops the *screen* to the window's frame, so it loses the shadow — drawn outside that frame —
    /// and leaves desktop inside the corners.) But `screencapture` needs Screen Recording, which the
    /// test runner has no grant for and the terminal running `Scripts/screenshots.sh` does. So the
    /// test drives the UI and the script takes the picture.
    ///
    /// They meet in a plain directory under /tmp. That works only because the runner is deliberately
    /// unsandboxed (PaletteUITests/PaletteUITests.entitlements): a sandboxed runner cannot write /tmp,
    /// and its own container is unreadable to the script, so the two would have nowhere to meet.
    /// (On the visionOS simulator the same path is the host's, which is what lets `simctl` answer.)
    private static let handshakeDirectory = URL(fileURLWithPath: "/tmp/app-store-screenshots")

    private func captureWindow(named name: String) {
        let files = FileManager.default
        let handshake = Self.handshakeDirectory
        let done = handshake.appendingPathComponent("done-\(name)")
        try? files.removeItem(at: done)

        let request = handshake.appendingPathComponent("request-\(name)")
        guard files.createFile(atPath: request.path, contents: nil) else {
            return XCTFail("could not write a capture request to \(request.path)")
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if files.fileExists(atPath: done.path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("timed out waiting for the script to capture \(name) — is Scripts/screenshots.sh watching \(handshake.path)?")
    }

    #endif
}
