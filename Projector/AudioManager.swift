//
//  AudioManager.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//
//  Low-latency audio passthrough from microphone to HDMI output.
//
//  Architecture:
//  ─────────────
//  1. Create an Aggregate Device combining mic (input) + HDMI (output)
//     with drift compensation enabled for clock synchronization.
//  2. Set the smallest possible I/O buffer size on both devices.
//  3. HAL AudioUnit with a lightweight render callback that pulls mic data
//     from bus 1 and passes it through to bus 0 (HDMI). Zero processing —
//     just a direct passthrough for minimum latency.
//  4. Level metering is throttled to every 32nd callback (~6/sec at 256 samples)
//     and quantized to 8 visual steps — only triggers SwiftUI redraw when the
//     visible bar count actually changes. Uses coalesced DispatchQueue instead
//     of per-update Task allocations.
//  5. Virtual mic detection — skips drift compensation for software mics
//     (BoomAudio, OBS, BlackHole) since they share the system clock.
//  6. Channel count matching — uses min(input, output) channels to avoid
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

    // We need to store both the aggregate device and the current output device
    // so we can restart routing when the mic changes
    nonisolated(unsafe) var audioUnit: AudioUnit?
    private var aggregateDeviceID: AudioDeviceID = 0
    private var currentOutputDeviceID: AudioDeviceID = 0
    private var deviceObservers: [NSObjectProtocol] = []

    // Level metering — throttle counter (accessed on audio thread)
    nonisolated(unsafe) var _meterCounter: Int32 = 0
    // Coalesce level updates to main thread — avoid spawning Task per update
    nonisolated(unsafe) var _pendingLevelUpdate = false
    nonisolated(unsafe) var _pendingLevel: Float = 0
    // Track last quantized level to skip no-op UI updates
    nonisolated(unsafe) var _lastQuantizedLevel: Int32 = -1

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
        availableMics = discovery.devices

        if selectedMic == nil, let first = availableMics.first {
            selectedMic = first
        }
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

        // Check if input is a virtual device (same machine = same clock = no drift)
        let isVirtualInput = isVirtualDevice(inputDeviceID)
        print("[Audio] Input device: \(mic.localizedName) (UID: \(inputUID), ID: \(inputDeviceID), virtual: \(isVirtualInput))")
        print("[Audio] Output device ID: \(outputDeviceID) (UID: \(outputUID))")

        // Step 1.5: Set minimum buffer size on both hardware devices
        setMinimumBufferSize(for: inputDeviceID)
        setMinimumBufferSize(for: outputDeviceID)

        // Step 2: Create an Aggregate Device combining input + output
        // Virtual devices (BoomAudio, OBS, etc.) share the system clock,
        // so drift compensation is unnecessary and adds latency.
        let aggregateResult = createAggregateDevice(
            inputUID: inputUID,
            outputUID: outputUID,
            enableDriftCompensation: !isVirtualInput
        )
        guard let aggDeviceID = aggregateResult else {
            routingError = "Cannot create aggregate device"
            return
        }
        self.aggregateDeviceID = aggDeviceID
        print("[Audio] Aggregate device created: \(aggDeviceID) (drift comp: \(!isVirtualInput))")

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
        isRouting = true

        // Log the achieved latency
        let bufferSize = getBufferSize(for: aggDeviceID)
        let latencyMs = Double(bufferSize) / sampleRate * 1000.0

        // Also query the device's stream latency for a complete picture
        let inputLatency = getDeviceLatency(for: inputDeviceID, scope: kAudioDevicePropertyScopeInput)
        let outputLatency = getDeviceLatency(for: outputDeviceID, scope: kAudioDevicePropertyScopeOutput)
        let totalLatencyMs = latencyMs + (Double(inputLatency + outputLatency) / sampleRate * 1000.0)
        print("[Audio] Routing started — buffer: \(bufferSize) samples (\(String(format: "%.1f", latencyMs))ms)")
        print("[Audio] Total estimated latency: \(String(format: "%.1f", totalLatencyMs))ms (buf: \(String(format: "%.1f", latencyMs))ms + device: \(inputLatency + outputLatency) frames)")
    }

    private func describeASBD(_ asbd: AudioStreamBasicDescription) -> String {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        return "\(asbd.mSampleRate)Hz, \(asbd.mChannelsPerFrame)ch, \(asbd.mBitsPerChannel)bit, \(isFloat ? "float" : "int"), \(isInterleaved ? "interleaved" : "non-interleaved")"
    }

    func stopRouting() {
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

    /// Set a low I/O buffer size on a device.
    /// 256 samples at 48kHz = ~5.3ms — very low latency.
    /// CPU overhead is manageable after the metering/Task optimizations.
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

        // Target 256 samples (~5.3ms at 48kHz) — low latency.
        // The CPU optimizations (coalesced dispatch, quantized metering,
        // reduced callback overhead) give us headroom for smaller buffers.
        var targetSize: UInt32 = 256
        if rangeStatus == noErr {
            targetSize = max(targetSize, UInt32(range.mMinimum))
            targetSize = min(targetSize, UInt32(range.mMaximum))
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
        // Drift compensation adds a resampling buffer for clock sync.
        // Virtual devices (BoomAudio, OBS, BlackHole) share the system
        // clock, so drift comp is unnecessary and adds ~1 buffer of latency.
        // Hardware mics have their own clock and DO need drift comp.
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Projector Audio Bridge",
            kAudioAggregateDeviceUIDKey as String: "com.projector.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: inputUID,
                    kAudioSubDeviceDriftCompensationKey as String: enableDriftCompensation
                ] as [String : Any],
                [
                    kAudioSubDeviceUIDKey as String: outputUID
                ] as [String : Any]
            ],
            kAudioAggregateDeviceMasterSubDeviceKey as String: outputUID
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

    // MARK: - Level Metering (called from render callback)

    /// Called from the real-time audio thread. Coalesces updates to avoid
    /// spawning a Task per callback — uses a single pending dispatch.
    /// Also quantizes to 8 visual steps so SwiftUI only redraws when
    /// the visible bar count actually changes.
    nonisolated func updateLevel(_ rms: Float) {
        // Quantize to 8 steps (matching the 8-bar display)
        let scaled = min(rms * 5, 1.0)
        let quantized = Int32(scaled * 8)
        // Skip if the visual output hasn't changed
        guard quantized != _lastQuantizedLevel else { return }
        _lastQuantizedLevel = quantized
        _pendingLevel = rms

        // Coalesce — only dispatch if no pending update
        guard !_pendingLevelUpdate else { return }
        _pendingLevelUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self._pendingLevelUpdate = false
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
        return status
    }

    // Throttled level metering — only compute RMS every 32nd callback
    // At 256 samples / 48kHz, each callback is ~5.3ms, so metering updates ~every 170ms (~6/sec)
    // Quantized to 8 steps so SwiftUI only redraws when the visible bar changes
    manager._meterCounter &+= 1
    if manager._meterCounter & 31 == 0 {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        if let firstBuffer = buffers.first, let data = firstBuffer.mData {
            let floatData = data.assumingMemoryBound(to: Float.self)
            let count = min(Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size,
                           Int(inNumberFrames))
            // Use Accelerate-style manual loop for RMS (no import needed)
            var sum: Float = 0
            var i = 0
            // Process 4 samples at a time for better pipelining
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
