//
//  AudioManager.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//
//  Ultra-low-latency audio passthrough from microphone (or camera audio) to HDMI output.
//
//  Architecture:
//  ─────────────
//  1. Create an Aggregate Device combining mic (input) + HDMI (output).
//     Input device is the CLOCK MASTER — drives callback timing for minimum
//     input latency. Drift compensation is on the output (non-master) side.
//  2. Set the SMALLEST possible I/O buffer on all devices (typically 64 samples
//     = 1.3ms at 48kHz). CPU is fine because metering only runs when visible.
//  3. HAL AudioUnit with a lightweight render callback that pulls mic data
//     from bus 1 and passes it through to bus 0 (HDMI). Zero processing —
//     just a direct passthrough for minimum latency.
//  4. Level metering is ONLY active when the menu popover is visible.
//     When hidden, the render callback skips RMS entirely (zero overhead).
//     When visible, metering is throttled to every 256th callback (~3/sec).
//  5. Camera audio detection — finds the companion audio device for capture
//     cards (matched by modelID). Skips drift compensation since camera audio
//     and video share the same USB clock for perfect lip sync.
//  6. Virtual mic detection — skips drift compensation for software mics
//     (BoomAudio, OBS, BlackHole) since they share the system clock.
//  7. Channel count matching — uses min(input, output) channels to avoid
//     expensive multi-channel mixdown (e.g., 6ch BoomAudio → 2ch HDMI).
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

@MainActor
final class AudioManager: ObservableObject {

    @Published var availableMics: [AVCaptureDevice] = []
    @Published var selectedMic: AVCaptureDevice? {
        didSet {
            guard selectedMic?.uniqueID != oldValue?.uniqueID else { return }
            if isRouting { restartRouting() }
        }
    }
    @Published var isRouting = false
    @Published var inputLevel: Float = 0
    @Published var routingError: String?

    // Camera audio — detected companion audio device for the current camera
    @Published var cameraAudioDevice: AVCaptureDevice?
    @Published var isCameraAudioSelected: Bool = false

    // We need to store both the aggregate device and the current output device
    // so we can restart routing when the mic changes
    nonisolated(unsafe) var audioUnit: AudioUnit?
    private var aggregateDeviceID: AudioDeviceID = 0
    private var currentOutputDeviceID: AudioDeviceID = 0
    private var deviceObservers: [NSObjectProtocol] = []

    // Level metering — only active when the menu popover is visible.
    // When hidden, the render callback skips RMS computation entirely,
    // saving CPU cycles on the real-time audio thread.
    nonisolated(unsafe) var _meterEnabled: Bool = false
    nonisolated(unsafe) var _meterCounter: Int32 = 0
    nonisolated(unsafe) var _pendingLevel: Float = 0

    // Audio error tracking — consecutive render errors trigger recovery
    nonisolated(unsafe) var _renderErrorCount: Int32 = 0
    private var audioRecoveryTimer: Timer?

    init() {
        refreshMicList()
        observeDeviceChanges()
    }

    deinit {
        for observer in deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Device Enumeration

    func refreshMicList() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        // Filter out our own aggregate devices — they appear in the discovery
        // session and cause Picker tag mismatches if selected.
        availableMics = discovery.devices.filter {
            !$0.uniqueID.hasPrefix("com.projector.aggregate.")
        }

        if selectedMic == nil && !isCameraAudioSelected, let first = availableMics.first {
            selectedMic = first
        }

        // Re-validate camera audio device still exists
        if let cameraAudio = cameraAudioDevice,
           !discovery.devices.contains(where: { $0.uniqueID == cameraAudio.uniqueID }) {
            cameraAudioDevice = nil
            if isCameraAudioSelected {
                isCameraAudioSelected = false
                selectedMic = availableMics.first
            }
        }
    }

    // MARK: - Camera Audio Detection

