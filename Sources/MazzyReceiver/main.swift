import Foundation
import AppKit
import MazzyCore

// line-buffer stdout so logs survive when the process is killed (CI smoke test)
setvbuf(stdout, nil, _IOLBF, 0)

let configPath = NSString(string: "~/.mazzy-receiver.json").expandingTildeInPath
var config = ReceiverConfig.load(path: configPath)

var args = Array(CommandLine.arguments.dropFirst())
var headless = false
while !args.isEmpty {
    switch args.removeFirst() {
    case "--host": config.host = args.isEmpty ? config.host : args.removeFirst()
    case "--no-stats": config.showStatsOverlay = false
    case "--headless": headless = true
    case "--save-config": config.save(to: configPath); print("saved \(configPath)")
    default: break
    }
}

print("MazzyReceiver -> \(config.host)")
print("video udp:\(config.videoPort) audio udp:\(config.audioPort) tcp:\(config.tcpPort)")

let receiver = Receiver(config: config)

if headless {
    receiver.start()
    withExtendedLifetime(receiver) {
        dispatchMain()  // never returns
    }
    exit(0)
}

// GUI mode -------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.regular)

guard let renderer = MetalRenderer(config: config) else {
    print("[gui] Metal unavailable - falling back to headless")
    receiver.run()
    withExtendedLifetime(receiver) {}
    exit(0)
}
let audio = AudioPlayer(config: config)
audio.start()

receiver.onFrame = { frame in renderer.present(frame: frame) }
receiver.onAudio = { data in audio.feed(data) }

// keyboard -> controller
let keyboard = KeyboardInput()
keyboard.onState = { buttons, lx, ly, rx, ry in
    receiver.sendController(buttons: buttons, lx: lx, ly: ly, rx: rx, ry: ry)
}

// HUD
var hud: HudOverlay?
if config.showStatsOverlay {
    hud = HudOverlay(parent: NSApplication.shared.windows.first?.contentView ?? NSView())
    Timer.scheduledTimer(withTimeInterval: Double(config.statsOverlayIntervalMs) / 1000.0, repeats: true) { _ in
        hud?.update(lines: receiver.statsLines())
    }
}

receiver.start()

let window = NSApplication.shared.windows.first
keyboard.attach(to: window ?? NSWindow())

app.run()
