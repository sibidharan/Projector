# Projector

A lightweight macOS menu bar app that projects any camera + audio source to an external display over HDMI.

Built for video production workflows using capture cards — bringing clock-synced audio and video from any source into HDMI, right from the menu bar.

## What it does

- Pick any Mac camera (capture cards, virtual cameras, built-in) and send its video fullscreen to any external display
- Route any audio source (microphone, camera audio, virtual audio) to the HDMI output with ultra-low latency
- Clock-synced audio and video — input device is the clock master, so lip sync just works
- Lives in the menu bar — no dock icon, no windows in the way

## Use cases

- **Capture card passthrough** — Feed HDMI/SDI into a capture card (JoyCast, Elgato, BlackMagic), project it back out to a monitor or projector
- **Virtual camera output** — Send OBS Virtual Camera, Boom Camera, or any virtual camera to an external display
- **Confidence monitor** — Show a camera feed on a stage monitor during live production
- **Simple signage** — Project a camera feed to a TV or display

## Features

**Video**
- AVCaptureVideoPreviewLayer — Apple's zero-copy GPU rendering path
- Camera format picker — resolution, frame rate, codec
- Automatic best-format selection (prefers formats without system video effects)
- Auto-disables Center Stage to avoid frame drops
- Session watchdog — auto-restarts on capture card stalls

**Audio**
- Aggregate Device audio routing — combines any input + HDMI output into one device
- 64-sample buffer size (~1.3ms at 48kHz)
- Input device as clock master — minimum input latency, output adapts via drift compensation
- Camera audio detection — finds companion audio on capture cards (matched by modelID)
- Virtual device detection — skips drift compensation for software sources (same system clock)
- Channel count matching — avoids expensive multi-channel mixdown
- Live audio level meter in the menu bar
- Audio health check — auto-restarts routing on errors

**Display**
- External display picker
- Display mode/resolution selector
- Projection window is excluded from Mission Control, Expose, and window cycling — it stays fullscreen on the external display no matter what
- Mirror-set handling — auto-breaks mirroring for independent output
- Mouse confinement — keeps cursor on the primary display

**Recovery**
- Auto-recovers from macOS Mission Control GPU purge events
- Session detach/reattach recovery after space changes
- Health check monitoring for connection state

## Requirements

- macOS 15.0+ (Sequoia)
- Apple Silicon or Intel Mac
- External display connected via HDMI/DisplayPort/USB-C
- Camera permissions
- Microphone permissions (for audio routing)

## Build

```
git clone https://github.com/sibidharan/Projector.git
cd Projector
open Projector.xcodeproj
```

Build and run from Xcode. The app appears in the menu bar.

## Architecture

```
ProjectorApp.swift          → App entry point, menu bar setup
MenuBarView.swift           → SwiftUI menu bar UI (INPUT/OUTPUT sections)
CameraManager.swift         → AVCaptureSession, camera enumeration, format config
DisplayManager.swift        → External display enumeration, mode management
AudioManager.swift          → Aggregate device, HAL AudioUnit, audio routing
ProjectionWindowController.swift → Borderless fullscreen window, preview layer
CameraPreviewView.swift     → Menu bar camera preview (NSViewRepresentable)
```

## How it works

**Video pipeline:**
Camera → AVCaptureSession → AVCaptureVideoPreviewLayer → Fullscreen NSWindow on external display

**Audio pipeline:**
Mic/Camera Audio → Aggregate Device (input as clock master) → HAL AudioUnit render callback → HDMI output

The audio and video pipelines are independent. The audio uses the input device as clock master so the capture timing drives everything — HDMI output adapts via drift compensation. This gives the lowest possible input-to-output latency with perfect lip sync.

## License

MIT