    /// Finds the audio AVCaptureDevice that belongs to the same hardware as the given camera.
    /// Capture cards (USB) expose separate video and audio AVCaptureDevices with the same modelID.
    func updateCameraAudioDevice(for camera: AVCaptureDevice?) {
        guard let camera = camera else {
            cameraAudioDevice = nil
            if isCameraAudioSelected {
                isCameraAudioSelected = false
                selectedMic = availableMics.first
            }
            return
        }

        let audioDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        // Filter out our own aggregate devices
        let audioDevices = audioDiscovery.devices.filter {
            !$0.uniqueID.hasPrefix("com.projector.aggregate.")
        }

        // Primary match: same modelID (most reliable — same hardware shares modelID)
        if let match = audioDevices.first(where: {
            $0.modelID == camera.modelID && $0.uniqueID != camera.uniqueID
        }) {
            cameraAudioDevice = match
            print("[Audio] Camera audio detected: \(match.localizedName) (modelID: \(match.modelID))")
            return
        }

        // Fallback: name-based matching (mutual containment)
        let cameraName = camera.localizedName.lowercased()
        if let match = audioDevices.first(where: {
            let audioName = $0.localizedName.lowercased()
            return audioName.contains(cameraName) || cameraName.contains(audioName)
        }) {
            cameraAudioDevice = match
            print("[Audio] Camera audio detected (name match): \(match.localizedName)")
            return
        }

        // No companion audio device found
        cameraAudioDevice = nil
        if isCameraAudioSelected {
            print("[Audio] Camera audio lost, falling back to mic")
            isCameraAudioSelected = false
            selectedMic = availableMics.first
        }
    }

    /// Select the camera's companion audio device as the audio source.
    func selectCameraAudio() {
        guard let device = cameraAudioDevice else { return }
        isCameraAudioSelected = true
        selectedMic = device
    }

    /// Select a regular microphone as the audio source.
    func selectMicrophone(_ mic: AVCaptureDevice?) {
        isCameraAudioSelected = false
        selectedMic = mic
    }

    // MARK: - Audio Routing via Aggregate Device + HAL AudioUnit
    //
    // Problem: A single HAL AudioUnit can only have ONE device. You can't set
    // an input device on bus 1 and a different output device on bus 0.
    //
    // Solution: Create a temporary Aggregate Device that combines the mic (as input
    // sub-device) and the HDMI output (as output sub-device) into a single virtual
    // device with drift compensation. Then set that aggregate device on the AudioUnit.

    func startRouting(toOutputDeviceID outputDeviceID: AudioDeviceID) {
        stopRouting()
        routingError = nil
        currentOutputDeviceID = outputDeviceID

        guard let mic = selectedMic else {
            routingError = "No microphone selected"
            return
        }

        // Step 1: Get the Core Audio device ID for the mic
        guard let inputDeviceID = coreAudioDeviceID(forAVCaptureUID: mic.uniqueID) else {
            routingError = "Cannot find audio device for mic: \(mic.localizedName)"
            return
        }

        // Get UIDs for both devices
        guard let inputUID = deviceUID(for: inputDeviceID),
              let outputUID = deviceUID(for: outputDeviceID) else {
            routingError = "Cannot get device UIDs"
            return
        }

        // Camera audio shares the same USB clock as the video — no drift compensation.
        // Virtual devices (BoomAudio, OBS, etc.) share the system clock — also no drift.
        let isVirtualInput = isVirtualDevice(inputDeviceID)
        let skipDriftCompensation = isCameraAudioSelected || isVirtualInput
        print("[Audio] Input device: \(mic.localizedName) (UID: \(inputUID), ID: \(inputDeviceID), virtual: \(isVirtualInput), cameraAudio: \(isCameraAudioSelected))")
        print("[Audio] Output device ID: \(outputDeviceID) (UID: \(outputUID))")

        // Step 1.5: Set minimum buffer size on both hardware devices
        setMinimumBufferSize(for: inputDeviceID)
        setMinimumBufferSize(for: outputDeviceID)

        // Step 2: Create an Aggregate Device combining input + output
        // Skip drift compensation for camera audio (same USB clock) and
        // virtual devices (same system clock) to avoid unnecessary latency.
        let aggregateResult = createAggregateDevice(
            inputUID: inputUID,
            outputUID: outputUID,
            enableDriftCompensation: !skipDriftCompensation
        )
        guard let aggDeviceID = aggregateResult else {
            routingError = "Cannot create aggregate device"
            return
        }
        self.aggregateDeviceID = aggDeviceID
        print("[Audio] Aggregate device created: \(aggDeviceID) (drift comp: \(!skipDriftCompensation))")

        // Also set minimum buffer size on the aggregate device itself
        setMinimumBufferSize(for: aggDeviceID)

        // Step 3: Create HAL AudioUnit with the aggregate device
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            routingError = "Cannot find HAL audio component"
            destroyAggregateDevice()
            return
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            routingError = "Cannot create audio unit: \(status)"
            destroyAggregateDevice()
            return
        }

