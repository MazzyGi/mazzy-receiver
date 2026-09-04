import Foundation
import AppKit
import Carbon.HIToolbox
import MazzyCore

/// Maps keyboard events to DualSense button bits + stick values and ships
/// them to the daemon at a fixed rate.
final class KeyboardInput {
    private(set) var buttons: UInt32 = 0
    private(set) var lx: Int = 0, ly: Int = 0, rx: Int = 0, ry: Int = 0
    private var sendTimer: Timer?

    var onState: ((UInt32, Int, Int, Int, Int) -> Void)?

    // key codes -> buttons (WASD move, arrows dpad, etc.)
    private let map: [UInt16: (UInt32, Bool)] = [
        UInt16(kVK_ANSI_X):        (ControllerButton.cross.rawValue, true),
        UInt16(kVK_ANSI_C):        (ControllerButton.moon.rawValue, true),
        UInt16(kVK_ANSI_Z):        (ControllerButton.box.rawValue, true),
        UInt16(kVK_ANSI_V):        (ControllerButton.pyramid.rawValue, true),
        UInt16(kVK_ANSI_A):        (ControllerButton.l1.rawValue, true),
        UInt16(kVK_ANSI_S):        (ControllerButton.r1.rawValue, true),
        UInt16(kVK_Return):        (ControllerButton.options.rawValue, true),
        UInt16(kVK_Space):         (ControllerButton.cross.rawValue, true),
        UInt16(kVK_Escape):        (ControllerButton.share.rawValue, true),
        UInt16(kVK_UpArrow):       (ControllerButton.dpadUp.rawValue, true),
        UInt16(kVK_DownArrow):     (ControllerButton.dpadDown.rawValue, true),
        UInt16(kVK_LeftArrow):     (ControllerButton.dpadLeft.rawValue, true),
        UInt16(kVK_RightArrow):    (ControllerButton.dpadRight.rawValue, true),
    ]

    func attach(to window: NSWindow) {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
        // 60Hz sender
        sendTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onState?(self.buttons, self.lx, self.ly, self.rx, self.ry)
        }
    }

    private func handle(_ event: NSEvent) {
        guard let (bit, press) = map[event.keyCode] else { return }
        if event.type == .keyDown && press {
            buttons |= bit
        } else {
            buttons &= ~bit
        }
    }
}
