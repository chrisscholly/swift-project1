/*
 * amlparser.swift
 *
 * Created by Simon Evans on 05/07/2016.
 * Copyright © 2016 Simon Evans. All rights reserved.
 *
 * AML Parser
 *
 */


typealias AMLByteBuffer = UnsafeBufferPointer<UInt8>
extension AMLNameString {
    static let rootChar = Character(UnicodeScalar("\\"))
    static let parentPrefixChar = Character(UnicodeScalar("^"))
    static let pathSeparatorChar = Character(UnicodeScalar("."))
}


func debugPrint(function: String = #function, _ args: Any...) {
#if false
    print("DEBUG: ", terminator: "")
    for x in args {
        print(x, " ", terminator: "")
    }
    print("")
#endif
}


enum AMLError: Error {
    //case invalidOpcode(reason: String)
    case invalidSymbol(reason: String)
    case invalidMethod(reason: String)
    case invalidData(reason: String)
    case endOfStream
    case parseError
    case unimplementedError(reason: String)

    static func invalidOpcode(value: UInt8) -> AMLError {
        let reason = "Bad opcode: " + asHex(value)
        return invalidData(reason: reason)
    }

    static func invalidOpcode(value: UInt16) -> AMLError {
        let reason = "Bad opcode: " + asHex(value)
        return invalidData(reason: reason)
    }


    static func unimplemented(_ function: String = #function, line: Int = #line) -> AMLError {
        print("line:", line, function, "is unimplemented")
        return unimplementedError(reason: function)
    }
}


struct AMLByteStream {
    private let buffer: AMLByteBuffer
    private(set) var position = 0
    private var bytesRemaining: Int { return buffer.count - position }


    init(buffer: AMLByteBuffer) throws {
        guard buffer.count > 0 else {
            throw AMLError.endOfStream
        }
        self.buffer = buffer
    }


    mutating func reset() {
        position = 0
    }


    func endOfStream() -> Bool {
        return position == buffer.endIndex
    }


    mutating func nextByte() -> UInt8? {
        debugPrint("position = \(position) count = \(buffer.count)")
        guard position < buffer.endIndex else {
            return nil
        }
        let byte = buffer[position]
        position += 1
        return byte
    }


    // get bytes in buffer from current pos to end
    mutating func bytesToEnd() -> AMLByteList {
        let bytes: AMLByteList = Array(buffer.suffix(bytesRemaining))
        position = buffer.endIndex

        return bytes
    }


    mutating func substreamOf(length: Int) throws -> AMLByteStream {
        guard length > 0 else {
            throw AMLError.invalidData(reason: "length < 1")
        }
        if let ba = buffer.baseAddress {
            guard length <= bytesRemaining else {
                throw AMLError.parseError
            }
            let substream = AMLByteBuffer(start: ba + position,
                count: length)
            position += length
            //substream.dumpBytes(count: length)
            return try AMLByteStream(buffer: substream)
        }
        throw AMLError.endOfStream
    }
}


final class AMLParser {
    private struct ParsedSymbol {
        var currentOpcode: AMLOpcode? = nil
        var currentChar: AMLCharSymbol? = nil

    }
    private var byteStream: AMLByteStream!
    private var currentScope: AMLNameString
    let acpiGlobalObjects: ACPIGlobalObjects


    init() {
        currentScope = AMLNameString(value: String(AMLNameString.rootChar))
        acpiGlobalObjects = ACPIGlobalObjects()
    }


    func parse(amlCode: AMLByteBuffer) throws -> () {
        debugPrint("amlCodeLength = \(amlCode.count) bytes")
        byteStream = try AMLByteStream(buffer: amlCode)
        try parse()
    }

/*
    func parseMethods() {

        print("ACPI: Parsing methods")
        for name in acpiGlobalObjects.unparsedMethodNames().sorted() {
            print("Method:", name)
            guard let node = acpiGlobalObjects.get(name) else {
                fatalError("Cant get node \(name)")
            }
            guard node.namedObjects.count == 1 else {
                fatalError("method \(node) has \(node.namedObjects.count) objects")
            }
            guard let method = node.namedObjects[0] as? AMLDataRefObject,
                method.isUnparsedMethod else {
                fatalError("\(name) is not an AMLUnparsedMethod")

            }
            do {
                let parsed = try parseUnparsedMethod(object: method)
                node.namedObjects[0] = parsed
            } catch {
                print("Cant update \(name):", error)
            }
        }
        print("ACPI: Methods parsed")
    }
*/

    private func subParser() throws -> AMLParser {
        let curPos = byteStream.position
        let pkgLength = try parsePkgLength()
        let bytesRead = byteStream.position - curPos
        let byteCount = Int(pkgLength) - bytesRead
        let stream = try byteStream.substreamOf(length: byteCount)
        let parser = AMLParser(byteStream: stream, scope: currentScope,
                               globalObjects: acpiGlobalObjects)
        return parser
    }


    // Called by subParser
    private init(byteStream: AMLByteStream, scope: AMLNameString,
                 globalObjects: ACPIGlobalObjects) {
        self.byteStream = byteStream
        self.currentScope = scope
        self.acpiGlobalObjects = globalObjects
    }


    private func parse() throws {
        byteStream.reset()
        _ = try parseTermList()
    }


   
    private func resolveNameToCurrentScope(path: AMLNameString) -> AMLNameString {
        return resolveNameTo(scope: currentScope, path: path)
    }


    // Package Length in bytes
    private func parsePkgLength() throws -> UInt {
        let leadByte = try nextByte()
        let byteCount: UInt8 = (leadByte & 0xC0) >> 6 // bits 6-7
        if byteCount == 0 {  // 1byte, length is 0-63
            let pkgLen = UInt(leadByte & 0x3f)
            return pkgLen
        }
        guard leadByte & 0x30 == 0 else {
            throw AMLError.invalidData(reason: "Bits 4,5 in PkgLength are not clear")
        }
        guard byteCount <= 3 else {
            throw AMLError.invalidData(reason: "byteCount is wrong \(byteCount)")
        }
        // bits 0-3 are lowest nibble
        var pkgLength = UInt(leadByte & 0x0f)

        for x in 0..<byteCount {
            let shift = (x * 8) + 4
            let byteData = try nextByte()
            pkgLength |= UInt(byteData) << UInt(shift)

        }
        return pkgLength
    }


