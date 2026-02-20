//
//  DisplayManager.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//

import AppKit
import Combine

@MainActor
final class DisplayManager: ObservableObject {

    @Published var availableDisplays: [ExternalDisplay] = []
    @Published var selectedDisplay: ExternalDisplay?
    @Published var isProjecting = false

    // Display mode selection
    @Published var availableModes: [DisplayMode] = []
    @Published var currentMode: DisplayMode?

    private var screenObserver: NSObjectProtocol?

    init() {
        refreshDisplayList()
        observeDisplayChanges()
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Display Enumeration

    func refreshDisplayList() {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)

        var externals: [ExternalDisplay] = []

        for i in 0..<Int(displayCount) {
            let displayID = onlineDisplays[i]
            if CGDisplayIsBuiltin(displayID) != 0 { continue }

            let isMirroring = CGDisplayIsInMirrorSet(displayID) != 0
            let screen = NSScreen.screens.first { $0.displayID == displayID }

            let name: String
            if let screen {
                name = screen.localizedName
            } else {
                name = "External Display \(displayID)"
            }

            externals.append(ExternalDisplay(
                displayID: displayID,
                name: name,
                screen: screen,
                isMirroring: isMirroring
            ))
        }

        availableDisplays = externals

        if let selected = selectedDisplay,
           !availableDisplays.contains(where: { $0.displayID == selected.displayID }) {
            selectedDisplay = nil
        }

        if selectedDisplay == nil {
            selectedDisplay = availableDisplays.first
        }

        // Refresh modes for the selected display
        refreshModes()
    }

    // MARK: - Display Mode Management

    func refreshModes() {
        guard let display = selectedDisplay else {
            availableModes = []
            currentMode = nil
            return
        }

        let displayID = display.displayID

        // Get current mode
        if let cgMode = CGDisplayCopyDisplayMode(displayID) {
            currentMode = DisplayMode(from: cgMode, displayID: displayID)
        }

        // Get all available modes
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            availableModes = []
            return
        }

        // Convert and deduplicate: unique (width, height, refreshRate) combos
        var seen = Set<String>()
        var modes: [DisplayMode] = []

        for cgMode in cgModes {
            guard cgMode.isUsableForDesktopGUI() else { continue }
            let mode = DisplayMode(from: cgMode, displayID: displayID)
            let key = "\(mode.width)x\(mode.height)@\(Int(mode.refreshRate))"
            if seen.insert(key).inserted {
                modes.append(mode)
            }
        }

        // Sort: highest resolution first, then highest refresh rate
        modes.sort { a, b in
            let pixelsA = a.width * a.height
            let pixelsB = b.width * b.height
            if pixelsA != pixelsB { return pixelsA > pixelsB }
            return a.refreshRate > b.refreshRate
        }

        availableModes = modes
    }

    func applyMode(_ mode: DisplayMode) {
        let displayID = mode.displayID

        // Find the matching CGDisplayMode
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }

        let target = cgModes.first { cgMode in
            cgMode.width == mode.width
            && cgMode.height == mode.height
            && Int(cgMode.refreshRate) == Int(mode.refreshRate)
        }

        guard let targetMode = target else { return }

        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let config else { return }

        CGConfigureDisplayWithDisplayMode(config, displayID, targetMode, nil)

        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        if completeErr != .success {
            CGCancelDisplayConfiguration(config)
        } else {
            // Refresh after applying
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshModes()
                self?.refreshDisplayList()
            }
        }
    }

    // MARK: - Display Observation

    private func observeDisplayChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDisplayList()
            }
        }
    }
}

// MARK: - Display Mode Model

struct DisplayMode: Identifiable, Hashable {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let refreshRate: Double

    var id: String { "\(displayID)-\(width)x\(height)@\(Int(refreshRate))" }

    var label: String {
        "\(width)x\(height) @ \(Int(refreshRate)) Hz"
    }

    init(from cgMode: CGDisplayMode, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.width = cgMode.width
        self.height = cgMode.height
        self.refreshRate = cgMode.refreshRate
    }
}

// MARK: - External Display Model

struct ExternalDisplay: Identifiable, Hashable {
    let displayID: CGDirectDisplayID
    let name: String
    let screen: NSScreen?
    let isMirroring: Bool

    var id: CGDirectDisplayID { displayID }

    var resolutionWidth: Int { Int(CGDisplayPixelsWide(displayID)) }
    var resolutionHeight: Int { Int(CGDisplayPixelsHigh(displayID)) }
    var resolutionString: String { "\(resolutionWidth)x\(resolutionHeight)" }

    var refreshRate: Double {
        CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
    }

    static func == (lhs: ExternalDisplay, rhs: ExternalDisplay) -> Bool {
        lhs.displayID == rhs.displayID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(displayID)
    }
}

// MARK: - NSScreen Helpers

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

}
