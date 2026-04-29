import AppKit
import CoreGraphics

func displayUUID(for screen: NSScreen) -> String? {
    guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
    let vendor = CGDisplayVendorNumber(screenNumber)
    let model  = CGDisplayModelNumber(screenNumber)
    let serial = CGDisplaySerialNumber(screenNumber)
    return String(format: "%08X-%08X-%08X", vendor, model, serial)
}