    private func nextByte() throws -> UInt8 {
        if let byte = byteStream.nextByte() {
            return byte
        } else {
            throw AMLError.endOfStream
        }
    }

    private func nextWord() throws -> UInt16 {
        let byte0 = try nextByte()
        let byte1 = try nextByte()
        return UInt16(byte0) | UInt16(byte1) << 8
    }


    private func nextDWord() throws -> UInt32 {
        let word0 = try nextWord()
        let word1 = try nextWord()
        return UInt32(word0) | UInt32(word1) << 16
    }


    private func nextQWord() throws -> UInt64 {
        let dword0 = try nextDWord()
        let dword1 = try nextDWord()
        return UInt64(dword0) | UInt64(dword1) << 32
    }


    // update currentChar and currentOpcode, returns true is there was
    // a symbol or false if end of stream
    private func nextSymbol() throws -> ParsedSymbol? {
        guard let byte = byteStream.nextByte() else {
            debugPrint("nextSymbol: End of stream")
            return nil    // end of stream
        }
        debugPrint("nextSymbol: byte:0x", String(byte, radix: 16))
        let currentChar = AMLCharSymbol(byte: byte)

        // some bytes (eg 0x00) are both chars and opcodes
        var currentOpcode: AMLOpcode? = nil // clear it now
        if let op = AMLOpcode(byte: byte) {
            debugPrint("nextSymbol: opcode: \(op)")
            if op.isTwoByteOpcode {
                if let byte2 = byteStream.nextByte() {
                    let value = UInt16(withBytes: byte2, byte)
                    currentOpcode = AMLOpcode(rawValue: value)
                    guard currentOpcode != nil else {
                        throw AMLError.invalidOpcode(value: value)
                    }
                } else {
                    // This is an error since opcode is missing 2nd byte
                    throw AMLError.endOfStream
                }
            } else {
                currentOpcode = op
            }
        }
        if currentChar == nil && currentOpcode == nil {
            throw AMLError.invalidOpcode(value: byte)
        }
        return ParsedSymbol(currentOpcode: currentOpcode,
                            currentChar: currentChar)
    }


    // parse funcs return, true = matched and ran ok, false = no match,
    // throw on error
    func parseTermList() throws -> AMLTermList {
        var termList: AMLTermList = []
        while let symbol = try nextSymbol() {
            let termObj = try parseTermObj(symbol: symbol)
            termList.append(termObj)
        }
        return termList
    }


    // FIXME: parse objects to a more specific type
    private func parseObjectList() throws -> AMLObjectList {
        return try parseTermList()
    }


    private func parseFieldList() throws -> AMLFieldList {
        var bitOffset: UInt = 0
        var fieldList: AMLFieldList = []

        func parseFieldElement() throws -> AMLFieldElement? {
            guard let byte = byteStream.nextByte() else {
                return nil // end of stream
            }
            debugPrint(String(byte, radix: 16, uppercase: true))
            switch byte {
            case 0x00:
                let pkgLength = try parsePkgLength()
                bitOffset += pkgLength
                return AMLReservedField(pkglen: pkgLength)

            case 0x01:
                let type = try AMLAccessType(value: nextByte())
                let attrib = try nextByte()
                return AMLAccessField(type: type, attrib: attrib)

            case 0x02: //ConnectField
                throw AMLError.unimplemented()
                /*
                 case 0x03:
                 let type = try AMLAccessType(value: nextByte())
                 guard let attrib = try AMLExtendedAccessAttrib(rawValue: nextByte()) else {
                 let r = "Bad AMLExtendedAccessAttrib byte: \(byte)"
                 throw AMLError.invalidData(reason: r)
                 }
                 let length = try AMLByteConst(nextByte())
                 return AMLExtendedAccessField(type: type, attrib: attrib, length: length)
                 */
            default:
                if let ch = AMLCharSymbol(byte: byte), ch.charType == .leadNameChar {
                    let name = try AMLNameString(value: parseNameSeg(1, startingWith: String(ch.character)))
                    let bitWidth = try parsePkgLength()
                    let field = try AMLNamedField(name: name, bitOffset: bitOffset,
                                              bitWidth: bitWidth)
                    try addGlobalObject(name: resolveNameToCurrentScope(path: name),
                                        object: field)
                    bitOffset += bitWidth
                    return field
                }
                throw AMLError.invalidData(reason: "Bad byte: \(byte)")
            }
        }

        while let element = try parseFieldElement() {
            fieldList.append(element)
            // TODO: Add in field access defaults etc
        }
        return fieldList
    }




    private func parseTermObj(symbol: ParsedSymbol) throws -> AMLTermObj {
        debugPrint("symbol", symbol)

        if let obj = try parseSymbol(symbol: symbol) as? AMLTermObj {
            return obj
        }
        let r = "\(String(describing: symbol.currentOpcode)) is Invalid for termobj"
        throw AMLError.invalidSymbol(reason: r)
    }


    private func parseTermArgList(argCount: Int) throws -> AMLTermArgList {
        var termArgList: AMLTermArgList = []
        debugPrint("endOfStream: ", byteStream.endOfStream())
        while termArgList.count < argCount {
            termArgList.append(try parseTermArg())
        }
        return termArgList
    }


