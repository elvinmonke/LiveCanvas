```
 ╦  ╦╦  ╦╔═╗╔═╗╔═╗╔╗╔╦  ╦╔═╗╔═╗
 ║  ║╚╗╔╝║╣ ║  ╠═╣║║║╚╗╔╝╠═╣╚═╗
 ╩═╝╩ ╚╝ ╚═╝╚═╝╩ ╩╝╚╝ ╚╝ ╩ ╩╚═╝
       live wallpapers for macOS
```

**Website:** [trylivecanvas.vercel.app](https://trylivecanvas.vercel.app)

---

```
┌─────────────────────────────────────────────────────┐
│ ~ LiveCanvas v1.0.0                            [x]  │
│─────────────────────────────────────────────────────│
│                                                     │
│   ┌───────────────────────────────────────┐         │
│   │  ▶  ocean-waves.mp4       ▮▮ 00:32   │         │
│   │     ████████████░░░░░░░░░░░░░░░░░░░   │         │
│   │                                       │         │
│   │  Display 1: Built-in Retina           │         │
│   │  Display 2: LG UltraFine             │         │
│   │  Battery:   Paused on battery ⚡      │         │
│   └───────────────────────────────────────┘         │
│                                                     │
│   [Select Video]  [Pause]  [Settings]               │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Features

- **Live Video Wallpapers** -- Play any video file as your desktop background
- **Multi-Display Support** -- Independent wallpapers per monitor
- **Minimal UI** -- Lightweight menu bar app, stays out of your way
- **Battery-Aware** -- Automatically pauses playback on battery power

---

## How It Works

```
┌──────────────────────────────────────────────────┐
│                  Architecture                    │
│                                                  │
│   ┌─────────────┐    spawn    ┌──────────────┐   │
│   │  LiveCanvas  │ ────────── │  wallpaper    │   │
│   │  (Main App)  │            │  daemon       │   │
│   │              │  IPC/XPC   │              │   │
│   │  - GUI       │ ◄────────► │  - AVPlayer   │   │
│   │  - Settings  │            │  - Window Mgr │   │
│   │  - Tray Icon │            │  - Rendering  │   │
│   └─────────────┘            └──────┬───────┘   │
│                                     │            │
│                              inject below        │
│                              desktop icons       │
│                                     │            │
│                              ┌──────▼───────┐   │
│                              │   Desktop     │   │
│                              │   (layer -1)  │   │
│                              └──────────────┘   │
└──────────────────────────────────────────────────┘
```

The main app provides the user interface and spawns a lightweight Objective-C
daemon that handles video decoding and rendering. The daemon creates a
borderless window pinned beneath desktop icons using `NSWindow.Level` tricks,
then drives an `AVPlayerLayer` to render video frames directly to the GPU.

---

## Build

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
# one-step build
chmod +x build.sh
./build.sh

# or manually
xcodegen generate
xcodebuild -project LiveCanvas.xcodeproj \
           -scheme LiveCanvas \
           -configuration Release build
```

Or open `LiveCanvas.xcodeproj` in Xcode after running `xcodegen generate`.

---

## Installation

```bash
# copy to Applications
cp -r build/Release/LiveCanvas.app /Applications/

# or run directly
open build/Release/LiveCanvas.app
```

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ / Swift 5.9
- XcodeGen (for project generation)

---

## License

MIT
