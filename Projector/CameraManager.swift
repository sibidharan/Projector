//
//  CameraManager.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//
//  Pipeline Architecture:
//  ──────────────────────
//  Menu Bar Preview:  AVCaptureSession → AVCaptureVideoPreviewLayer (zero-copy GPU path)
//  HDMI Projection:   AVCaptureSession → AVCaptureVideoPreviewLayer (zero-copy GPU path)
//
//  Both the menu bar preview and the HDMI projection window use
//  AVCaptureVideoPreviewLayer — Apple's own optimized rendering path.
//
//  Frame Heartbeat:
//  A lightweight AVCaptureVideoDataOutput acts as a heartbeat monitor.
//  It doesn't process frames — it just records when the last frame arrived.
//  A watchdog timer checks this timestamp and restarts the session if
//  frames stop arriving for > 2 seconds (capture card stall).
//

import AVFoundation
import Combine
import CoreMedia
import QuartzCore

@MainActor
final class CameraManager: NSObject, ObservableObject {

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice? {
        didSet {
            guard selectedCamera?.uniqueID != oldValue?.uniqueID else { return }
            reconfigureSession()
        }
    }
    @Published var isRunning = false
    @Published var configuredFPS: Double = 0
    @Published var currentResolution: String = ""
    @Published var currentCodec: String = ""

    // Camera format/mode selection
    @Published var availableCameraModes: [CameraMode] = []
    @Published var currentCameraMode: CameraMode?

    let captureSession = AVCaptureSession()

    // Projection controller — for triggering preview layer reconnection on recovery
    weak var projectionController: ProjectionWindowController?

    private var currentInput: AVCaptureDeviceInput?
    private var heartbeatOutput: AVCaptureVideoDataOutput?
    private var deviceObservers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []

    // Frame heartbeat — timestamp of last received frame
    // Written by heartbeatQueue (background), read by watchdog and health check
    nonisolated(unsafe) var _lastFrameTime: CFTimeInterval = 0

    /// Public accessor for the last frame timestamp.
    /// Used by ProjectionWindowController's health check to detect
    /// when frames are arriving but the preview layer is stale.
    var lastFrameTime: CFTimeInterval { _lastFrameTime }
    // Use .utility QoS — heartbeat only timestamps frames, doesn't need high priority.
    // Using .userInitiated wastes CPU competing with the main thread.
    private let heartbeatQueue = DispatchQueue(label: "projector.heartbeat", qos: .utility)

    // Watchdog timer — detects frozen capture card
    private var watchdogTimer: Timer?
    private var isRestarting = false

    override init() {
        super.init()
        refreshCameraList()
        observeDeviceChanges()
        observeSessionEvents()
    }

    deinit {
        watchdogTimer?.invalidate()
        for observer in deviceObservers + sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Camera Enumeration

    func refreshCameraList() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discoverySession.devices

        if selectedCamera == nil, let first = availableCameras.first {
            selectedCamera = first
        }
    }

    // MARK: - Session Management

    func startSession() {
        guard !captureSession.isRunning else { return }

        if currentInput == nil {
            reconfigureSession()
        }

        Task.detached { [captureSession] in
            captureSession.startRunning()
            await MainActor.run { [weak self] in
                self?.isRunning = true
                self?._lastFrameTime = CACurrentMediaTime()
                self?.startWatchdog()
            }
        }
    }

    func stopSession() {
        guard captureSession.isRunning else { return }
        stopWatchdog()

        Task.detached { [captureSession] in
            captureSession.stopRunning()
            await MainActor.run { [weak self] in
                self?.isRunning = false
                self?.configuredFPS = 0
            }
        }
    }