    private func parseTermArg() throws -> AMLTermArg {
        guard let symbol = try nextSymbol() else {
            throw AMLError.endOfStream
        }

        if let ch = symbol.currentChar, ch.charType != .nullChar {
            let name = try parseNameStringWith(character: ch)
            if try determineIfMethodOrName(name: name) {
                return try parseMethodInvocation(name: name)
            }
            if determineIfObjectOrName(name: name) {
                return name
            }
            return name
        }

        if symbol.currentOpcode != nil {
            if let arg: AMLTermArg = try parseSymbol(symbol: symbol) as? AMLTermArg
                /*                ?? parseDataObject(symbol: symbol)
                 ?? parseArgObj(symbol: symbol)
                 ?? parseLocalObj(symbol: symbol) */{
                    debugPrint(arg)
                return arg
            }
        }
        let r = "Invalid for termarg: \(String(describing: symbol))"
        throw AMLError.invalidSymbol(reason: r)
    }


    private func parseSuperName(symbol s: ParsedSymbol? = nil) throws -> AMLSuperName {

        if let symbol = try s ?? nextSymbol() {
            if let x: AMLSuperName = try? parseSimpleName(symbol: symbol) {
                return x
            }
            if let x = try parseSymbol(symbol: symbol) as? AMLSuperName {
                return x
            }
        }
        throw AMLError.invalidData(reason: "Cant find supername")
    }


    private func parseSymbol(symbol: ParsedSymbol) throws -> Any {
        // Check for method invocation first
        if let ch = symbol.currentChar, ch.charType != .nullChar {
            let name = try parseNameStringWith(character: ch)
            return try parseMethodInvocation(name: name)
        }

        guard let opcode = symbol.currentOpcode else {
            throw(AMLError.invalidSymbol(reason: "No opcode"))
        }
        switch opcode {
            // Type1opcodes
        case .breakOp:      return AMLDefBreak()
        case .breakPointOp: return AMLDefBreakPoint()
        case .continueOp:   return AMLDefContinue()
        case .elseOp:       return try parseDefElse()
        case .fatalOp:      return try parseDefFatal()
        case .ifOp:         return try parseDefIfElse()
        case .loadOp:       return try parseDefLoad()
        case .noopOp:       return AMLDefNoop()
        case .notifyOp:     return try parseDefNotify()
        case .releaseOp:    return try AMLDefRelease(object: parseSuperName())
        case .resetOp:      return try AMLDefReset(object: parseSuperName())
        case .returnOp:     return try AMLDefReturn(object: parseTermArg())
        case .signalOp:     return try AMLDefSignal(object: parseSuperName())
        case .sleepOp:      return try AMLDefSleep(msecTime: parseTermArg())
        case .stallOp:      return try AMLDefStall(usecTime: parseTermArg())
        case .unloadOp:     return try AMLDefUnload(object: parseSuperName())
        case .whileOp:      return try parseDefWhile()

            // Type2 opcodes
        case .acquireOp:            return try parseDefAcquire()
        case .addOp:                return try parseDefAdd()
        case .andOp:                return try parseDefAnd()
        case .bufferOp:             return try parseDefBuffer()
        case .concatOp:             return try parseDefConcat()
        case .concatResOp:          return try parseDefConcatRes()
        case .condRefOfOp:          return try parseDefCondRefOf()
        case .copyObjectOp:         return try parseDefCopyObject()
        case .decrementOp:          return try AMLDefDecrement(target: parseSuperName())
        case .derefOfOp:            return try AMLDefDerefOf(name: parseSuperName())
        case .divideOp:             return try parseDefDivide()
        case .findSetLeftBitOp:     return try parseDefFindSetLeftBit()
        case .findSetRightBitOp:    return try parseDefFindSetRightBit()
        case .fromBCDOp:            return try parseDefFromBCD()
        case .incrementOp:          return try AMLDefIncrement(target: parseSuperName())
        case .indexOp:              return try parseDefIndex()
        case .lAndOp:               return try parseDefLAnd()
        case .lEqualOp:             return try parseDefLEqual()
        case .lGreaterOp:           return try parseDefLGreater()
        case .lGreaterEqualOp:      return try parseDefLGreaterEqual()
        case .lLessOp:              return try parseDefLLess()
        case .lLessEqualOp:         return try parseDefLLessEqual()
        case .midOp:                return try parseDefMid()
        case .lNotOp:               return try AMLDefLNot(operand: parseOperand())
        case .lNotEqualOp:          return try parseDefLNotEqual()
        case .loadTableOp:          return try parseDefLoadTable()
        case .lOrOp:                return try parseDefLOr()
        case .matchOp:              return try parseDefMatch()
        case .modOp:                return try parseDefMod()
        case .multiplyOp:           return try parseDefMultiply()
        case .nandOp:               return try parseDefNAnd()
        case .norOp:                return try parseDefNOr()
        case .notOp:                return try parseDefNot()
        case .objectTypeOp:         return try AMLDefObjectType(object: parseSuperName())
        case .orOp:                 return try parseDefOr()
        case .packageOp:            return try parseDefPackage()
        case .varPackageOp:         return try parseDefVarPackage()
        case .refOfOp:              return try AMLDefRefOf(name: parseSuperName())
        case .shiftLeftOp:          return try parseDefShiftLeft()
        case .shiftRightOp:         return try parseDefShiftRight()
        case .sizeOfOp:             return try AMLDefSizeOf(name: parseSuperName())
        case .storeOp:              return try parseDefStore()
        case .subtractOp:           return try parseDefSubtract()
        case .timerOp:              return AMLDefTimer()
        case .toBCDOp:              return try parseDefToBCD()
        case .toBufferOp:           return try parseDefToBuffer()
        case .toDecimalStringOp:    return try parseDefToDecimalString()
        case .toHexStringOp:        return try parseDefToHexString()
        case .toIntegerOp:          return try parseDefToInteger()
        case .toStringOp:           return try parseDefToString()
        case .waitOp:               return try parseDefWait()
        case .xorOp:                return try parseDefXor()

        // ComputationalData
        case .bytePrefix:   return try AMLByteConst(nextByte())
        case .wordPrefix:   return try AMLWordConst(nextWord())
        case .dwordPrefix:  return try AMLDWordConst(nextDWord())
        case .qwordPrefix:  return try AMLQWordConst(nextQWord())
        case .stringPrefix: return try parseString()
        case .revisionOp:   return AMLRevisionOp()

        // Named objects
        case .bankFieldOp:          return try parseDefBankField()
        case .createBitFieldOp:     return try parseDefCreateBitField()
        case .createByteFieldOp:    return try parseDefCreateByteField()
        case .createDWordFieldOp:   return try parseDefCreateDWordField()
        case .createFieldOp:        return try parseDefCreateField()
        case .createQWordFieldOp:   return try parseDefCreateQWordField()
        case .createWordFieldOp:    return try parseDefCreateWordField()
        case .dataRegionOp:         return try parseDefDataRegion()
        case .deviceOp:             return try parseDefDevice()
        case .externalOp:           return try parseDefExternal()
        case .fieldOp:              return try parseDefField()
        case .methodOp:             return try parseDefMethod()
        case .indexFieldOp:         return try parseDefIndexField()
        case .mutexOp:              return try parseDefMutex()
        case .opRegionOp:           return try parseDefOpRegion()
        case .powerResOp:           return try parseDefPowerRes()
        case .processorOp:          return try parseDefProcessor()
        case .thermalZoneOp:        return try parseDefThermalZone()

        case .zeroOp:   return AMLZeroOp()
        case .oneOp:    return AMLOneOp()
        case .onesOp:   return AMLOnesOp()


        case .aliasOp: return try parseDefAlias()
        case .nameOp: return try parseDefName()
        case .scopeOp: return try parseDefScope()

        case .eventOp: return AMLEvent(name: try parseNameString())
        case .debugOp: return AMLDebugObj()
        case .local0Op: return try AMLLocalObj(localOp: opcode)
        case .local1Op: return try AMLLocalObj(localOp: opcode)
        case .local2Op: return try AMLLocalObj(localOp: opcode)
        case .local3Op: return try AMLLocalObj(localOp: opcode)
        case .local4Op: return try AMLLocalObj(localOp: opcode)
        case .local5Op: return try AMLLocalObj(localOp: opcode)
        case .local6Op: return try AMLLocalObj(localOp: opcode)
        case .local7Op: return try AMLLocalObj(localOp: opcode)
        case .arg0Op: return try AMLArgObj(argOp: opcode)
        case .arg1Op: return try AMLArgObj(argOp: opcode)
        case .arg2Op: return try AMLArgObj(argOp: opcode)
        case .arg3Op: return try AMLArgObj(argOp: opcode)
        case .arg4Op: return try AMLArgObj(argOp: opcode)
        case .arg5Op: return try AMLArgObj(argOp: opcode)
        case .arg6Op: return try AMLArgObj(argOp: opcode)

        // Should already be consumed by nextSymbol()
        case .extendedOpPrefix: throw AMLError.invalidSymbol(reason: "extendedOp")
        }
    }


