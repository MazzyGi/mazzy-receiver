# MazzyReceiver

macOS receiver for the chiaki-relay daemon on OrangePi. Receives the PS5's
native H.264 + PCM over UDP, hardware-decodes via VideoToolbox, renders
with Metal (MetalFX upscaling / frame generation coming).

## Pipeline
```
OrangePi daemon ──UDP video──→ reassemble → VideoToolbox → Metal (+MetalFX)
                 ──UDP audio──→ AVAudioEngine playback
                 ──TCP control─→ keyboard → DualSense state → PS5
```

## Build & run
```
swift build -c release
.build/release/MazzyReceiver --host <orangepi-ip>
```

Config lives at `~/.mazzy-receiver.json` (auto-created defaults with
`--save-config`). Every latency/loss/upscale knob is in there.

## Tests
- `swift test` — unit tests (reassembler, H.264 parser, control protocol)
- `Scripts/smoke_test.py` — protocol smoke test against a fake daemon
