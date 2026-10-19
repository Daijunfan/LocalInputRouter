import AppKit
import IOBluetooth
final class Probe: NSObject, NSApplicationDelegate, IOBluetoothRFCOMMChannelDelegate {
    var window: NSWindow!
    let label = NSTextField(wrappingLabelWithString: "正在建立蓝牙测试连接…")
    var channel: IOBluetoothRFCOMMChannel?
    var device: IOBluetoothDevice?
    var payloadSize = 32
    var phaseResults: [[String: Any]] = []
    var received = Data(), sentAt = 0.0, samples: [Double] = [], finished = false
    var output = ""
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 430,height: 145),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.title = "DJF 蓝牙链路测试"; window.center()
        label.frame = NSRect(x: 20,y: 30,width: 390,height: 85); window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        do {
            let url = Bundle.main.url(forResource: "ProbeConfig",withExtension: "json")!
            let c = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            output = c["output"] as! String
            guard let device = IOBluetoothDevice(addressString: c["address"] as! String) else { finish(["error":"Unknown device"]); return }
            self.device = device
            let status = device.openRFCOMMChannelAsync(&channel, withChannelID: UInt8(c["channel"] as! Int), delegate: self)
            if status != kIOReturnSuccess { finish(["connected":false,"error":String(format:"0x%08x",status)]); return }
            Timer.scheduledTimer(withTimeInterval: 45,repeats: false) { [weak self] _ in self?.finish(["connected":false,"error":"Bluetooth connection timed out"]) }
        } catch { finish(["error":error.localizedDescription]) }
    }
    func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error != kIOReturnSuccess { finish(["connected":false,"error":String(format:"0x%08x",error)]); return }
        channel=c; label.stringValue="已连接，仅测试固定字节往返延迟。"; send()
    }
    func send() {
        guard !finished, let channel else { return }
        received.removeAll(); var bytes=[UInt8](repeating: UInt8(samples.count % 256),count:payloadSize)
        sentAt=ProcessInfo.processInfo.systemUptime
        let status=bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress,length:UInt16($0.count)) }
        if status != kIOReturnSuccess { finish(["error":"Bluetooth write failed"]); }
    }
    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard !finished else { return }
        received.append(pointer.assumingMemoryBound(to: UInt8.self),count:count)
        guard received.count>=payloadSize else { return }
        guard received==Data(repeating:UInt8(samples.count % 256),count:payloadSize) else { finish(["error":"Echo mismatch"]); return }
        samples.append((ProcessInfo.processInfo.systemUptime-sentAt)*1000)
        if samples.count==160 {
            let sorted=Array(samples.dropFirst(5)).sorted()
            phaseResults.append(["bytes":payloadSize,"samples":sorted.count,"medianMs":sorted[sorted.count/2],"p95Ms":sorted[Int(Double(sorted.count)*0.95)],"maxMs":sorted.last!])
            if payloadSize == 32 { payloadSize = 512; samples.removeAll(); DispatchQueue.main.asyncAfter(deadline:.now()+0.05){self.send()}; return }
            finish(["connected":true,"paired":device?.isPaired() ?? false,"encryptionMode":device?.getEncryptionMode() ?? 0,"phases":phaseResults]);return
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.005){self.send()}
    }
    func finish(_ result:[String:Any]) {
        guard !finished else { return }; finished=true;channel?.close();channel=nil
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {
            if !output.isEmpty {try? data.write(to:URL(fileURLWithPath:output))}
            label.stringValue=String(decoding:data,as:UTF8.self)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let app=NSApplication.shared
let probe=Probe();app.delegate=probe;app.setActivationPolicy(.accessory);app.run()