    private func checkForMethodInvocation(symbol: ParsedSymbol) throws -> AMLMethodInvocation? {
        if let ch = symbol.currentChar, ch.charType != .nullChar {
            let name = try parseNameStringWith(character: ch)
            return try parseMethodInvocation(name: name)
        }
        return nil
    }


    private func parseMethodInvocation(name: AMLNameString) throws -> AMLMethodInvocation {
        // TODO: Somehow validate the method at a later stage

        guard let object = try acpiGlobalObjects.getGlobalObject(currentScope: currentScope, name: name) else {
            let r = "No such method \(name._value) in \(currentScope._value)"
            throw AMLError.invalidMethod(reason: r)
        }

        guard let method = object.object as? AMLMethod else {
            throw AMLError.invalidMethod(reason: "\(name._value) is not a Method")
        }
        debugPrint(method)
        var args: AMLTermArgList = []
        let flags = method.flags
        if flags.argCount > 0 {
            args = try parseTermArgList(argCount: flags.argCount)
            guard args.count == flags.argCount else {
                let r = "Method: \(name._value) has argCount of "
                    + "\(flags.argCount) but only parsed \(args.count) args"
                throw AMLError.invalidData(reason: r)
            }
        }
        let result = try AMLMethodInvocation(method: name, args:  args)
        debugPrint(result)
        return result
    }

    
    // FIXME: needs fix for Integer check (AMLOperand = AMLTermArg // => Integer)
    private func parseOperand() throws -> AMLOperand {
        let operand: AMLOperand = try parseTermArg()
        return operand
    }

    //  => Buffer, Package or String or Object
    private func parseBuffPkgStrObj() throws -> AMLBuffPkgStrObj {
        let arg = try parseTermArg()
        guard let result = arg as? AMLBuffPkgStrObj else {
            throw AMLError.invalidData(reason: "\(arg) is not a BuffPkgStrObj")
        }
        return result
    }


    private func parseString() throws -> AMLString {
        var result: String = ""
        while true {
            let byte = try nextByte()
            if byte == 0x00 { // NullChar
                break
            }
            else if byte >= 0x01 && byte <= 0x7F {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                throw AMLError.invalidData(reason: "Bad asciichar \(byte)")
            }
        }
        return AMLString(result)
    }

    private func parseInteger(symbol: ParsedSymbol) throws -> AMLInteger {
        var result: AMLInteger = 0
        var radix: AMLInteger = 0
        guard let symbol = try nextSymbol(), let ch = symbol.currentChar else {
            throw AMLError.endOfStream
        }
        guard let value = ch.numericValue else {
            throw AMLError.invalidData(reason: "Not a digit: '\(ch)'")
        }
        if value == 0 { // hex or octal
            radix = 1
        } else {
            radix = 10
            result = AMLInteger(value)
        }
        while let symbol = try nextSymbol(), let ch = symbol.currentChar {
            if radix == 1 {
                if ch.character == Character(UnicodeScalar("x")) ||
                    ch.character == Character(UnicodeScalar("X")) {
                    radix = 16
                    continue
                }
            }
            guard let value = ch.numericValueInclHex else {
                throw AMLError.invalidData(reason: "Not a digit: '\(ch)'")
            }
            if radix == 1 { // check if octal
                if value > 7 {
                    let r = "Invalid octal digit: '\(ch)'"
                    throw AMLError.invalidData(reason: r)
                }
                radix = 8
                result = AMLInteger(value)
                continue
            }

            if AMLInteger(value) >= radix {
                let r = "Invalid digit '\(ch)' for radix: \(radix)"
                throw AMLError.invalidData(reason: r)
            }
            result *= radix
            result += AMLInteger(value)
        }
        return result
    }


