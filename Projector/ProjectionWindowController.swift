//
//  ProjectionWindowController.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//
//  Manages a borderless fullscreen window on the external display.
//
//  Rendering pipeline: IOSurface-backed CALayer.contents
//
//  Uses AVCaptureVideoDataOutput to receive camera frames as CVPixelBuffer
//  (IOSurface-backed), then sets them directly on a CALayer.contents property.
//
//  Why NOT AVCaptureVideoPreviewLayer:
//  macOS Tahoe fires [_MTLDevice _purgeDevice] during space-transition particle
//  effects (confetti, balloons, fireworks, hearts, lasers). This silently
//  destroys Metal textures, including AVCaptureVideoPreviewLayer's internal
//  textures. The layer's connection still reports "active" but the display is
//  frozen. No notification fires for external displays. The freeze is permanent.
//
//  Why IOSurface + CALayer.contents works:
//  IOSurface data is managed by the kernel (IOSurfaceRoot kext), NOT by Metal.
//  When _purgeDevice destroys Metal textures, the IOSurface backing store
//  survives in system memory. Setting CALayer.contents to an IOSurface-backed
//  CVPixelBuffer lets WindowServer composite the frame directly without going
//  through the app's Metal pipeline.
//
//  Freeze detection:
//  A heartbeat monitor checks that frames are flowing. If frames stop for >1s,
//  we show a CGImage snapshot (CPU-resident, immune to GPU purge) as fallback
//  and bounce the session to restart frame delivery.
//

import AppKit
import AVFoundation
import CoreVideo
import os
import QuartzCore

@MainActor
final class ProjectionWindowController {

    private var window: NSWindow?
    private var displayView: IOSurfaceDisplayView?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?
    private var mouseEventMonitor: Any?
    private var pendingMouseConstrain = false

    // Health check timer — freeze detection
    private var healthTimer: Timer?

    // Keep reference for reconfiguration
    private weak var activeCameraManager: CameraManager?

    // Display state
    private var previousMirrorMaster: CGDirectDisplayID?
    private var wasMirroring = false
    private var takenOverDisplayID: CGDirectDisplayID = 0
    private var isProjectionActive = false

    // Cancellable recovery task
    private var recoveryTask: Task<Void, Never>?

    // Frame delegate — receives frames from AVCaptureVideoDataOutput
    private let frameReceiver = FrameReceiver()

    // Video data output — attached to the capture session for frame delivery
    private var videoDataOutput: AVCaptureVideoDataOutput?

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
        attachVideoOutput(to: cameraManager)

        self.isProjectionActive = true
        observeScreenDisconnect(cameraManager: cameraManager)
        observeSpaceAndVisibility()
        startMouseConfinement()
        startHealthCheck()

