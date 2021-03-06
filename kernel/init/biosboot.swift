/*
 * kernel/init/biosboot.swift
 *
 * Created by Simon Evans on 01/04/2017.
 * Copyright © 2015 - 2017 Simon Evans. All rights reserved.
 *
 * Parse the BIOS tables.
 */

typealias ScanArea = UnsafeBufferPointer<UInt8>


struct BiosBootParams: BootParams, CustomStringConvertible {
    enum E820Type: UInt32 {
    case RAM      = 1
    case RESERVED = 2
    case ACPI     = 3
    case NVS      = 4
    case UNUSABLE = 5
    }


    struct E820MemoryRange: CustomStringConvertible {
        let baseAddr: UInt64
        let length: UInt64
        let type: UInt32

        var description: String {
            var desc = String.sprintf("%12X - %12X %4.4X", baseAddr,
                baseAddr + length - 1, type)
            let size = UInt(length)
            if (size >= mb) {
                desc += String.sprintf(" %6uMB  ", size / mb)
            } else {
                desc += String.sprintf(" %6uKB  ", size / kb)
            }
            if let x = E820Type(rawValue: type) {
                desc += String(describing: x)
            } else {
                desc += "type: \(type) is invalid"
            }

            return desc
        }


        fileprivate func toMemoryRange() -> MemoryRange? {
            guard let e820type = E820Type(rawValue: self.type) else {
                print("bootparams: Invalid memory type: \(self.type)")
                return nil
            }
            var mtype: MemoryType

            switch (e820type) {
            case .RAM:      mtype = MemoryType.Conventional
            case .RESERVED: mtype = MemoryType.E820Reserved
            case .ACPI:     mtype = MemoryType.ACPIReclaimable
            case .NVS:      mtype = MemoryType.ACPINonVolatile
            case .UNUSABLE: mtype = MemoryType.Unusable
            }

            return MemoryRange(type: mtype,
                start: PhysAddress(RawAddress(self.baseAddr)),
                size: UInt(self.length))
        }
    }


    private let RSDP_SIG: StaticString = "RSD PTR "

    let source = "E820"
    let memoryRanges: [MemoryRange]
    let frameBufferInfo: FrameBufferInfo? = nil
    let kernelPhysAddress: PhysAddress

    var description: String {
        return "bootparams: BiosBootParams has \(memoryRanges.count) ranges"
    }


    init?(bootParamsAddr: VirtualAddress) {
        let sig = readSignature(bootParamsAddr)
        if sig == nil || sig! != "BIOS" {
            print("bootparams: boot_params are not BIOS")
            return nil
        }
        let membuf = MemoryBufferReader(bootParamsAddr,
            size: MemoryLayout<bios_boot_params>.stride)
        membuf.offset = 8       // skip signature
        do {
            // FIXME: use bootParamsSize to size a buffer limit
            let bootParamsSize: UInt = try membuf.read()
            guard bootParamsSize > 0 else {
                print("bootparams: bootParamsSize = 0")
                return nil
            }
            kernelPhysAddress = PhysAddress(try membuf.read())
            printf("bootParamsSize = %ld kernelPhysAddress: %#x\n",
                bootParamsSize, kernelPhysAddress.value)

            let e820MapAddr = PhysAddress(try membuf.read())
            let e820Entries: UInt = try membuf.read()
            memoryRanges = BiosBootParams.parseE820Table(kernelPhysAddress,
                e820MapAddr, e820Entries)
        } catch {
            koops("bootparams: Cant read BIOS boot params")
        }
    }


