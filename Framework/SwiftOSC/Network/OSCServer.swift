//
//  OSCServer.swift
//  SwiftOSC
//
//  Created by Devin Roth on 6/26/16.
//  Copyright © 2019 Devin Roth Music. All rights reserved.
//

import Foundation
import Network
import OSLog

public class OSCServer {
    
    public weak var delegate: OSCDelegate?
    
    public var listener: NWListener?
    public private(set) var port: NWEndpoint.Port
    public private(set) var name: String?
    public private(set) var domain: String?
    public private(set) var queue: DispatchQueue = DispatchQueue(label: "SwiftOSC Server", qos: .userInteractive)
    public var connection: NWConnection?
    /// When this flag is set, the server uses delegate method didReceive(_:port:) instead of didReceive(_:)
    public private(set) var indicatesPort: Bool

    /// POSIX receive socket (bound to INADDR_ANY) and its read source. See setupListener().
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    
    // TODO: why does init have to be failing?
    public init?(port: UInt16, bonjourName: String? = nil, delegate: OSCDelegate? = nil, domain: String? = nil, indicatesPort: Bool = false) {
        
        self.delegate = delegate
        self.domain = domain
        
        if let bonjourName = bonjourName {
            self.name = bonjourName
        }
        
        self.port = NWEndpoint.Port(integerLiteral: port)
        self.indicatesPort = indicatesPort
        
        setupListener()
    }
    
    private func setupListener() {

        // Receive OSC on a plain POSIX UDP socket bound to INADDR_ANY, instead
        // of Network.framework's NWListener. NWListener does not surface UDP
        // datagrams that arrive on a secondary interface such as a USB-C
        // CDC-NCM link: the handshake reply reaches the device over the cable
        // but the app never sees it (verified by on-cable tcpdump, 2026-10-28).
        // A socket bound to 0.0.0.0 accepts datagrams on EVERY interface
        // unconditionally, so it works over Wi-Fi exactly as before AND over
        // the USB link. (This server never advertises Bonjour -- the app only
        // browses -- so NWListener's service feature was unused here anyway.)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 {
            os_log("Server '%{Public}@': failed to create socket, errno %{Public}@", log: SwiftOSCLog, type: .error, self.name ?? "<noName>", String(errno))
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking so the read handler can drain every queued datagram per
        // fire (the meter stream is high-rate) without ever blocking the queue.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = 0 // INADDR_ANY -- all interfaces
        addr.sin_port = port.rawValue.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            os_log("Server '%{Public}@': failed to bind port %{Public}@, errno %{Public}@", log: SwiftOSCLog, type: .error, self.name ?? "<noName>", String(describing: self.port), String(errno))
            close(fd)
            return
        }

        self.socketFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n > 0 {
                    self.decodePacket(Data(buffer[0..<Int(n)]))
                } else {
                    break
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        self.readSource = source
        source.resume()

        os_log("Server '%{Public}@': Ready, listening on UDP port %{Public}@ (POSIX, all interfaces), delegate: %{Public}@", log: SwiftOSCLog, type: .default, self.name ?? "<noName>", String(describing: self.port), delegateDescription())
    }
    
    /// No-op. Reads are driven by the POSIX DispatchSource created in
    /// setupListener(); kept for API compatibility.
    public func receive() {}
    
    func decodePacket(_ data: Data){
        
        // FIXME: What is GCD doing here on 'main'?
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.delegate?.didReceive(data)
        }
        
