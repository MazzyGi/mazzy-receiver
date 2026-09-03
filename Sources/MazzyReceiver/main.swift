import Foundation
import MazzyCore

// headless-ish receiver for now: connects, decodes, prints stats.
// Metal window comes in the next step.

let configPath = NSString(string: "~/.mazzy-receiver.json").expandingTildeInPath
var config = ReceiverConfig.load(path: configPath)

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--host": config.host = args.isEmpty ? config.host : args.removeFirst()
    case "--no-stats": config.showStatsOverlay = false
    case "--save-config": config.save(to: configPath); print("saved \(configPath)")
    default: break
    }
}

print("MazzyReceiver -> \(config.host)")
print("video udp:\(config.videoPort) audio udp:\(config.audioPort) tcp:\(config.tcpPort)")

let receiver = Receiver(config: config)
receiver.run()

// kept alive by receiver.run() until Ctrl-C
withExtendedLifetime(receiver) {}