    private func parsePackageElementList(numElements: UInt8) throws -> AMLPackageElementList {

        func parsePackageElement(_ symbol: ParsedSymbol) throws -> AMLPackageElement {
            if let ch = symbol.currentChar, ch.charType != .nullChar {
                return try AMLString(parseNameStringWith(character: ch)._value)
            }

            guard symbol.currentOpcode != nil else {
                throw AMLError.invalidData(reason: "No opcode or valid string found")
            }
            if let obj = try parseSymbol(symbol: symbol) as? AMLDataRefObject {
                return obj //parseDataRefObject(symbol: symbol)
            }
            throw AMLError.invalidSymbol(reason: "\(symbol) is not an AMLDataRefObject")
        }

        var elements: AMLPackageElementList = []
        debugPrint("endOfStream: ", byteStream.endOfStream())
        while let symbol = try nextSymbol() {
            let element = try parsePackageElement(symbol)
            debugPrint("element:", element)
            elements.append(element)
            if Int(numElements) == elements.count {
                break
            }
        }
        return elements
    }


    private func determineIfMethodOrName(name: AMLNameString) throws -> Bool {
        debugPrint(name)
        if let obj = try acpiGlobalObjects.getGlobalObject(currentScope: currentScope,
                                         name: name),
            let method = obj.object as? AMLMethod {
                    debugPrint(name._value, method)
                    return true
            }

        return false
    }


    private func determineIfObjectOrName(name: AMLNameString) -> Bool {
        let fullName = resolveNameToCurrentScope(path: name)
        return (acpiGlobalObjects.get(fullName._value) != nil)
    }


    func addGlobalObject(name: AMLNameString, object: AMLNamedObj) throws {
        let nameStr = name._value
        guard let ch = nameStr.characters.first,
            ch == AMLNameString.rootChar else {
            throw AMLError.invalidData(reason: "\(nameStr) is not an absolute name")
        }
        guard acpiGlobalObjects.get(nameStr) != nil else {
            //throw AMLError.invalidData(reason: "\(nameStr) already exists")
            acpiGlobalObjects.add(nameStr, object)
            return // FIXME: should validate replacement is same type
        }
        acpiGlobalObjects.add(nameStr, object)
    }

    // MARK: Parse Def
    private func parseDefPackage() throws -> AMLDefPackage {
        let parser = try subParser()
        let numElements = try parser.nextByte()
        let elements = try parser.parsePackageElementList(numElements: numElements)
        debugPrint("numElements: \(numElements) count: \(elements.count)")
        return AMLDefPackage(numElements: numElements, elements: elements)

    }


    private func parseDefVarPackage() throws -> AMLDefVarPackage {
        throw AMLError.unimplemented()
    }


    private func parseDefAlias() throws -> AMLDefAlias {
        let alias = try AMLDefAlias(sourceObject: parseNameString(),
                                    aliasObject: parseNameString())
        // TODO, all the alias into the global objects
        return alias
    }


    private func parseDefBuffer() throws -> AMLBuffer {
        let parser = try subParser()
        let bufSize = try parser.parseTermArg()
        let bytes = parser.byteStream.bytesToEnd()
        return AMLBuffer(size: bufSize, value: bytes)
    }


    private func parseDefName() throws -> AMLDataRefObject {
        let name = try parseNameString()
       // print("DefName:", name._value)
        guard let symbol = try nextSymbol() else {
            throw AMLError.invalidSymbol(reason: "parseDefName")
        }
        if let dataObj = try parseSymbol(symbol: symbol) as? AMLDataRefObject {
            try addGlobalObject(name: resolveNameToCurrentScope(path: name),
                                object: dataObj)
            return dataObj //parseDataRefObject(symbol: symbol)
        }
        throw AMLError.invalidSymbol(reason: "\(symbol) is not an AMLDataRefObject")
    }


    // FIXME: Validate the location in the scope already exists
    private func parseDefScope() throws -> AMLDefScope {
        let parser = try subParser()
        let nameString = try parser.parseNameString()
        parser.currentScope = resolveNameToCurrentScope(path: nameString)
        let termList = try parser.parseTermList()
        return AMLDefScope(name: nameString, value: termList)
    }


    private func parseDefIndexField() throws -> AMLDefIndexField {
        let parser = try subParser()
        _ = try parser.parseNameString()
        let result = try AMLDefIndexField(/*name: name,*/
            dataName: parser.parseNameString(),
            flags: AMLFieldFlags(flags: parser.nextByte()),
            fields: parser.parseFieldList())
        return result
    }


    private func parseDefMethod() throws -> AMLDataRefObject {
        let parser = try subParser()
        let name = try parser.parseNameString()
        let fullPath = resolveNameToCurrentScope(path: name)
        parser.currentScope = fullPath
        let flags = try AMLMethodFlags(flags: parser.nextByte())
        let m = AMLMethod(flags: flags, parser: parser)


        try addGlobalObject(name: fullPath, object: m)
        return m
    }

/*
    private func parseUnparsedMethod(object: AMLMethod) throws -> AMLDataRefObject {
       /* guard let (flags, parser) = object.resultAsUnparseMethod else {
            throw AMLError.invalidMethod(reason: "Not an unparsed method")
        }*/
        let termList = try parser.parseTermList()
        return amlDefMethod(flags: flags, method: termList)
    }