        print("[Window] Projection started on display \(displayID) using IOSurface + CALayer.contents")
    }

    func stopProjection(cameraManager: CameraManager? = nil) {
        isProjectionActive = false
        recoveryTask?.cancel()
        recoveryTask = nil
        stopHealthCheck()
        stopMouseConfinement()
        removeObservers()
        detachVideoOutput()

        activeCameraManager = nil

        displayView = nil
        window?.close()
        window = nil

        restoreDisplayState()
    }

    // MARK: - Window Creation

    private func createProjectionWindow(on screen: NSScreen, cameraManager: CameraManager) {
        // Clean up old
        displayView = nil
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

        // CRITICAL: Exclude this window from screen capture.
        // Without this, virtual cameras (Boom Camera, OBS Virtual Camera) that
        // capture the screen will create a feedback loop.
        projectionWindow.sharingType = .none

        self.window = projectionWindow

        // Build the display view — a plain CALayer that receives CVPixelBuffer frames
        let view = IOSurfaceDisplayView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]

        projectionWindow.contentView = view
        self.displayView = view

        projectionWindow.setFrame(frame, display: true)
        projectionWindow.orderFrontRegardless()

        print("[Window] IOSurface display view attached")
    }

    // MARK: - Video Data Output

    /// Attach AVCaptureVideoDataOutput to the capture session.
    /// Requests IOSurface-backed buffers so frames survive GPU purge.
    private func attachVideoOutput(to cameraManager: CameraManager) {
        detachVideoOutput()

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // Request IOSurface-backed BGRA buffers — kernel-managed, survives _purgeDevice
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        // Wire the frame receiver to push frames to our display view
        frameReceiver.displayView = displayView
        output.setSampleBufferDelegate(frameReceiver, queue: frameReceiver.queue)

        let session = cameraManager.captureSession
        session.beginConfiguration()
        if session.canAddOutput(output) {
            session.addOutput(output)
            self.videoDataOutput = output
            print("[Window] VideoDataOutput attached for IOSurface frame delivery")
        } else {
            print("[Window] WARNING: Could not add VideoDataOutput to session")
        }
        session.commitConfiguration()
    }

    /// Remove the video data output from the capture session.
    private func detachVideoOutput() {
        guard let output = videoDataOutput else { return }
        activeCameraManager?.captureSession.beginConfiguration()
        activeCameraManager?.captureSession.removeOutput(output)
        activeCameraManager?.captureSession.commitConfiguration()
        videoDataOutput = nil
        frameReceiver.displayView = nil
        print("[Window] VideoDataOutput detached")
    }

    /// Called externally (e.g., after session restart) to force recovery.
    func fullRebuildPreviewLayer() {
        guard isProjectionActive else { return }
        print("[Window] Full rebuild requested — bouncing session")
        bounceSession()
    }

    // MARK: - Health Check (Freeze Detection)
    //
    // Every 2 seconds, check if frames are flowing via the heartbeat.
    // If frames stopped for >1.5 seconds, the pipeline is likely frozen
    // by _purgeDevice. Show the CGImage snapshot fallback and bounce the session.
    //
    // This is the ONLY reliable detection method — connection.isActive lies,
    // no notifications fire for external displays.

    private func startHealthCheck() {
        stopHealthCheck()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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
        guard isProjectionActive else { return }

        let timeSinceLastFrame = frameReceiver.timeSinceLastFrame()

        if timeSinceLastFrame > 1.5 && frameReceiver.hasReceivedAnyFrame {
            print("[Window] Health: no frame for \(String(format: "%.1f", timeSinceLastFrame))s — frozen, bouncing session")
            // Show last good frame as CGImage (CPU-resident, immune to GPU purge)
            if let snapshot = frameReceiver.lastGoodSnapshot {
                displayView?.showSnapshot(snapshot)
            }
            bounceSession()
        }

        // Always keep window on top
        window?.orderFrontRegardless()
    }

    /// Bounce the capture session — stop and restart.
    /// This forces AVFoundation to rebuild its internal GPU pipeline.
    /// The display view keeps showing the last frame (or snapshot) during the bounce.
    private func bounceSession() {
        guard let camera = activeCameraManager else { return }
        let session = camera.captureSession

        Task.detached { [weak self] in
            if session.isRunning {
                session.stopRunning()
            }
            // Brief pause to let GPU recover from purge
            try? await Task.sleep(for: .milliseconds(300))
            session.startRunning()

            await MainActor.run { [weak self] in
                guard let self, self.isProjectionActive else { return }
                print("[Window] Session bounced, isRunning: \(session.isRunning)")
                self.window?.orderFrontRegardless()
            }
        }
    }

    // MARK: - Space / Mission Control / Stage Manager Observation

    /// Observe space changes, visibility, and app activation.
    /// These events correlate with _purgeDevice firing, so we
    /// proactively check health and bounce if needed.
    private func observeSpaceAndVisibility() {
        // Space change — Mission Control, Stage Manager, desktop swipe
        spaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isProjectionActive else { return }
                print("[Window] Space change detected")
                self.window?.orderFrontRegardless()
                self.scheduleRecoveryCheck()
            }
        }

        // Occlusion — app becomes visible again
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isProjectionActive else { return }
                let isVisible = NSApp.occlusionState.contains(.visible)
                if isVisible {
                    print("[Window] App became visible")
                    self.window?.orderFrontRegardless()
                    self.scheduleRecoveryCheck()
                }
            }
        }

        // App activation
        appActivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isProjectionActive else { return }
                print("[Window] App activated")
                self.window?.orderFrontRegardless()
                self.scheduleRecoveryCheck()
            }
        }
    }

    /// After an event that might correlate with GPU purge,
    /// check if frames are still flowing. If not, bounce.
    private func scheduleRecoveryCheck() {
        recoveryTask?.cancel()

        recoveryTask = Task { @MainActor [weak self] in
            guard let self, self.isProjectionActive else { return }

            // Wait a moment for the transition particle effects to fire
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.isProjectionActive else { return }
            self.checkHealth()

            // Check again after effects may have finished
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self.isProjectionActive else { return }
            self.checkHealth()

            // Final check
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.isProjectionActive else { return }
            self.checkHealth()
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

// MARK: - IOSurface Display View

/// An NSView that displays CVPixelBuffer frames via CALayer.contents.
/// The layer content is set directly to the IOSurface-backed pixel buffer,
/// bypassing Metal entirely. WindowServer composites the IOSurface directly.
final class IOSurfaceDisplayView: NSView {

    private let displayLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.contentsGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.isOpaque = true
        // Suppress implicit animations on content changes
        displayLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// Display a CVPixelBuffer frame (IOSurface-backed).
    /// Called from the frame receiver's output queue, dispatched to main.
    func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        // Setting CALayer.contents to a CVPixelBuffer works on macOS.
        // The IOSurface backing survives GPU texture purge.
        displayLayer.contents = pixelBuffer
    }

    /// Show a CGImage snapshot (CPU-resident fallback during freeze).
    func showSnapshot(_ image: CGImage) {
        displayLayer.contents = image
    }
}

// MARK: - Frame Receiver

/// Receives frames from AVCaptureVideoDataOutput on a dedicated queue.
/// Pushes them to the IOSurfaceDisplayView and maintains a heartbeat
/// for freeze detection, plus periodic CGImage snapshots for fallback.
final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let queue = DispatchQueue(label: "com.projector.frameReceiver", qos: .userInteractive)

    /// The display view to push frames to (weak, main-actor owned).
    weak var displayView: IOSurfaceDisplayView?

    /// Heartbeat — updated atomically on the output queue.
    /// Read from the main thread for health checks.
    private let _lastFrameTime = OSAllocatedUnfairLock(initialState: CFAbsoluteTime(0))
    private let _hasReceivedAnyFrame = OSAllocatedUnfairLock(initialState: false)

    /// Last good CGImage snapshot (CPU-resident, immune to GPU purge).
    private let _lastGoodSnapshot = OSAllocatedUnfairLock<CGImage?>(initialState: nil)
    private var snapshotCounter = 0

    var hasReceivedAnyFrame: Bool {
        _hasReceivedAnyFrame.withLock { $0 }
    }

    var lastGoodSnapshot: CGImage? {
        _lastGoodSnapshot.withLock { $0 }
    }

    func timeSinceLastFrame() -> TimeInterval {
        let lastTime = _lastFrameTime.withLock { $0 }
        guard lastTime > 0 else { return 0 }
        return CFAbsoluteTimeGetCurrent() - lastTime
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Update heartbeat
        _lastFrameTime.withLock { $0 = CFAbsoluteTimeGetCurrent() }
        _hasReceivedAnyFrame.withLock { $0 = true }

        // Capture CGImage snapshot periodically (every ~60 frames ≈ 1-2s)
        snapshotCounter += 1
        if snapshotCounter % 60 == 0 {
            captureSnapshot(from: pixelBuffer)
        }

        // Push frame to display view on main thread
        let view = displayView
        DispatchQueue.main.async {
            view?.displayPixelBuffer(pixelBuffer)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Still update heartbeat — dropped frames mean the pipeline is alive
        _lastFrameTime.withLock { $0 = CFAbsoluteTimeGetCurrent() }
    }

    // MARK: - Snapshot

    private func captureSnapshot(from pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        if let image = context.makeImage() {
            _lastGoodSnapshot.withLock { $0 = image }
        }
    }
}