    // This is only called from init() so needs to be static since 'self'
    // isnt fully initialised.
    // FIXME - still needs to check for overlapping regions
    static private func parseE820Table(_ kernelPhysAddress: PhysAddress,
        _ e820MapPhysAddr: PhysAddress, _ e820Entries: UInt) -> [MemoryRange] {
        guard e820Entries > 0 && e820MapPhysAddr.value > 0 else {
            koops("E820: map is empty")
        }
        let e820MapAddr = e820MapPhysAddr.vaddr
        var ranges: [MemoryRange] = []
        ranges.reserveCapacity(Int(e820Entries))
        let buf = MemoryBufferReader(e820MapAddr,
            size: MemoryLayout<E820MemoryRange>.stride * Int(e820Entries))
        let kernelSize = UInt(_kernel_end_addr - _kernel_start_addr)
        let kernelPhysEnd = kernelPhysAddress.advanced(by: kernelSize)
        printf("E820: Kernel size: %lx\n", kernelSize)

        for _ in 0..<e820Entries {
            if let entry: E820MemoryRange = try? buf.read() {
                if let memEntry = entry.toMemoryRange() {
                    // Find the entry that covers the memory where the kernel
                    // is loaded and adjust it then add another range for the
                    // kernel
                    if memEntry.start <= kernelPhysAddress
                    && kernelPhysEnd <= memEntry.start + memEntry.size {
                        let range1size = memEntry.start.distance(to: kernelPhysAddress)
                        if range1size > 0 {
                            ranges.append(MemoryRange(type: memEntry.type,
                                    start: memEntry.start, size: range1size))
                        }

                        ranges.append(MemoryRange(type: .Kernel,
                                start: kernelPhysAddress, size: kernelSize))
                        let range2end = memEntry.start.advanced(by: memEntry.size)
                        let range2size = kernelPhysEnd.distance(to: range2end)
                        if range2size > 0 {
                            ranges.append(MemoryRange(type: memEntry.type,
                                    start: kernelPhysEnd, size: range2size))
                        }
                    } else {
                        ranges.append(memEntry)
                    }
                }
            }
        }

        // Find any holes in the memory ranges and add a fake range. This
        // allows finding gaps later on for MMIO space etc
        func findHoles(_ ranges: inout [MemoryRange]) {
            var addr = PhysAddress(0)
            sortRanges(&ranges)
            for entry in ranges {
                if addr < entry.start {
                    let size = addr.distance(to: entry.start)
                    ranges.append(MemoryRange(type: MemoryType.Hole, start: addr,
                            size: size))
                }
                addr = entry.start.advanced(by: entry.size)
            }
            sortRanges(&ranges)
        }

        func sortRanges(_ ranges: inout [MemoryRange]) {
            ranges.sort(by: { $0.start < $1.start })
        }

        guard ranges.count > 0 else {
            koops("E820: Cant find any memory in the e820 map")
        }

        guard ranges.contains(where: { $0.type == .Kernel }) else {
            koops("E820: Could not find Kernel entry")
        }

        findHoles(&ranges)

        return ranges
    }


    func findTables() -> (UnsafePointer<rsdp1_header>?,
        UnsafePointer<smbios_header>?) {
        let rsdp = findRSDP()
        let smbiosp = findSMBIOS()
        return (rsdp, smbiosp)
    }


    // Root System Description Pointer
    private func findRSDP() -> UnsafePointer<rsdp1_header>? {
        if let ebda = getEBDA() {
            printf("ACPI: EBDA: %#8.8lx len: %#4.4lx\n", ebda.baseAddress!,
                ebda.count)
            if let rsdp = scanForRSDP(ebda) {
                return rsdp
            }
        }
        let upper = getUpperMemoryArea()
        printf("ACPI: Upper: %#8.8lx len: %#4.4lx\n", upper.baseAddress!, upper.count)
        return scanForRSDP(upper)
    }


    // SMBios table
    private func findSMBIOS() -> UnsafePointer<smbios_header>? {
        let region: ScanArea = mapPhysicalRegion(start: PhysAddress(0xf0000),
            size: 0x10000)
        if let ptr = scanForSignature(region, SMBIOS.SMBIOS_SIG) {
            return ptr.bindMemory(to: smbios_header.self, capacity: 1)
        } else {
            return nil
        }
    }


    private func getEBDA() -> ScanArea? {
        let ebdaRegion: UnsafeBufferPointer<UInt16> = mapPhysicalRegion(start: PhysAddress(0x40E),
            size: 1)
        let ebda = ebdaRegion[0]
        // Convert realmode segment to linear address
        let rsdpAddr = UInt(ebda) * 16

        if rsdpAddr > 0x400 {
            let region: ScanArea = mapPhysicalRegion(start: PhysAddress(rsdpAddr),
                size: 1024)
            return region
        } else {
            return nil
        }
    }


    private func getUpperMemoryArea() -> ScanArea {
        let region: ScanArea = mapPhysicalRegion(start: PhysAddress(0xE0000), size: 0x20000)
        return region
    }


    private func scanForRSDP(_ area: ScanArea) -> UnsafePointer<rsdp1_header>? {
        if let ptr = scanForSignature(area, RSDP_SIG) {
            return ptr.bindMemory(to: rsdp1_header.self, capacity: 1)
        } else {
            return nil
        }
    }


    private func scanForSignature(_ area: ScanArea, _ signature: StaticString)
        -> UnsafeRawPointer? {
        assert(signature.utf8CodeUnitCount != 0)
        assert(signature.isASCII)

        let end = area.count - MemoryLayout<rsdp1_header>.stride
        for idx in stride(from: 0, to: end, by: 16) {
            if memcmp(signature.utf8Start, area.baseAddress! + idx,
                signature.utf8CodeUnitCount) == 0 {
                return UnsafeRawPointer(area.regionPointer(offset: idx))
            }
        }

        return nil
    }
}