*/

    private func parseDefMutex() throws -> AMLDefMutex {
        return try AMLDefMutex(name: parseNameString(),
                               flags: AMLMutexFlags(flags: nextByte()))
        //let fullPath = resolveNameToCurrentScope(path: mutex.name)
        //try addGlobalObject(name: fullPath, object: mutex)
        //return mutex
    }


    private func parseDefBankField() throws -> AMLDefBankField {
     //   return try parseVarArgs(opcode: .bankFieldOp)
        throw AMLError.unimplemented()
    }


    private func parseDefCreateBitField() throws -> AMLDefCreateBitField {
        return try AMLDefCreateBitField(sourceBuff: parseTermArg(),
                                        bitIndex: parseTermArg(),
                                        name: parseNameString())
    }


    private func parseDefCreateByteField() throws -> AMLDefCreateByteField {
        return try AMLDefCreateByteField(sourceBuff: parseTermArg(),
                                         byteIndex: parseTermArg(),
                                         name: parseNameString())
    }


    private func parseDefCreateWordField() throws -> AMLDefCreateWordField {
        return try AMLDefCreateWordField(sourceBuff: parseTermArg(),
                                         byteIndex: parseTermArg(),
                                         name: parseNameString())
    }


    private func parseDefCreateDWordField() throws -> AMLDefCreateDWordField {
        return try AMLDefCreateDWordField(sourceBuff: parseTermArg(),
                                          byteIndex: parseTermArg(),
                                          name: parseNameString())
    }
    

    private func parseDefCreateQWordField() throws -> AMLDefCreateQWordField {
        return try AMLDefCreateQWordField(sourceBuff: parseTermArg(),
                                          byteIndex: parseTermArg(),
                                          name: parseNameString())
    }


    private func parseDefCreateField() throws -> AMLDefCreateField {
        return try AMLDefCreateField(sourceBuff: parseTermArg(),
                                     bitIndex: parseTermArg(),
                                     numBits: parseTermArg(),
                                     name: parseNameString())
    }


    private func parseDefDataRegion() throws -> AMLDefDataRegion {
        let name = try parseNameString()
        let arg1 = try parseTermArg()
        let arg2 = try parseTermArg()
        let arg3 = try parseTermArg()
        return AMLDefDataRegion(name: name, arg1: arg1, arg2: arg2, arg3: arg3)
    }


    private func parseDefExternal() throws -> AMLNamedObj {
        let name = try parseNameString()
        let type = try nextByte()
        let argCount = try nextByte()
        return try AMLDefExternal(name: name, type: type, argCount: argCount)
    }


    private func parseDefDevice() throws -> AMLDefDevice {
        let parser = try subParser()
        let name = try parser.parseNameString()
        let fqn = resolveNameToCurrentScope(path: name)
        parser.currentScope = fqn
        let dev = try AMLDefDevice(name: name, value: parser.parseTermList())
        try addGlobalObject(name: fqn, object: dev)
        return dev
    }


    private func parseDefField() throws -> AMLDefField {
        let parser = try subParser()
        let name = try parser.parseNameString()
        let flags = try AMLFieldFlags(flags: parser.nextByte())
        let fields = try parser.parseFieldList()
        let field = AMLDefField(name: name, flags: flags, fields: fields)

       // for namedField in field.fields {
       //     print(namedField)
       // }

        return field
    }


    private func parseDefOpRegion() throws -> AMLDefOpRegion {
        let name = try parseNameString()
        let byte = try nextByte()
        guard let region = AMLRegionSpace(rawValue: byte) else {
            throw AMLError.invalidData(reason: "Bad AMLRegionSpace: \(byte)")
        }
        return try AMLDefOpRegion(name: name, region: region,
                                  offset: parseTermArg(),
                                  length: parseTermArg())
    }


    private func parseDefPowerRes() throws -> AMLNamedObj {
        throw AMLError.unimplemented()
    }


    private func parseDefProcessor() throws -> AMLDefProcessor {
        let parser = try subParser()
        let name = try parser.parseNameString()
        parser.currentScope = resolveNameToCurrentScope(path: name)

        return try AMLDefProcessor(//name: name,
                                   procId: parser.nextByte(),
                                   pblkAddr: parser.nextDWord(),
                                   pblkLen: parser.nextByte(),
                                   objects: parser.parseObjectList())
    }


    private func parseDefThermalZone() throws -> AMLNamedObj {
        throw AMLError.unimplemented()
    }


    private func parseDefElse() throws -> AMLDefElse {
        if byteStream.endOfStream() {
            // FIXME, maybe just catch
            debugPrint("endOfStream")
            return AMLDefElse(value: nil)
        }
        let parser = try subParser()
        let termList = try parser.parseTermList()
        return AMLDefElse(value: termList)
    }


    private func parseDefFatal() throws -> AMLDefFatal {
        let type = try nextByte()
        let code = try nextDWord()
        let arg = try parseTermArg()
        return AMLDefFatal(type: type, code: code, arg: arg)
    }


    private func parseDefIfElse() throws -> AMLIfElseOp {
        let parser = try subParser()
        let predicate: AMLPredicate = try parser.parseTermArg()
        let termList = try parser.parseTermList()

        guard let symbol = try nextSymbol() else {
            throw AMLError.endOfStream
        }

        guard let defElse = try parseSymbol(symbol: symbol) as? AMLDefElse else {
            throw AMLError.invalidData(reason: "should be DefElse")
        }

        return AMLIfElseOp(predicate: predicate, value: termList,
                           defElse: defElse)
    }


    private func parseDefLoad() throws -> AMLDefLoad {
        let name = try parseNameString()
        let value = try parseSuperName()
        return AMLDefLoad(name: name, value: value)
    }


    private func parseDefNotify() throws -> AMLDefNotify {
        return try AMLDefNotify(object: parseSuperName(),
            value: parseTermArg())
    }

    private func parseDefWhile() throws -> AMLDefWhile {
        let parser = try subParser()
        return try AMLDefWhile(predicate: parser.parseTermArg(),
                               list: parser.parseTermList())
    }


    private func parseDefAcquire() throws -> AMLDefAcquire {
        return try AMLDefAcquire(mutex: parseSuperName(),
                                 timeout: nextWord())
    }


    private func parseDefAdd() throws -> AMLDefAdd {
        return try AMLDefAdd(operand1: parseOperand(), operand2: parseOperand(),
                             target: parseTarget())
    }


    private func parseDefAnd() throws -> AMLDefAnd {
        return try AMLDefAnd(operand1: parseOperand(), operand2: parseOperand(),
                            target: parseTarget())
    }


    private func parseDefConcat() throws -> AMLDefConcat {
        return try AMLDefConcat(data1: parseTermArg(), data2: parseTermArg(),
                                target: parseTarget())
    }


    private func parseDefConcatRes() throws -> AMLDefConcatRes {
        return try AMLDefConcatRes(data1: parseTermArg(), data2: parseTermArg(),
                                   target: parseTarget())
    }


    private func parseDefCondRefOf() throws -> AMLDefCondRefOf {
        return try AMLDefCondRefOf(name: parseSuperName(),
                                   target: parseTarget())
    }


    private func parseDefDerefOf() throws -> AMLDefCondRefOf {
        return try AMLDefCondRefOf(name: parseSuperName(),
                                   target: parseTarget())
    }



    private func parseDefCopyObject() throws -> AMLDefCopyObject {
        let arg = try parseTermArg()
        let name = try parseSimpleName(symbol: nextSymbol())
        return AMLDefCopyObject(object: arg, target: name)
    }


    private func parseDefDivide() throws -> AMLDefDivide {
        return try AMLDefDivide(dividend: parseTermArg(),
                                divisor: parseTermArg(),
                                remainder: parseTarget(),
                                quotient: parseTarget())
    }


    private func parseDefFindSetLeftBit() throws -> AMLDefFindSetLeftBit {
        return try AMLDefFindSetLeftBit(operand: parseOperand(),
                                        target: parseTarget())
    }


    private func parseDefFindSetRightBit() throws -> AMLDefFindSetRightBit {
        return try AMLDefFindSetRightBit(operand: parseOperand(),
                                         target: parseTarget())
    }


    private func parseDefFromBCD() throws -> AMLDefFromBCD {
        return try AMLDefFromBCD(value: parseOperand(),
                                 target: parseTarget())
    }


    private func parseDefIndex() throws -> AMLDefIndex {
        return try AMLDefIndex(object: parseBuffPkgStrObj(),
                               index: parseTermArg(),
                               target: parseTarget())
    }


    private func parseDefLAnd() throws -> AMLDefLAnd {
        return try AMLDefLAnd(operand1: parseOperand(),
                              operand2: parseOperand())
    }


    private func parseDefLEqual() throws -> AMLDefLEqual {
        return try AMLDefLEqual(operand1: parseOperand(),
                                operand2: parseOperand())
    }


    private func parseDefLGreater() throws -> AMLDefLGreater {
        return try AMLDefLGreater(operand1: parseOperand(),
                                  operand2: parseOperand())
    }


    private func parseDefLGreaterEqual() throws -> AMLDefLGreaterEqual {
        return try AMLDefLGreaterEqual(operand1: parseOperand(),
                                       operand2: parseOperand())
    }


    private func parseDefLLess() throws -> AMLDefLLess {
        return try AMLDefLLess(operand1: parseOperand(),
                        operand2: parseOperand())
    }


    private func parseDefLLessEqual() throws -> AMLDefLLessEqual {
        return try AMLDefLLessEqual(operand1: parseOperand(),
                                    operand2: parseOperand())
    }


    private func parseDefMid() throws -> AMLDefMid {
        return try AMLDefMid(obj: parseTermArg(),
                             arg1: parseTermArg(),
                             arg2: parseTermArg(),
                             target: parseTarget())
    }


    private func parseDefLNotEqual() throws -> AMLDefLNotEqual {
        return try AMLDefLNotEqual(operand1: parseOperand(),
                                   operand2: parseOperand())
    }


    private func parseDefLoadTable() throws -> AMLDefLoadTable {
        throw AMLError.unimplemented()
    }


    private func parseDefLOr() throws -> AMLDefLOr {
        return try AMLDefLOr(operand1: parseOperand(),
                             operand2: parseOperand())
    }


    private func parseDefMatch() throws -> AMLDefMatch {
        throw AMLError.unimplemented()
    }


    private func parseDefMod() throws -> AMLDefMod {
        throw AMLError.unimplemented()
    }


    private func parseDefMultiply() throws -> AMLDefMultiply {
        return try AMLDefMultiply(operand1: parseTermArg(),
                                  operand2: parseTermArg(),
                                  target: parseTarget())
    }


    private func parseDefNAnd() throws -> AMLDefNAnd {
        return try AMLDefNAnd(operand1: parseTermArg(),
                              operand2: parseTermArg(),
                              target: parseTarget())
    }


    private func parseDefNOr() throws -> AMLDefNOr {
        return try AMLDefNOr(operand1: parseTermArg(),
                             operand2: parseTermArg(),
                             target: parseTarget())
    }


    private func parseDefNot() throws -> AMLDefNot {
        return try AMLDefNot(operand: parseOperand(), target: parseTarget())
    }


    private func parseDefOr() throws -> AMLDefOr {
        return try AMLDefOr(operand1: parseTermArg(),
                            operand2: parseTermArg(),
                            target: parseTarget())
    }


    private func parseDefShiftLeft() throws -> AMLDefShiftLeft {
        return try AMLDefShiftLeft(operand: parseTermArg(),
                                   count: parseTermArg(),
                                   target: parseTarget())
    }


    private func parseDefShiftRight() throws -> AMLDefShiftRight {
        return try AMLDefShiftRight(operand: parseTermArg(),
                                    count: parseTermArg(),
                                    target: parseTarget())
    }


    private func parseDefStore() throws -> AMLDefStore {
        return try AMLDefStore(arg: parseTermArg(), name: parseSuperName())
    }


    private func parseDefSubtract() throws -> AMLDefSubtract {
        return try AMLDefSubtract(operand1: parseTermArg(),
                                  operand2: parseTermArg(),
                                  target: parseTarget())
    }


    private func parseDefToBCD() throws -> AMLDefToBCD {
        return try AMLDefToBCD(operand: parseOperand(), target: parseTarget())
    }


    private func parseDefToBuffer() throws -> AMLDefToBuffer {
        return try AMLDefToBuffer(operand: parseOperand(), target: parseTarget())
    }


    private func parseDefToDecimalString() throws -> AMLDefToDecimalString {
        return try AMLDefToDecimalString(operand: parseOperand(),
                                         target: parseTarget())
    }


    private func parseDefToHexString() throws -> AMLDefToHexString {
        return try AMLDefToHexString(operand: parseOperand(),
                                     target: parseTarget())
    }


    private func parseDefToInteger() throws -> AMLDefToInteger {
        return try AMLDefToInteger(operand: parseOperand(),
                                   target: parseTarget())
    }


    private func parseDefToString() throws -> AMLDefToString {
        return try AMLDefToString(arg: parseTermArg(),
                                  length: parseTermArg(),
                                  target: parseTarget())
    }


    private func parseDefWait() throws -> AMLDefWait {
        let object = try parseSuperName()
        let operand = try parseOperand()
        return AMLDefWait(object: object, operand: operand)
    }


    private func parseDefXor() throws -> AMLDefXor {
        return try AMLDefXor(operand1: parseTermArg(), operand2: parseTermArg(),
                             target: parseTarget())
    }


    // MARK: Name / String / Target parsing
    private func parseTarget() throws -> AMLTarget {
        guard let symbol = try nextSymbol() else {
            throw AMLError.endOfStream
        }
        debugPrint(symbol)
        if symbol.currentChar?.charType == .nullChar {
            return AMLNullName()
        }

        if let name = try? parseSuperName(symbol: symbol) {
            return name
        }

        let r = "nextSymbol returned true but symbol: \(symbol)"
        throw AMLError.invalidSymbol(reason: r)
    }


    // Lead byte could be opcode or char
    private func parseSimpleName(symbol: ParsedSymbol?) throws -> AMLSimpleName {
        guard let s = symbol else {
            throw AMLError.endOfStream
        }
        if s.currentChar != nil {
            debugPrint("s.currentChar = '\(s.currentChar!.character)'")
            return try parseNameStringWith(character: s.currentChar!)
        }

        if let obj = try parseSymbol(symbol: s) as? AMLSimpleName {
            return obj
        }
        throw AMLError.invalidSymbol(reason: "shouldnt get here")
    }


    private func nextChar() throws -> AMLCharSymbol {
        if let ch = try nextCharOrEOS() {
            return ch
        } else {
            throw AMLError.endOfStream // End Of stream
        }
    }


    private func nextCharOrEOS() throws -> AMLCharSymbol? {
        guard let symbol = try nextSymbol() else {
            return nil // End of Stream
        }
        guard let char = symbol.currentChar else {
            let r = "next char is an opcode \(String(describing: symbol.currentOpcode))"
            throw AMLError.invalidSymbol(reason: r)
        }
        return char
    }


    private func parseNameString() throws -> AMLNameString {
        return try parseNameStringWith(character: nextChar())
    }


    // NameString := <RootChar NamePath> | <PrefixPath NamePath>
    private func parseNameStringWith(character: AMLCharSymbol) throws -> AMLNameString {
        var result = ""
        var ch = character
        switch ch.charType {
        case .rootChar:
            result = String(ch.character)
            ch = try nextChar()

        case .parentPrefixChar:
            var c: AMLCharSymbol? = ch
            while c != nil {
                result.append(c!.character)
                ch = try nextChar()
                c = (ch.charType == .parentPrefixChar) ? ch : nil
            }
        default: break
        }
        // result is now RootChar | PrefixChar 0+
        result += try parseNamePath(ch: ch)
        return AMLNameString(value: result)
    }


    // Namepath might start with a char or a prefix
    private func parseNamePath(ch: AMLCharSymbol) throws -> String {

        switch ch.charType {
        case .leadNameChar:
            return try parseNameSeg(1, startingWith: String(ch.character))

        case .dualNamePrefix:
            return try parseNameSeg(2)

        case .multiNamePrefix:
            let segCount = try nextByte()
            guard segCount != 0 else {
                throw AMLError.invalidData(reason: "segCount cannot be 0")
            }
            return try parseNameSeg(segCount)

        case .nullChar:
            return "" // fixme should be nullname
            //return AMLNullName

        default:
            let r = "Bad char \(String(describing: ch))"
            throw AMLError.invalidData(reason: r)
        }
    }


    private func parseNameSeg(startingWith: String = "") throws -> String {
        var name = startingWith

        if let ch = try nextCharOrEOS() {
            if name == "" {
                guard ch.charType == .leadNameChar else {
                    let r = "Expected .leadNameChar but char was \(ch)"
                    throw AMLError.invalidSymbol(reason: r)
                }
            }
            name.append(ch.character)
            let nameLen = name.characters.count
            for _ in nameLen...3 {
                if let currentChar = try nextCharOrEOS() {
                    let ch = try parseNameChar(ch: currentChar)
                    name.append(ch.character)
                }
            }
            // Strip trailing '_' padding characters
            while let e = name.characters.last, e == "_" {
                name.remove(at: name.index(before: name.endIndex))
            }
        }
        return name
    }


    private func parseNameSeg(_ count: UInt8, startingWith: String = "") throws -> String {
        let pathSeperator = "."

        guard count > 0 else {
            throw AMLError.invalidData(reason: "Name paths has 0 segments")
        }
        var name = try parseNameSeg(startingWith: startingWith)
        for _ in 1..<count {
            name += pathSeperator
            name += try parseNameSeg()
        }
        return name
    }


    private func parseNameChar(ch: AMLCharSymbol) throws -> AMLCharSymbol {
        if ch.charType == .digitChar || ch.charType == .leadNameChar {
            return ch
        }
        let r = "bad name char: \(String(describing: ch))"
        throw AMLError.invalidData(reason: r)
    }
}
