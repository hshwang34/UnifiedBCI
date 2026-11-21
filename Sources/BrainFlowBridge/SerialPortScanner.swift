import Foundation
import IOKit
import IOKit.serial

/// One serial device the Connect sheet can offer. `path` is the `/dev/cu.*` callout device,
/// the one to open for an outgoing connection (`/dev/tty.*` waits for carrier detect).
public struct SerialPort: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    /// From the USB device above the serial service, when there is one (the OpenBCI dongle
    /// is an FTDI USB-serial bridge). Bluetooth and built-in ports have none.
    public let vendorName: String?
    public let productName: String?
    public let isUSB: Bool

    public init(path: String, vendorName: String? = nil, productName: String? = nil, isUSB: Bool = false) {
        self.path = path
        self.vendorName = vendorName
        self.productName = productName
        self.isUSB = isUSB
    }
}

/// Lists serial ports from IOKit (`IOSerialBSDServices`), not by globbing `/dev`, so names
/// come with the USB vendor/product strings. Synchronous and cheap; call it off the main
/// actor anyway, IOKit registry walks can stall while a device is being enumerated.
public enum SerialPortScanner {
    public static func scan() -> [SerialPort] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [SerialPort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = string(service, kIOCalloutDeviceKey, searchParents: false),
                  path.hasPrefix("/dev/cu.") else { continue }
            let vendor = string(service, "USB Vendor Name", searchParents: true)
            let hasVendorID = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString,
                                                              kCFAllocatorDefault, parentSearch) != nil
            ports.append(SerialPort(path: path, vendorName: vendor,
                                    productName: string(service, "USB Product Name", searchParents: true),
                                    isUSB: hasVendorID || vendor != nil))
        }
        return ordered(ports)
    }

    /// USB-serial devices first (the dongle is one), then by path; stable for a refresh.
    public static func ordered(_ ports: [SerialPort]) -> [SerialPort] {
        ports.sorted { a, b in a.isUSB != b.isUSB ? a.isUSB : a.path < b.path }
    }

    private static let parentSearch = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)

    private static func string(_ service: io_object_t, _ key: String, searchParents: Bool) -> String? {
        let value = searchParents
            ? IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, parentSearch)
            : IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return value as? String
    }
}
