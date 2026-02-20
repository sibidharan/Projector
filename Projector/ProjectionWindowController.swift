//
//  ProjectionWindowController.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//
//  Manages a borderless fullscreen window on the external display.
//
//  Uses AVCaptureVideoPreviewLayer for native-quality rendering.
//  This is Apple's own optimized path — the same one used by FaceTime,
//  Photo Booth, and QuickTime. It handles:
//    - Zero-copy GPU texture sharing from the camera
//    - VSync-aligned presentation
//    - Display refresh rate matching
//    - Color space management
//    - Hardware scaling
//  No manual IOSurface handling, no Metal, no frame drops.
//
//  Recovery:
//  Two failure modes are handled:
//  1. GPU resource purge — Mission Control / Space switch triggers
//     [_MTLDevice _purgeDevice], invalidating preview layer GPU textures.
//     Detected via NSWorkspace.activeSpaceDidChangeNotification.
//  2. Silent preview layer disconnect — The session runs fine and frames
//     arrive to the heartbeat output, but the preview layer's internal
//     connection goes stale. Detected by a health-check timer that
//     inspects the preview layer's connection state every 2 seconds.
//
//  Both are fixed by rebuilding the preview layer from scratch
//  with zero blackout (new view replaces old in a single assignment).
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
    private var appActivateObserver: NSObjectProtocol?
    private var mouseEventMonitor: Any?
    private var pendingMouseConstrain = false

    // Health check timer — detects silent preview layer disconnects
    private var healthTimer: Timer?

    // Keep reference for reconfiguration
    private weak var activeCameraManager: CameraManager?

    // Display state
    private var previousMirrorMaster: CGDirectDisplayID?
    private var wasMirroring = false
    private var takenOverDisplayID: CGDirectDisplayID = 0
    private var isProjectionActive = false

    // Recovery state
    private var isRebuilding = false

    // Track the last time the preview layer was rebuilt, to avoid excessive rebuilds
    private var lastRebuildTime: CFTimeInterval = 0

    // Track when the preview layer was last attached, to know its "age"
    private var previewLayerAttachedTime: CFTimeInterval = 0

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
        observeSpaceChanges()
        startMouseConfinement()
        startHealthCheck()

        print("[Window] Projection started on display \(displayID) using AVCaptureVideoPreviewLayer")
    }

    func stopProjection(cameraManager: CameraManager? = nil) {
        isProjectionActive = false
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

        self.window = projectionWindow

        // Build and attach the preview layer
        attachPreviewLayer(to: projectionWindow, session: cameraManager.captureSession)

        projectionWindow.setFrame(frame, display: true)
        projectionWindow.orderFrontRegardless()
    }

    /// Build a fresh PreviewBackedView + AVCaptureVideoPreviewLayer and attach to the window.
    private func attachPreviewLayer(to window: NSWindow, session: AVCaptureSession) {
        let frame = window.frame
        let view = PreviewBackedView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]

        let preview = view.previewLayer
        preview.session = session
        preview.videoGravity = .resizeAspect

        // Configure connection
        if let connection = preview.connection {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        window.contentView = view
        self.contentView = view
        self.previewLayerAttachedTime = CACurrentMediaTime()

        print("[Window] PreviewLayer attached, connection active: \(preview.connection?.isActive ?? false)")
    }

    // MARK: - Preview Layer Recovery

    /// Rebuild the preview layer from scratch.
    /// Called when the existing preview layer's GPU resources are corrupted
    /// or its connection has gone stale. Creates an entirely new
    /// PreviewBackedView + AVCaptureVideoPreviewLayer to guarantee
    /// a clean GPU pipeline.
    ///
    /// Has a minimum 500ms cooldown between rebuilds to avoid thrashing.
    func rebuildPreviewLayer() {
        guard isProjectionActive, !isRebuilding else { return }
        guard let window = self.window, let camera = activeCameraManager else { return }

        // Cooldown — don't rebuild more than once per 500ms
        let now = CACurrentMediaTime()
        if now - lastRebuildTime < 0.5 { return }

        isRebuilding = true
        lastRebuildTime = now
        let session = camera.captureSession

        print("[Window] Rebuilding preview layer (fresh GPU pipeline)")

        // IMPORTANT: Do NOT nil the old view's session before the new view is ready.
        // That causes a black frame flash because the window briefly shows a view
        // with no session. Instead:
        //   1. Build the new view and connect its preview layer to the session
        //   2. Swap window.contentView (atomic — old view removed, new view shown)
        //   3. THEN disconnect the old view's session
        // This way there is never a frame where the visible view has no session.

        let oldView = contentView

        // 1. Build fresh preview layer with session already connected
        let frame = window.frame
        let newView = PreviewBackedView(frame: NSRect(origin: .zero, size: frame.size))
        newView.autoresizingMask = [.width, .height]

        let preview = newView.previewLayer
        preview.session = session
        preview.videoGravity = .resizeAspect

        if let connection = preview.connection {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        // 2. Atomic swap — new view replaces old in a single
        //    contentView assignment. The window never shows a sessionless view.
        window.contentView = newView
        self.contentView = newView
        self.previewLayerAttachedTime = CACurrentMediaTime()
        window.orderFrontRegardless()

        // 3. NOW disconnect the old view (it's no longer visible)
        oldView?.previewLayer.session = nil

        self.isRebuilding = false
        print("[Window] Preview layer rebuilt, connection active: \(preview.connection?.isActive ?? false)")
    }

    // MARK: - Preview Layer Health Check

    /// Periodically verify the preview layer's connection is alive.
    /// Catches the case where the session runs fine and frames arrive
    /// to the heartbeat output, but the preview layer silently disconnects.
    private func startHealthCheck() {
        stopHealthCheck()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Timer fires on main RunLoop — we're already on main thread.
            // Use assumeIsolated to avoid Task allocation overhead.
            MainActor.assumeIsolated {
                self?.checkPreviewLayerHealth()
            }
        }
    }

    private func stopHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func checkPreviewLayerHealth() {
        guard isProjectionActive, !isRebuilding else { return }
        guard let preview = contentView?.previewLayer else {
            // No preview layer at all — rebuild
            print("[Window] Health: no preview layer, rebuilding")
            rebuildPreviewLayer()
            return
        }

        // Check 1: Does the preview layer have a session?
        guard preview.session != nil else {
            print("[Window] Health: session nil on preview layer, rebuilding")
            rebuildPreviewLayer()
            return
        }

        // Check 2: Is the connection active?
        // When AVFoundation drops the connection, connection becomes nil
        // or connection.isActive becomes false.
        if let connection = preview.connection {
            if !connection.isActive || !connection.isEnabled {
                print("[Window] Health: connection inactive/disabled, rebuilding")
                rebuildPreviewLayer()
                return
            }
        } else {
            // No connection at all — the preview layer lost its link to the session
            print("[Window] Health: no connection on preview layer, rebuilding")
            rebuildPreviewLayer()
            return
        }

        // Note: We don't do preventive rebuilds based on layer age.
        // That causes unnecessary flicker when the projection is working fine.
        // The space change observer (triple rebuild at 300ms/2000ms/4000ms)
        // and the connection checks above are sufficient to catch real problems.
    }

    // MARK: - Space / Mission Control Observation

    /// Observe workspace active space changes.
    /// Mission Control and Space switches trigger [_MTLDevice _purgeDevice],
    /// which invalidates the preview layer's GPU resources.
    ///
    /// Strategy: rebuild the preview layer THREE times with wide spread —
    /// macOS Tahoe plays ALL particle effects (confetti, balloons, fireworks,
    /// hearts, lasers) during Mission Control, each of which can trigger
    /// additional GPU purge events. The second [_purgeDevice] comes AFTER
    /// all animations finish, which can be 3-5 seconds later.
    ///
    /// 1. After 300ms  — fast recovery from initial purge
    /// 2. After 2000ms — catch mid-animation purges
    /// 3. After 4000ms — catch final purge after all animations complete
    private func observeSpaceChanges() {
        // Space changed (covers Mission Control exit, Space switch, fullscreen app switch)
        spaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isProjectionActive else { return }
                print("[Window] Space change detected, scheduling preview rebuilds")

                // First rebuild — fast recovery after initial GPU purge
                try? await Task.sleep(for: .milliseconds(300))
                guard self.isProjectionActive else { return }
                self.rebuildPreviewLayer()

                // Second rebuild — catch mid-animation GPU purges
                try? await Task.sleep(for: .milliseconds(1700))
                guard self.isProjectionActive else { return }
                self.rebuildPreviewLayer()

                // Third rebuild — final safety net after ALL particle effects
                // (confetti, balloons, fireworks, hearts, lasers) finish and
                // the second [_MTLDevice _purgeDevice] fires
                try? await Task.sleep(for: .milliseconds(2000))
                guard self.isProjectionActive else { return }
                self.rebuildPreviewLayer()
            }
        }

        // App re-activation (covers returning from other apps that may have taken GPU)
        appActivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Fires on .main queue — use assumeIsolated to avoid Task allocation
            MainActor.assumeIsolated {
                guard let self, self.isProjectionActive else { return }
                // Ensure window is on top and rebuild preview after app activation
                self.window?.orderFrontRegardless()
                self.rebuildPreviewLayer()
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
            // Coalesce rapid mouse events — only dispatch once per main run loop cycle
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
        if let observer = appActivateObserver {
            NotificationCenter.default.removeObserver(observer)
            appActivateObserver = nil
        }
    }

    // MARK: - Screen Disconnect Handling

    private func observeScreenDisconnect(cameraManager: CameraManager) {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak cameraManager] _ in
            // Fires on .main queue — check synchronously first
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.takenOverDisplayID != 0 {
                    let stillConnected = NSScreen.screens.contains(where: { $0.displayID == self.takenOverDisplayID })
                    if !stillConnected {
                        self.stopProjection(cameraManager: cameraManager)
                    } else {
                        // Display config changed but still connected — rebuild preview
                        // This handles resolution changes, display wake, etc.
                        // Only use Task for the delayed rebuild
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(300))
                            self?.rebuildPreviewLayer()
                        }
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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer.isOpaque = true
        previewLayer.backgroundColor = NSColor.black.cgColor
        return previewLayer
    }

    override var wantsUpdateLayer: Bool { true }
}