    /// Restart the capture session to recover from stalls.
    /// After restart, also reconnects the projection preview layer
    /// to force AVFoundation to rebuild its GPU pipeline.
    func restartSession() {
        guard !isRestarting else { return }
        isRestarting = true
        print("[Camera] Restarting session to recover from stall")

        Task.detached { [captureSession, weak self] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            // Brief pause to let the capture card reset
            try? await Task.sleep(for: .milliseconds(300))
            captureSession.startRunning()

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRestarting = false
                self.isRunning = captureSession.isRunning
                self._lastFrameTime = CACurrentMediaTime()
                if captureSession.isRunning {
                    print("[Camera] Session restarted successfully")
                    // Rebuild the preview layer so it gets a fresh GPU pipeline
                    self.projectionController?.rebuildPreviewLayer()
                }
            }
        }
    }

    // MARK: - Configuration

    private func reconfigureSession() {
        guard let device = selectedCamera else { return }

        // Disable macOS system video effects BEFORE session configuration.
        // These effects (Center Stage, Portrait Blur, Studio Light) intercept
        // every frame in the CMIO pipeline and can cause massive frame drops
        // when CVPixelBufferPool allocation fails (error -6689).
        disableSystemVideoEffects(for: device)

        captureSession.beginConfiguration()

        // Remove existing input
        if let existing = currentInput {
            captureSession.removeInput(existing)
            currentInput = nil
        }

        // Remove existing heartbeat output
        if let existing = heartbeatOutput {
            captureSession.removeOutput(existing)
            heartbeatOutput = nil
        }

        // Set session preset to high for best quality pipeline hint
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }

        // Add new input
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                currentInput = input
            }
        } catch {
            print("Failed to create camera input: \(error.localizedDescription)")
            captureSession.commitConfiguration()
            return
        }

        // Add heartbeat output — lightweight frame arrival monitor.
        // alwaysDiscardsLateVideoFrames = true ensures this never buffers.
        // The delegate just timestamps — no processing, no copies.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: heartbeatQueue)

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            heartbeatOutput = output
        }

        // Configure best format — prefers formats without Portrait Effect
        // to bypass the PortraitBlur pipeline entirely
        configureBestFormat(for: device)

        captureSession.commitConfiguration()

        // Log device info
        let isExternal = device.deviceType == .external
        print("[Camera] Device: \(device.localizedName) (external: \(isExternal))")
    }

    /// Disable macOS system video effects that intercept the CMIO pipeline.
    /// Center Stage, Portrait Blur, and Studio Light all process every frame
    /// through CVPixelBufferPool, which can fail and drop frames.
    private func disableSystemVideoEffects(for device: AVCaptureDevice) {
        // Center Stage — we can take app-level control and disable it
        if AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
            print("[Camera] Disabled Center Stage")
        }

        // Portrait Effect — can only be read, not set programmatically.
        // We handle this by preferring formats where isPortraitEffectSupported = false.
        if device.isPortraitEffectActive {
            print("[Camera] Warning: Portrait Effect is active — prefer non-portrait format")
            print("[Camera] To avoid frame drops, disable Portrait Effect in System Settings > Camera")
        }
    }

    private func configureBestFormat(for device: AVCaptureDevice) {
        var modes: [CameraMode] = []

        for format in device.formats {
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let subType = CMFormatDescriptionGetMediaSubType(desc)

            let bestRange = format.videoSupportedFrameRateRanges
                .max(by: { $0.maxFrameRate < $1.maxFrameRate })

            guard let range = bestRange, range.maxFrameRate >= 15 else { continue }

            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            let maxFPS = range.maxFrameRate
            let fourCC = fourCharCodeToString(subType)

            // Check if this format triggers the PortraitBlur pipeline
            let hasPortrait = format.isPortraitEffectSupported
            let hasCenterStage = format.isCenterStageSupported

            modes.append(CameraMode(
                format: format,
                width: width,
                height: height,
                maxFPS: maxFPS,
                codec: fourCC,
                hasPortraitEffect: hasPortrait,
                hasCenterStage: hasCenterStage
            ))
        }

        // Sort: prefer formats WITHOUT system video effects (they cause frame drops),
        // then highest resolution, then highest FPS, then raw formats
        modes.sort { a, b in
            // Prefer no-effect formats — they bypass the PortraitBlur pipeline
            let aClean = !a.hasPortraitEffect && !a.hasCenterStage
            let bClean = !b.hasPortraitEffect && !b.hasCenterStage
            if aClean != bClean { return aClean }

            let pixelsA = a.width * a.height
            let pixelsB = b.width * b.height
            if pixelsA != pixelsB { return pixelsA > pixelsB }
            if a.maxFPS != b.maxFPS { return a.maxFPS > b.maxFPS }
            let aRaw = a.codec == "420v" || a.codec == "420f" || a.codec == "yuvs"
            let bRaw = b.codec == "420v" || b.codec == "420f" || b.codec == "yuvs"
            if aRaw != bRaw { return aRaw }
            return false
        }

        availableCameraModes = modes

        let best = modes.first(where: { $0.maxFPS >= 30 })
            ?? modes.first(where: { $0.maxFPS >= 24 })
            ?? modes.first
        if let best {
            applyCameraMode(best, to: device)
            if best.hasPortraitEffect || best.hasCenterStage {
                print("[Camera] Warning: selected format supports system effects (Portrait/CenterStage)")
                print("[Camera] This may cause frame drops. Disable effects in System Settings > Camera")
            }
        }
    }

    func applyCameraMode(_ mode: CameraMode) {
        guard let device = selectedCamera else { return }
        applyCameraMode(mode, to: device)
    }

    private func applyCameraMode(_ mode: CameraMode, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.activeFormat = mode.format
            let targetFPS = min(mode.maxFPS, 60)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.unlockForConfiguration()

            configuredFPS = targetFPS
            currentResolution = "\(mode.width)x\(mode.height)"
            currentCodec = mode.codec
            currentCameraMode = mode
            print("[Camera] Format: \(mode.width)x\(mode.height) @ \(targetFPS)fps, codec: \(mode.codec)")
        } catch {
            print("Failed to configure format: \(error.localizedDescription)")
        }
    }

    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - Session Event Observation

    private func observeSessionEvents() {
        // Session was interrupted (e.g., capture card hiccup, system sleep)
        let interruptionObs = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: captureSession,
            queue: .main
        ) { [weak self] _ in
            print("[Camera] Session interrupted")
            // Need Task only for the delayed restart
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.restartSession()
            }
        }

        // Session interruption ended
        let interruptionEndedObs = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: captureSession,
            queue: .main
        ) { _ in
            print("[Camera] Session interruption ended")
        }

        // Session runtime error
        let errorObs = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            print("[Camera] Session runtime error: \(error?.localizedDescription ?? "unknown")")
            // Need Task only for the delayed restart
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.restartSession()
            }
        }

        sessionObservers = [interruptionObs, interruptionEndedObs, errorObs]
    }

    // MARK: - Watchdog Timer

    /// Checks every 2 seconds if frames are still arriving.
    /// If no frame has arrived in > 2 seconds, the capture card has stalled
    /// and we need to restart the session.
    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Timer fires on main RunLoop — already on main thread.
            // Use assumeIsolated to avoid Task allocation overhead.
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.isRestarting else { return }

                // Check if session stopped
                if !self.captureSession.isRunning {
                    print("[Camera] Watchdog: session stopped unexpectedly, restarting")
                    self.restartSession()
                    return
                }

                // Check if frames stopped arriving (capture card stall)
                let now = CACurrentMediaTime()
                let elapsed = now - self._lastFrameTime
                if elapsed > 2.0 && self._lastFrameTime > 0 {
                    print("[Camera] Watchdog: no frames for \(String(format: "%.1f", elapsed))s, restarting session")
                    self.restartSession()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Device Observation

    private func observeDeviceChanges() {
        let connectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCameraList()
            }
        }

        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let device = notif.object as? AVCaptureDevice
            let disconnectedID = device?.uniqueID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let disconnectedID, disconnectedID == self.selectedCamera?.uniqueID {
                    self.selectedCamera = self.availableCameras.first
                }
                self.refreshCameraList()
            }
        }

        deviceObservers = [connectObserver, disconnectObserver]
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Heartbeat)

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Called on heartbeatQueue for every camera frame.
    /// This is ONLY a heartbeat — just records the timestamp.
    /// The actual rendering is done by AVCaptureVideoPreviewLayer.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        _lastFrameTime = CACurrentMediaTime()
    }

    /// Called when a frame is dropped. Capture cards can drop frames
    /// during signal renegotiation or bandwidth hiccups.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Still counts as "alive" — frames are being delivered, just dropped
        _lastFrameTime = CACurrentMediaTime()
    }
}

// MARK: - Camera Mode Model

struct CameraMode: Identifiable, Hashable {
    let format: AVCaptureDevice.Format
    let width: Int
    let height: Int
    let maxFPS: Double
    let codec: String
    let hasPortraitEffect: Bool
    let hasCenterStage: Bool

    var id: String { "\(width)x\(height)@\(Int(maxFPS))_\(codec)" }

    var label: String {
        var text = "\(width)x\(height) @ \(Int(maxFPS)) fps (\(codec))"
        if hasPortraitEffect || hasCenterStage {
            text += " ⚠️"
        }
        return text
    }

    static func == (lhs: CameraMode, rhs: CameraMode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