        if data[0] == 0x2f { // check if first character is "/"
            if let message = decodeMessage(data) {
                // print(message)
                self.sendToDelegate(message)
            }
            
        } else if data.count > 8 { /// make sure we have at least 8 bytes before checking if a bundle.
            if "#bundle\0".toData() == data.subdata(in: Range(0...7)) { // matches string #bundle
                if let bundle = decodeBundle(data){
                    self.sendToDelegate(bundle)
                }
            }
        } else {
            os_log("Invalid OSCPacket: data must begin with #bundle\\0 or /", log: SwiftOSCLog, type: .error)
        }
    }
    
    func decodeBundle(_ data: Data)->OSCBundle? {
        
        /// extract timetag
        let bundle = OSCBundle(OSCTimetag(data.subdata(in: 8..<16)))
        
        var bundleData = data.subdata(in: 16..<data.count)
        
        while bundleData.count > 0 {
            let length = Int(bundleData.subdata(in: Range(0...3)).toInt32())
            let nextData = bundleData.subdata(in: 4..<length+4)
            bundleData = bundleData.subdata(in:length+4..<bundleData.count)
            // SwiftOSC isssue OSCServer crashes #52
            // it's not a proper fix since you can have a bundle in a bundle
//            if "#bundle\0".toData() == nextData.subdata(in: Range(0...7)){//matches string #bundle
//                if let newbundle = self.decodeBundle(nextData){
//                    bundle.add(newbundle)
//                } else {
//                    return nil
//                }
//            } else if nextData[0] == 0x2f { // matches /
                
                if let message = self.decodeMessage(nextData) {
                    bundle.add(message)
                } else {
                    return nil
                }
//            } else {
//            os_log("Invalid OSCPacket: data must begin with #bundle\\0 or /", log: SwiftOSCLog, type: .error)
//                return nil
//            }
        }
        return bundle
    }
    
    func decodeMessage(_ data: Data)->OSCMessage?{
        var messageData = data
        var message: OSCMessage
        
        /// extract address and check if valid
        if let addressEnd = messageData.firstIndex(of: 0x00){
            
            let addressString = messageData.subdata(in: 0..<addressEnd).toString()
            if let address = OSCAddressPattern(addressString) {
                message = OSCMessage(address)
                
                /// extract types
                messageData = messageData.subdata(in: (addressEnd/4+1)*4..<messageData.count)
                
                /// message may not contain arguments
                guard let typeEnd = messageData.firstIndex(of: 0x00) else {
                    os_log("Server: Invalid OSCMessage: Missing type terminator. Address: %{Public}@", log: SwiftOSCLog, type: .error, message.address.string)
                    return message
                }
                let type = messageData.subdata(in: 1..<typeEnd).toString()
                
                messageData = messageData.subdata(in: (typeEnd/4+1)*4..<messageData.count)
                
                for char in type {
                    switch char {
                    case "i": /// int
                        message.add(Int(messageData.subdata(in: Range(0...3))))
                        messageData = messageData.subdata(in: 4..<messageData.count)
                    case "f": /// float
                        message.add(Float(messageData.subdata(in: Range(0...3))))
                        messageData = messageData.subdata(in: 4..<messageData.count)
                    case "s": /// string
                        let stringEnd = messageData.firstIndex(of: 0x00)!
                        message.add(String(messageData.subdata(in: 0..<stringEnd)))
                        messageData = messageData.subdata(in: (stringEnd/4+1)*4..<messageData.count)
                    case "b": /// blob
                        var length = Int(messageData.subdata(in: Range(0...3)).toInt32())
                        messageData = messageData.subdata(in: 4..<messageData.count)
                        message.add(OSCBlob(messageData.subdata(in: 0..<length)))
                        while length%4 != 0 {//remove null ending
                            length += 1
                        }
                        messageData = messageData.subdata(in: length..<messageData.count)
                    case "T": /// true
                        message.add(true)
                    case "F": /// false
                        message.add(false)
                    case "N": /// null
                        message.add()
                    case "I": /// impulse
                        message.add(OSCImpulse())
                    case "t": /// timetag
                        message.add(OSCTimetag(messageData.subdata(in: Range(0...7))))
                        messageData = messageData.subdata(in: 8..<messageData.count)
                    default:
                        os_log("Invalid OSCMessage: Unknown OSC type.", log: SwiftOSCLog, type: .error)
                        return nil
                    }
                }
            } else {
                os_log("Invalid OSCMessage: Invalid address.", log: SwiftOSCLog, type: .error)
                return nil
            }
            return message
        } else {
            os_log("Invalid OSCMessage: Missing address terminator", log: SwiftOSCLog, type: .error)
            return nil
        }
    }
    
    func sendToDelegate(_ element: OSCElement){
        
        // FIXME: What is GCD doing here on 'main'?
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let message = element as? OSCMessage {
                // FIXME: Probably `indicatesPort` is not necessary, delegate methods are optional
                if self.indicatesPort {
                    self.delegate?.didReceive(message, port: self.port)
                } else {
                    self.delegate?.didReceive(message)
                }
            }
            
            if let bundle = element as? OSCBundle {
                
                /// send to delegate at the correct time
                if bundle.timetag.secondsSinceNow < 0 {
                    if self.indicatesPort {
                        self.delegate?.didReceive(bundle, port: self.port)
                    } else {
                        self.delegate?.didReceive(bundle)
                    }
                    for element in bundle.elements {
                        self.sendToDelegate(element)
                    }
                } else {
                    // FIXME: What is GCD doing here on 'main'?
                    DispatchQueue.main.asyncAfter(deadline: .now() + bundle.timetag.secondsSinceNow, execute: { [weak self] in
                        guard let self = self else { return }
                        if self.indicatesPort {
                            self.delegate?.didReceive(bundle, port: self.port)
                        } else {
                            self.delegate?.didReceive(bundle)
                        }
                        for element in bundle.elements {
                            self.sendToDelegate(element)
                        }
                    })
                }
            }
        }
    }
    
    /// cancel the receive socket (and any legacy NWListener/connection)
    public func stop() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }
    
    /// cancel conection and listener, then start with refreshed settings
    public func restart() {
        stop()
        
        /// setup new listener
        setupListener()
    }
}

extension OSCServer {
    /// This string dance serves the mere purpose of avoiding ugly "Optional(<someClassName>)" in log.
    func delegateDescription() -> String {
        if let delegate = self.delegate {
            return String(describing: delegate)
        } else {
            return "<none>"
        }
    }
}
