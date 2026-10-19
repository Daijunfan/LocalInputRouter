import Foundation
import IOBluetooth
import Darwin

/// OpenSSH ProxyCommand: stdin/stdout carry only the encrypted SSH byte stream.
final class BluetoothPipe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?
    private var opened = false

    func start(address: String, channelID: UInt8) {
        signal(SIGPIPE, SIG_IGN)
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
            fail("DJF-Windows is not paired with this Mac")
        }
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        if result != kIOReturnSuccess { fail("Cannot open Bluetooth channel: \(result)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [self] in
            if !opened { fail("Bluetooth connection timed out") }
        }
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == kIOReturnSuccess else { fail("Bluetooth connection failed: \(status)") }
        self.channel = channel; opened = true
        let size = min(1024, Int(channel.getMTU()))
        guard size > 0 else { fail("Invalid Bluetooth MTU") }
        // Read one MTU at a time. Wait for its write before reading more, so
        // a slow radio cannot accumulate an unbounded queue of input events.
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            var bytes = [UInt8](repeating: 0, count: size)
            while true {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { DispatchQueue.main.async { self.finish(count == 0 ? 0 : 1) }; return }
                let payload = Data(bytes.prefix(count))
                let written = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { [self] in
                    var copy = payload
                    let result = copy.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
                    if result != kIOReturnSuccess { fail("Bluetooth write failed: \(result)") }
                    written.signal()
                }
                written.wait()
            }
        }
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        var offset = 0
        while offset < length {
            let count = Darwin.write(STDOUT_FILENO, pointer.advanced(by: offset), length - offset)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { finish(1) }
            offset += count
        }
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) { finish(0) }
    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8)); finish(1)
    }
    private func finish(_ code: Int32) -> Never { Darwin.exit(code) }
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let channel = UInt8(arguments[2]), (1...30).contains(channel) else { exit(2) }
let pipe = BluetoothPipe()
pipe.start(address: arguments[1], channelID: channel)
RunLoop.main.run()