        // Enable IO on both buses
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1,
                                      &enableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            routingError = "Cannot enable input IO: \(status)"
            AudioComponentInstanceDispose(unit)
            destroyAggregateDevice()
            return
        }

        var enableOutput: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0,
                                      &enableOutput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            routingError = "Cannot enable output IO: \(status)"
            AudioComponentInstanceDispose(unit)
            destroyAggregateDevice()
            return
        }

        // Set the aggregate device as THE device for this AudioUnit
        var aggID = aggDeviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0,
                                      &aggID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            routingError = "Cannot set aggregate device: \(status)"
            AudioComponentInstanceDispose(unit)
            destroyAggregateDevice()
            return
        }

        // Get the hardware input format (what the mic actually delivers)
        // Bus 1, Input scope = hardware side of input bus
        var hwInputASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 1,
                                      &hwInputASBD, &asbdSize)
        print("[Audio] Hardware input format: \(describeASBD(hwInputASBD)) status=\(status)")

        // Get the hardware output format to match channel count
        var hwOutputASBD = AudioStreamBasicDescription()
        var outAsbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 0,
                             &hwOutputASBD, &outAsbdSize)
        print("[Audio] Hardware output format: \(describeASBD(hwOutputASBD))")

        // Use the MINIMUM of input and output channels to avoid unnecessary
        // channel conversion overhead. HDMI typically has 2 channels, but
        // virtual mics like BoomAudio can have 6+. Mixing down 6→2 adds latency.
        let inputChannels = hwInputASBD.mChannelsPerFrame > 0 ? hwInputASBD.mChannelsPerFrame : 1
        let outputChannels = hwOutputASBD.mChannelsPerFrame > 0 ? hwOutputASBD.mChannelsPerFrame : 2
        let processingChannels = min(inputChannels, outputChannels)
        print("[Audio] Processing channels: \(processingChannels) (input: \(inputChannels), output: \(outputChannels))")

        // Create a canonical Float32 non-interleaved format for the internal processing
        let sampleRate = hwInputASBD.mSampleRate > 0 ? hwInputASBD.mSampleRate : 48000.0
        var processingFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: processingChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Set Float32 format on the OUTPUT scope of bus 1 (what we read from input)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1,
                                      &processingFormat, asbdSize)
        print("[Audio] Set bus 1 output format (\(processingChannels)ch): status=\(status)")

        // Set Float32 format on the INPUT scope of bus 0 (what we feed to output)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0,
                                      &processingFormat, asbdSize)
        print("[Audio] Set bus 0 input format (\(processingChannels)ch): status=\(status)")

        // Render callback — pulls mic data from bus 1 and passes it to bus 0.
        // This is a lightweight passthrough with throttled level metering.
        // The callback itself does zero audio processing — just AudioUnitRender
        // from bus 1 into the output buffer.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: audioPassthroughCallback,
            inputProcRefCon: selfPtr
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0,
                                      &callbackStruct,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            routingError = "Cannot set render callback: \(status)"
            AudioComponentInstanceDispose(unit)
            destroyAggregateDevice()
            return
        }

        // Initialize and start
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            routingError = "Cannot initialize audio unit: \(status)"
            AudioComponentInstanceDispose(unit)
            destroyAggregateDevice()
            return
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            routingError = "Cannot start audio unit: \(status)"
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            destroyAggregateDevice()
            return
        }

        self.audioUnit = unit
        self._renderErrorCount = 0
        isRouting = true
        startAudioHealthCheck()

        // Log the achieved latency — comprehensive breakdown
        let bufferSize = getBufferSize(for: aggDeviceID)
        let bufferMs = Double(bufferSize) / sampleRate * 1000.0

        let inputLatency = getDeviceLatency(for: inputDeviceID, scope: kAudioDevicePropertyScopeInput)
        let outputLatency = getDeviceLatency(for: outputDeviceID, scope: kAudioDevicePropertyScopeOutput)
        let inputSafety = getDeviceSafetyOffset(for: inputDeviceID, scope: kAudioDevicePropertyScopeInput)
        let outputSafety = getDeviceSafetyOffset(for: outputDeviceID, scope: kAudioDevicePropertyScopeOutput)

        let inputBufferSize = getBufferSize(for: inputDeviceID)
        let outputBufferSize = getBufferSize(for: outputDeviceID)

        let totalFrames = bufferSize + inputLatency + outputLatency + inputSafety + outputSafety
        let totalMs = Double(totalFrames) / sampleRate * 1000.0

        print("[Audio] ═══ Latency Breakdown ═══")
        print("[Audio] Input buffer: \(inputBufferSize) samples (\(String(format: "%.1f", Double(inputBufferSize)/sampleRate*1000))ms)")
        print("[Audio] Output buffer: \(outputBufferSize) samples (\(String(format: "%.1f", Double(outputBufferSize)/sampleRate*1000))ms)")
        print("[Audio] Aggregate buffer: \(bufferSize) samples (\(String(format: "%.1f", bufferMs))ms)")
        print("[Audio] Input device latency: \(inputLatency) frames (\(String(format: "%.1f", Double(inputLatency)/sampleRate*1000))ms)")
        print("[Audio] Output device latency: \(outputLatency) frames (\(String(format: "%.1f", Double(outputLatency)/sampleRate*1000))ms)")
        print("[Audio] Input safety offset: \(inputSafety) frames (\(String(format: "%.1f", Double(inputSafety)/sampleRate*1000))ms)")
        print("[Audio] Output safety offset: \(outputSafety) frames (\(String(format: "%.1f", Double(outputSafety)/sampleRate*1000))ms)")
        print("[Audio] Total estimated: \(String(format: "%.1f", totalMs))ms (\(totalFrames) frames @ \(sampleRate)Hz)")
        print("[Audio] ═════════════════════════")
    }

    private func describeASBD(_ asbd: AudioStreamBasicDescription) -> String {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        return "\(asbd.mSampleRate)Hz, \(asbd.mChannelsPerFrame)ch, \(asbd.mBitsPerChannel)bit, \(isFloat ? "float" : "int"), \(isInterleaved ? "interleaved" : "non-interleaved")"
    }

    func stopRouting() {
        stopAudioHealthCheck()
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        destroyAggregateDevice()
        isRouting = false
        inputLevel = 0
    }

    private func restartRouting() {
        let outputID = currentOutputDeviceID
        stopRouting()
        if outputID != 0 {
            startRouting(toOutputDeviceID: outputID)
        }
    }

    // MARK: - Buffer Size Management

    /// Set the lowest possible I/O buffer size on a device for minimum latency.
    /// Smaller buffers = lower latency but more CPU. Since metering is conditional
    /// (only when popover visible), we can afford very small buffers.
    private func setMinimumBufferSize(for deviceID: AudioDeviceID) {
        // Get the allowed buffer size range
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        let rangeStatus = AudioObjectGetPropertyData(deviceID, &rangeAddress, 0, nil, &rangeSize, &range)

        // Target the SMALLEST buffer the hardware supports.
        // USB capture cards typically support 64-128 samples minimum.
        // 64 samples @ 48kHz = 1.3ms, 128 = 2.7ms, 256 = 5.3ms.
        // CPU is fine because metering only runs when popover is visible.
        var targetSize: UInt32 = 64
        if rangeStatus == noErr {
            targetSize = max(targetSize, UInt32(range.mMinimum))
            targetSize = min(targetSize, UInt32(range.mMaximum))
            print("[Audio] Buffer range for device \(deviceID): \(UInt32(range.mMinimum))–\(UInt32(range.mMaximum)), using \(targetSize)")
        }

        // Set the buffer size
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &targetSize)
        if status == noErr {
            print("[Audio] Buffer size set to \(targetSize) samples for device \(deviceID)")
        }
    }

    /// Get the current buffer size for a device.
    private func getBufferSize(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufferSize: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &bufferSize)
        return bufferSize
    }

    // MARK: - Aggregate Device Management

    private func createAggregateDevice(inputUID: String, outputUID: String, enableDriftCompensation: Bool) -> AudioDeviceID? {
        // The INPUT device is the clock master — this minimizes input latency
        // because the audio callback fires in sync with the input hardware clock.
        // The output (HDMI) adapts to the input timing via drift compensation.
        //
        // Drift compensation goes on the OUTPUT (non-master) sub-device.
        // When clocks differ, the output resamples to match the input clock.
        // This keeps input latency at zero extra frames while output adapts.
        //
        // For camera audio or virtual devices, clocks are shared so we
        // skip drift comp entirely (avoids ~1 buffer of resampling latency).
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Projector Audio Bridge",
            kAudioAggregateDeviceUIDKey as String: "com.projector.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: inputUID
                ] as [String : Any],
                [
                    kAudioSubDeviceUIDKey as String: outputUID,
                    kAudioSubDeviceDriftCompensationKey as String: enableDriftCompensation
                ] as [String : Any]
            ],
            kAudioAggregateDeviceMasterSubDeviceKey as String: inputUID
        ]

        var aggregateID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        if status != noErr {
            print("Failed to create aggregate device: \(status)")
            return nil
        }
        return aggregateID
    }

    /// Check if a device is virtual (software-based, same clock as system).
    /// Virtual devices don't need drift compensation in aggregate devices.
    private func isVirtualDevice(_ deviceID: AudioDeviceID) -> Bool {
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &size, &transportType)
        guard status == noErr else { return false }

        // kAudioDeviceTransportTypeVirtual = 'virt'
        // kAudioDeviceTransportTypeAggregate = 'grup'
        // These run on the system clock, not their own hardware clock.
        return transportType == kAudioDeviceTransportTypeVirtual
            || transportType == kAudioDeviceTransportTypeAggregate
    }

    /// Get the device's hardware latency in frames.
    private func getDeviceLatency(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyLatency,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var latency: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &latency)
        return latency
    }

    /// Get the device's safety offset in frames (additional latency Apple adds for stability).
    private func getDeviceSafetyOffset(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertySafetyOffset,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var offset: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &offset)
        return offset
    }

    private func destroyAggregateDevice() {
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }

    // MARK: - Core Audio Helpers

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid?.takeUnretainedValue() as String?
    }

    private func coreAudioDeviceID(forAVCaptureUID uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices)

        for device in devices {
            if let uid = deviceUID(for: device), uid == uniqueID {
                return device
            }
        }

        return nil
    }

    /// Finds the HDMI/DisplayPort audio output device ID for a given display.
    static func hdmiAudioDeviceID(for displayID: CGDirectDisplayID) -> AudioDeviceID? {
        let outputs = allOutputDevices()
        // Prefer exact HDMI/DP transport match
        return outputs.first { $0.isHDMI }?.id ?? outputs.first?.id
    }

    static func allOutputDevices() -> [(id: AudioDeviceID, name: String, isHDMI: Bool)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices)

        var results: [(id: AudioDeviceID, name: String, isHDMI: Bool)] = []

        for device in devices {
            // Check output channels
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outputSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(device, &outputAddress, 0, nil, &outputSize)
            guard status == noErr, outputSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            AudioObjectGetPropertyData(device, &outputAddress, 0, nil, &outputSize, bufferListPtr)

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let outputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard outputChannels > 0 else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &cfName)
            let name = (cfName?.takeUnretainedValue() as String?) ?? "Unknown"

            // Transport type
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transportType)

            let isHDMI = transportType == kAudioDeviceTransportTypeHDMI
                || transportType == kAudioDeviceTransportTypeDisplayPort
                || name.lowercased().contains("hdmi")
                || name.lowercased().contains("displayport")

            results.append((id: device, name: name, isHDMI: isHDMI))
        }

        return results
    }

    // MARK: - Audio Routing Recovery

    /// Start a timer that checks for render callback errors.
    /// When the aggregate device is destroyed by the system (GPU purge, device disconnect),
    /// the render callback returns errors. After enough consecutive errors, we restart routing.
    private func startAudioHealthCheck() {
        stopAudioHealthCheck()
        audioRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRouting else { return }
                if self._renderErrorCount > 10 {
                    print("[Audio] Render errors detected (\(self._renderErrorCount)), restarting routing")
                    self._renderErrorCount = 0
                    self.restartRouting()
                }
            }
        }
    }

    private func stopAudioHealthCheck() {
        audioRecoveryTimer?.invalidate()
        audioRecoveryTimer = nil
    }

    // MARK: - Level Metering (called from render callback)

    /// Called from the real-time audio thread ~6 times/sec (every 32nd callback).
    /// Dispatches to main thread for SwiftUI update.
    nonisolated func updateLevel(_ rms: Float) {
        _pendingLevel = rms
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inputLevel = self._pendingLevel
        }
    }

    // MARK: - Device Observation

    private func observeDeviceChanges() {
        let connectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMicList()
            }
        }

        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMicList()
            }
        }

        deviceObservers = [connectObserver, disconnectObserver]
    }
}

