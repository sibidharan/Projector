//
//  ProjectionWindowController.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//
//  Manages a borderless fullscreen window on the external display.
//
//  Uses AVCaptureVideoPreviewLayer for native-quality rendering.
//  This is Apple's own optimized path — zero-copy GPU texture sharing,
//  VSync-aligned presentation, hardware scaling.
//
//  Mission Control / Stage Manager recovery:
//  ─────────────────────────────────────────
//  macOS Tahoe's Mission Control can trigger [_MTLDevice _purgeDevice] which
//  corrupts the preview layer's GPU textures. The layer goes black but its
//  connection still reports "active" — so we can't detect it via connection state.
//
//  Recovery strategy: SIMPLE and SAFE.
//  - On space change or becoming visible: wait for animations to finish, then
//    do a SINGLE rebuild by detaching and reattaching the session on the same layer.
//  - No new views, no contentView swaps, no complex state machines.
//  - Just: previewLayer.session = nil → delay → previewLayer.session = session
//  - This forces AVFoundation to recreate its internal GPU pipeline cleanly.
//  - A single Task handles recovery — if another space change fires while
//    we're waiting, the guard prevents re-entry.
//

import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class ProjectionWindowController {

    private var window: NSWindow?
    private var contentView: PreviewBackedView?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var mouseEventMonitor: Any?
    private var pendingMouseConstrain = false

    // Health check timer — catches session disconnects
    private var healthTimer: Timer?

    // Keep reference for reconfiguration
    private weak var activeCameraManager: CameraManager?

    // Display state
    private var previousMirrorMaster: CGDirectDisplayID?
    private var wasMirroring = false
    private var takenOverDisplayID: CGDirectDisplayID = 0
    private var isProjectionActive = false

    // Recovery state — prevents overlapping recoveries
    private var isRecovering = false

    // MARK: - Projection Control

    func startProjection(displayID: CGDirectDisplayID, cameraManager: CameraManager) {
        stopProjection(cameraManager: cameraManager)

        self.activeCameraManager = cameraManager
        takeOverDisplay(displayID)

        guard let updatedScreen = screenForDisplay(displayID) else {
            print("[Window] Display \(displayID) no longer available after reconfiguration")
            restoreDisplayState()
            return
        }

        createProjectionWindow(on: updatedScreen, cameraManager: cameraManager)

        self.isProjectionActive = true
        observeScreenDisconnect(cameraManager: cameraManager)
        observeSpaceAndVisibility()
        startMouseConfinement()
        startHealthCheck()

        print("[Window] Projection started on display \(displayID) using AVCaptureVideoPreviewLayer")
    }

    func stopProjection(cameraManager: CameraManager? = nil) {
        isProjectionActive = false
        isRecovering = false
        stopHealthCheck()
        stopMouseConfinement()
        removeObservers()

        activeCameraManager = nil

        contentView?.previewLayer.session = nil
        contentView = nil
        window?.close()
        window = nil

        restoreDisplayState()
    }

    // MARK: - Window Creation

    private func createProjectionWindow(on screen: NSScreen, cameraManager: CameraManager) {
        // Clean up old
        contentView?.previewLayer.session = nil
        contentView = nil
        window?.close()
        window = nil

        let frame = screen.frame

        let projectionWindow = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        projectionWindow.level = .statusBar + 1
        projectionWindow.isOpaque = true
        projectionWindow.hasShadow = false
        projectionWindow.backgroundColor = .black
        projectionWindow.alphaValue = 1.0
        projectionWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        projectionWindow.isReleasedWhenClosed = false
        projectionWindow.ignoresMouseEvents = true
        projectionWindow.hidesOnDeactivate = false
        projectionWindow.canHide = false
        projectionWindow.isMovable = false
        projectionWindow.animationBehavior = .none

        self.window = projectionWindow

        // Build and attach the preview layer
        let view = PreviewBackedView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]

        let preview = view.previewLayer
        preview.session = cameraManager.captureSession
        preview.videoGravity = .resizeAspect

        if let connection = preview.connection {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        projectionWindow.contentView = view
        self.contentView = view

        projectionWindow.setFrame(frame, display: true)
        projectionWindow.orderFrontRegardless()

        print("[Window] PreviewLayer attached, connection active: \(preview.connection?.isActive ?? false)")
    }

    // MARK: - Preview Layer Recovery

    /// Rebuild the preview layer by detaching and reattaching the session.
    /// This forces AVFoundation to recreate its internal GPU pipeline.
    ///
    /// This is the ONLY recovery mechanism. It's simple and safe:
    /// - No new views or contentView swaps (those cause black frame flashes)
    /// - Just nil the session, wait a beat, reassign it
    /// - AVFoundation handles the rest internally
    func rebuildPreviewLayer() {
        guard isProjectionActive, !isRecovering else { return }
        guard let preview = contentView?.previewLayer,
              let camera = activeCameraManager else { return }

        isRecovering = true
        let session = camera.captureSession

        print("[Window] Recovering preview layer (session detach/reattach)")

        // Detach session from preview layer
        preview.session = nil

        // Brief delay to let AVFoundation release GPU resources
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, self.isProjectionActive else {
                self?.isRecovering = false
                return
            }

            // Reattach session — AVFoundation creates fresh GPU pipeline
            preview.session = session

            // Reconfigure connection
            if let connection = preview.connection {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }

            self.window?.orderFrontRegardless()
            self.isRecovering = false
            print("[Window] Preview layer recovered, connection active: \(preview.connection?.isActive ?? false)")
        }
    }

    // MARK: - Health Check

    /// Periodically verify the preview layer's connection is alive.
    /// If session or connection is lost, trigger recovery.
    private func startHealthCheck() {
        stopHealthCheck()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkHealth()
            }
        }
    }

    private func stopHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func checkHealth() {
        guard isProjectionActive, !isRecovering else { return }
        guard let preview = contentView?.previewLayer else {
            print("[Window] Health: no preview layer")
            return
        }

        // Check session
        guard preview.session != nil else {
            print("[Window] Health: session nil, recovering")
            rebuildPreviewLayer()
            return
        }

        // Check connection
        if let connection = preview.connection {
            if !connection.isActive || !connection.isEnabled {
                print("[Window] Health: connection inactive/disabled, recovering")
                rebuildPreviewLayer()
                return
            }
        } else {
            print("[Window] Health: no connection, recovering")
            rebuildPreviewLayer()
            return
        }
    }

    // MARK: - Space / Mission Control / Stage Manager Observation

    /// Single observer for space changes and visibility.
    /// Recovery is simple: wait for the animation storm to finish, then rebuild once.
    private func observeSpaceAndVisibility() {
        // Space change — Mission Control, Stage Manager, desktop swipe
        spaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isProjectionActive else { return }
                print("[Window] Space change detected")

                // Bring window back to front immediately
                self.window?.orderFrontRegardless()

                // Wait for Mission Control animations to fully finish.
                // macOS Tahoe plays particle effects over ~3-5 seconds.
                // We wait 6 seconds to be safe, then rebuild ONCE.
                try? await Task.sleep(for: .seconds(6))
                guard self.isProjectionActive else { return }
                self.window?.orderFrontRegardless()
                self.rebuildPreviewLayer()
            }
        }

        // Occlusion — app becomes visible again
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isProjectionActive else { return }
                let isVisible = NSApp.occlusionState.contains(.visible)
                if isVisible {
                    print("[Window] App became visible")
                    self.window?.orderFrontRegardless()

                    // Wait for any lingering animations, then rebuild
                    try? await Task.sleep(for: .seconds(3))
                    guard self.isProjectionActive else { return }
                    self.rebuildPreviewLayer()
                }
            }
        }
    }

    // MARK: - Mouse Confinement

    private func startMouseConfinement() {
        stopMouseConfinement()

        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
            guard !self.pendingMouseConstrain else { return }
            self.pendingMouseConstrain = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingMouseConstrain = false
                self.constrainMouseToPrimaryDisplay()
            }
        }
    }

    private func stopMouseConfinement() {
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    private func constrainMouseToPrimaryDisplay() {
        guard isProjectionActive, takenOverDisplayID != 0 else { return }

        let mouseLocation = NSEvent.mouseLocation

        guard let projectedScreen = screenForDisplay(takenOverDisplayID) else { return }
        let projectedFrame = projectedScreen.frame

        if projectedFrame.contains(mouseLocation) {
            guard let primaryScreen = NSScreen.main else { return }
            let primaryFrame = primaryScreen.frame

            var warpX = mouseLocation.x
            var warpY = mouseLocation.y

            warpX = max(primaryFrame.minX, min(primaryFrame.maxX - 1, warpX))
            warpY = max(primaryFrame.minY, min(primaryFrame.maxY - 1, warpY))

            let screenHeight = primaryFrame.height + primaryFrame.origin.y
            let cgPoint = CGPoint(x: warpX, y: screenHeight - warpY)

            CGWarpMouseCursorPosition(cgPoint)
        }
    }

    // MARK: - Display Takeover (Mirroring)

    private func takeOverDisplay(_ displayID: CGDirectDisplayID) {
        takenOverDisplayID = displayID

        if CGDisplayIsInMirrorSet(displayID) != 0 {
            wasMirroring = true
            let primaryOfMirrorSet = CGDisplayPrimaryDisplay(displayID)
            if primaryOfMirrorSet != displayID {
                previousMirrorMaster = primaryOfMirrorSet
            } else {
                previousMirrorMaster = CGMainDisplayID()
            }

            var config: CGDisplayConfigRef?
            let beginErr = CGBeginDisplayConfiguration(&config)
            if beginErr == .success, let config {
                CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
                if completeErr != .success {
                    print("Failed to stop mirroring: \(completeErr)")
                    CGCancelDisplayConfiguration(config)
                }
            }

            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } else {
            wasMirroring = false
            previousMirrorMaster = nil
        }
    }

    private func restoreDisplayState() {
        guard takenOverDisplayID != 0 else { return }

        if wasMirroring, let master = previousMirrorMaster {
            var config: CGDisplayConfigRef?
            let beginErr = CGBeginDisplayConfiguration(&config)
            if beginErr == .success, let config {
                CGConfigureDisplayMirrorOfDisplay(config, takenOverDisplayID, master)
                let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
                if completeErr != .success {
                    print("Failed to restore mirroring: \(completeErr)")
                    CGCancelDisplayConfiguration(config)
                }
            }
        }

        wasMirroring = false
        previousMirrorMaster = nil
        takenOverDisplayID = 0
    }

    // MARK: - Helpers

    private func screenForDisplay(_ displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    private func removeObservers() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        if let observer = spaceObserver {
            NotificationCenter.default.removeObserver(observer)
            spaceObserver = nil
        }
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
    }

    // MARK: - Screen Disconnect Handling

    private func observeScreenDisconnect(cameraManager: CameraManager) {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak cameraManager] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.takenOverDisplayID != 0 {
                    let stillConnected = NSScreen.screens.contains(where: { $0.displayID == self.takenOverDisplayID })
                    if !stillConnected {
                        self.stopProjection(cameraManager: cameraManager)
                    }
                }
            }
        }
    }
}

// MARK: - NSView backed by AVCaptureVideoPreviewLayer

/// An NSView whose backing layer IS an AVCaptureVideoPreviewLayer.
/// This gives AVFoundation direct control over the layer's rendering pipeline.
private class PreviewBackedView: NSView {

    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer.isOpaque = true
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.drawsAsynchronously = true
        previewLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "sublayers": NSNull()
        ]
        return previewLayer
    }

    override var wantsUpdateLayer: Bool { true }
}
