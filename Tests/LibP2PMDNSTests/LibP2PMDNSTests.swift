//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2025 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import DNS
import LibP2P
import Multiaddr
import NIO
import Network
import PeerID
import XCTest

@testable import LibP2PMDNS

final class LibP2PMDNSTests: XCTestCase {
    // Try and get our machines internal IP Address
    let internalIPAddress = try! System.enumerateDevices().first(where: { device in
        guard device.name == "en0" && device.address != nil else { return false }
        guard let ma = try? device.address?.toMultiaddr().tcpAddress else { return false }

        return ma.ip4
    }).map { try! $0.address!.toMultiaddr().tcpAddress!.address }!

    /// System.enumerateDevices
    func testSystemDevices() throws {
        for device in try! System.enumerateDevices() {
            print("Description: \(device)")
            print("Interface Index: \(device.interfaceIndex)")
            print("Name: \(device.name)")
            print("Address: \(String(describing: device.address))")
            print("Broadcast Address: \(String(describing: device.broadcastAddress))")
            print("Netmask: \(String(describing: device.netmask))")
        }
    }

    func testSystemDevicesEN0() throws {
        let devices = try System.enumerateDevices().filter({ device in
            guard device.name == "en0" && device.address != nil else { return false }
            guard let ma = try? device.address?.toMultiaddr().tcpAddress else { return false }

            return ma.ip4
        })
        for device in devices {
            print("Description: \(device)")
            print("Interface Index: \(device.interfaceIndex)")
            print("Name: \(device.name)")
            print("Address: \(try! device.address!.toMultiaddr().tcpAddress!.address)")
            print("Broadcast Address: \(String(describing: device.broadcastAddress))")
            print("Netmask: \(String(describing: device.netmask))")
        }
    }

    func testFixSameHostAddresses() {
        let hostIP4 = "192.168.1.21"
        let hostIP6 = "f4:d4:88:5c:bf:7b"
        let mas = [
            try! Multiaddr("/ip4/192.168.1.21/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            try! Multiaddr("/ip4/127.0.0.1/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            try! Multiaddr("/ip4/192.168.1.23/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            //try! Multiaddr("/ip6/f4:d4:88:5c:bf:7b/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            //try! Multiaddr("/ip6/b4:44:28:5d:af:7c/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV")
        ]

        let fixed = mas.compactMap { ma -> Multiaddr? in
            guard let addy = ma.addresses.first else { return nil }
            switch addy.codec {
            case .ip4:
                if addy.addr == hostIP4 {
                    do {
                        var new = try Multiaddr(.ip4, address: "127.0.0.1")
                        for proto in ma.addresses.dropFirst() {
                            new = try new.encapsulate(proto: proto.codec, address: proto.addr)
                        }
                        return new
                    } catch {
                        return nil
                    }
                } else {
                    return ma
                }
            case .ip6:
                if addy.addr == hostIP6 {
                    do {
                        var new = try Multiaddr(.ip6, address: "::1")
                        for proto in ma.addresses.dropFirst() {
                            new = try new.encapsulate(proto: proto.codec, address: proto.addr)
                        }
                        return new
                    } catch {
                        return nil
                    }
                } else {
                    return ma
                }
            default:
                return nil
            }
        }

        print(fixed)
    }

    func testFixSameHostAddresses2() {
        let hostIP4 = "192.168.1.21"
        let hostIP6 = "f4:d4:88:5c:bf:7b"
        let mas = [
            try! Multiaddr("/ip4/192.168.1.21/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            try! Multiaddr("/ip4/127.0.0.1/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            try! Multiaddr("/ip4/192.168.1.23/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            //try! Multiaddr("/ip6/f4:d4:88:5c:bf:7b/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV"),
            //try! Multiaddr("/ip6/b4:44:28:5d:af:7c/tcp/1234/p2p/QmX99Bk1CoBc787KY36tcy43AbXoo1HiG1WTDpenmJecNV")
        ]

        let fixed = mas.compactMap { ma -> Multiaddr? in
            guard let addy = ma.addresses.first else { return nil }
            switch addy.codec {
            case .ip4:
                return ma.replace(address: hostIP4, with: "127.0.0.1", forCodec: .ip4)
            case .ip6:
                return ma.replace(address: hostIP6, with: "::1", forCodec: .ip6)
            default:
                return nil
            }
        }

        print(fixed)
    }

    /// This is an example of how we can register a service using the dnssd library / daemon
    /// We register a `_http._tcp` service with the name "MyTest" on port 3338 for 10 seconds and then unregsiter the service by safely deallocating the `DNSServiceRef`
    /// Eventually it would be nice to not have to rely on dnssd, and instead register services through SwiftNIO udp multicast directly, but I haven't figured out how to do that yet.
    func testRegisterService() throws {
        /// Attempt to register a custom service
        var dnsService: DNSServiceRef? = nil
        let flags: DNSServiceFlags = DNSServiceFlags()
        DNSServiceRegister(&dnsService, flags, 0, "chat-room-name", "_p2p._udp", "", "", 3338, 0, "", nil, nil)

        let exp = expectation(description: "3 second delay")

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) {
            exp.fulfill()
        }

        waitForExpectations(timeout: 5, handler: nil)

        DNSServiceRefDeallocate(dnsService)
    }

    //    func test_dsnsd_lookup() throws {
    //
    //        var dnsService:DNSServiceRef? = nil
    //        let flags:DNSServiceFlags = DNSServiceFlags()
    //        DNSServiceResolve(&dnsService, flags, 6, "_afpovertcp._tcp", "", "JaybeesNAS.local", nil, nil)
    //    }

    func testCreateTextRecord() throws {
        let txtRecord = DNS.TextRecord(
            name: "chat-room-name",
            ttl: 3600,
            attributes: ["port": "3338", "test": "something"]
        )
        var txtBytes = Data()
        var labels = Labels()
        try txtRecord.serialize(onto: &txtBytes, labels: &labels)

        print(UInt16(txtBytes.count).bytes)
        print(txtBytes.asString(base: .base16))
    }

    func testCreateTextRecord2() throws {
        var txtRecord = TXTRecordRef()
        var buffer = Data()
        TXTRecordCreate(&txtRecord, 1, &buffer)
        var value = "1234"
        TXTRecordSetValue(&txtRecord, "test", UInt8(value.bytes.count), &value)

        print(txtRecord)
        print(TXTRecordGetLength(&txtRecord))

        TXTRecordDeallocate(&txtRecord)
    }
}