// MARK: - Audio Passthrough Callback (C function, nonisolated)

/// This C callback is invoked by the AudioUnit on the real-time audio thread.
/// It pulls audio from the input bus (mic) and passes it through to the output bus (HDMI).
/// Since we set Float32 non-interleaved format on both sides, the data is always Float32.
/// Zero processing — just a direct passthrough for minimum latency.
///
/// Level metering is throttled to every 8th callback to minimize real-time thread overhead.
nonisolated private func audioPassthroughCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let manager = Unmanaged<AudioManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let unit = manager.audioUnit else { return noErr }
    guard let ioData else { return noErr }

    // Pull audio from input bus (bus 1 = mic via aggregate device)
    let status = AudioUnitRender(
        unit,
        ioActionFlags,
        inTimeStamp,
        1, // Input bus
        inNumberFrames,
        ioData
    )

    guard status == noErr else {
        // Track consecutive errors — the health check timer will restart routing
        manager._renderErrorCount &+= 1
        return status
    }

    // Reset error count on success
    manager._renderErrorCount = 0

    // Level metering — only when menu popover is visible.
    // Skips all RMS computation when hidden to save CPU.
    guard manager._meterEnabled else { return noErr }
    manager._meterCounter &+= 1
    // With small buffers (64 samples), callbacks fire ~750/sec at 48kHz.
    // Mask 0xFF = every 256th callback ≈ ~3 updates/sec — smooth enough for a meter.
    if manager._meterCounter & 0xFF == 0 {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        if let firstBuffer = buffers.first, let data = firstBuffer.mData {
            let floatData = data.assumingMemoryBound(to: Float.self)
            let count = min(Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size,
                           Int(inNumberFrames))
            var sum: Float = 0
            var i = 0
            let count4 = count & ~3
            while i < count4 {
                let s0 = floatData[i]
                let s1 = floatData[i + 1]
                let s2 = floatData[i + 2]
                let s3 = floatData[i + 3]
                sum += s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3
                i += 4
            }
            while i < count {
                let s = floatData[i]
                sum += s * s
                i += 1
            }
            let rms = sqrt(sum / Float(max(count, 1)))
            manager.updateLevel(rms)
        }
    }

    return noErr
}
