//
//  ACPIGlobalObjects.swift
//  acpi
//
//  Created by Simon Evans on 28/04/2017.
//  Copyright © 2017 Simon Evans. All rights reserved.
//


final class ACPIGlobalObjects {

    final class ACPIObjectNode {
        let name: String //AMLNamedObj
        //var namedObjects: [AMLNamedObj]
        var object: AMLNamedObj? = nil
        var childNodes: [ACPIObjectNode]

        init(name: String, object: AMLNamedObj?,
             childNodes: [ACPIObjectNode]) {
            self.name = name
            self.object = object
            self.childNodes = childNodes
        }

        subscript(index: String) -> ACPIObjectNode? {
            get {
                for node in childNodes {
                    if node.name == index {
                        return node
                    }
                }
                return nil
            }
        }
    }

    // Predefined objects
    private var globalObjects = ACPIObjectNode(
        name: "\\",
        //namedObjects: [],
        object: nil,
        childNodes: [
            ACPIObjectNode(name: "_OSI",
                           object: nil,
                           childNodes: []),

            ACPIObjectNode(name: "_GL",
                           object: AMLDefMutex(
                            name: AMLNameString(value: "_GL"),
                            flags: AMLMutexFlags()),
                           childNodes: []),

            ACPIObjectNode(name: "_REV",
                           object: AMLRevisionOp(),
                           childNodes: []),

            ACPIObjectNode(name: "_OS",
                           object: AMLString("Windows"),
                           childNodes: [])
        ])


    private func findNode(named: String, parent: ACPIObjectNode) -> ACPIObjectNode? {
        for node in parent.childNodes {
            if node.name == named {
                return node
            }
        }
        return nil
    }

    // Remove leading '\\'
    private func removeRootChar(name: String) -> String {
        if let f = name.characters.first, f == "\\" {
            var name2 = name
            name2.remove(at: name2.startIndex)
            return name2
        }
        return name
    }


    func fixup(name: String, object: AMLNamedObj) -> AMLNamedObj {
        if name == "_HID" || name == "_CID" {
            if let o = object as? AMLDataRefObject {
                return decodeHID(obj: o)
            }
        }
        return object
    }


    func add(_ name: String, _ object: AMLNamedObj) {
        print("Adding \(name)", type(of: object))
        var parent = globalObjects
        var nameParts = removeRootChar(name: name).components(
            separatedBy: AMLNameString.pathSeparatorChar)
        let nodeName = nameParts.last!
        let fixedObject = fixup(name: nodeName, object: object)

        while nameParts.count > 0 {
            let part = nameParts.removeFirst()
            if let childNode = findNode(named: part, parent: parent) {
                parent = childNode
            } else {
                let newNode = ACPIObjectNode(name: part,
                                             //namedObjects: [],
                                            object: nil,
                                             childNodes: [])
                    parent.childNodes.append(newNode)
                    parent = newNode
            }
        }

        guard parent.name == nodeName else {
            fatalError("bad node")
        }
        if parent.object != nil {
            print("already has object")
        }
        parent.object = fixedObject
    }


    // needs to be a full path starting with \\
    func get(_ name: String) -> ACPIObjectNode? {
        var name2 = name
        guard name2.remove(at: name2.startIndex) == "\\" else {
            return nil
        }
        var parent = globalObjects
        var nameParts = name2.components(separatedBy: AMLNameString.pathSeparatorChar)
        while nameParts.count > 0 {
            let part = nameParts.removeFirst()
            if let childNode = findNode(named: part, parent: parent) {
                parent = childNode
            } else {
                return nil
            }
        }
        return parent
    }


    func getDataRefObject(_ name: String) -> AMLDataRefObject? {
        if let node = get(name) {
            return node.object as? AMLDataRefObject
        }
        return nil
    }



    func getGlobalObject(currentScope: AMLNameString, name: AMLNameString)
        throws -> ACPIObjectNode? {
            let nameStr = name._value
            guard nameStr.characters.first != nil else {
                throw AMLError.invalidData(reason: "string is empty")
            }

            let fullPath = resolveNameTo(scope: currentScope, path: name)
            if let obj = get(fullPath._value) {
                return obj
            }
            // Do a search up the tree
            guard name.isNameSeg else {
                return nil
            }
            let seperator = AMLNameString.pathSeparatorChar
            var nameSegs = currentScope._value.components(separatedBy: seperator)
            while nameSegs.count > 1 {
                _ = nameSegs.popLast()
                var tmpName = nameSegs.joined(separator: String(seperator))
                tmpName.append(AMLNameString.pathSeparatorChar)
                tmpName.append(name._value)
                if let obj = get(tmpName) {
                    return obj
                }
            }
            if nameSegs.count == 1 {
                var tmpName = "\\"
                tmpName.append(name._value)
                if let obj =  get(tmpName) {
                    return obj
                }
            }
            return nil
    }



    func walkNode(name: String, node: ACPIObjectNode, _ body: (String, ACPIObjectNode) -> Void) {
        body(name, node)
        node.childNodes.forEach {
            let child = $0
            let fullName = (name == "\\") ? name + child.name :
                name + String(AMLNameString.pathSeparatorChar) + child.name
            walkNode(name: fullName, node: child, body)
        }
    }


    private func HIDForDevice(childNodes: [ACPIObjectNode]) -> String? {
        for node in childNodes {
            if (node.name == "_HID" || node.name == "_CID") {
                if let x = node.object as? AMLDataRefObject {
                    return decodeHID(obj: x).asString
                }
            }
        }
        return nil
    }


    func getDevices() -> [String] {
        guard let sb = get("\\_SB") else {
            fatalError("No \\_SB system bus node")
        }
        var devices: [String] = []
        walkNode(name: "\\_SB", node: sb) { (path, node) in
            if node.object is AMLDefDevice {
                var name = path
                if let hid = HIDForDevice(childNodes: node.childNodes) {
                    name += "\t[\(hid)]"
                    print(name)
                }
                devices.append(name)
            }
        }
        return devices
    }


    func dumpObjects() {
        walkNode(name: "\\", node: globalObjects) { (path, node) in
            print("ACPI: \(path)")
        }
    }


    func dumpDevices() {
        let devices = getDevices()
        for device in devices {
            print(device)
        }
        print("Have \(devices.count) devices")
        return
    }


    func runBody(root: String, body: (String, AMLNamedObj) -> ()) {
        guard let sb = get("\\") else {
            fatalError("\\ not found")
        }
        walkNode(name: root, node: sb) { (path, node) in
            if let obj = node.object {
                body(path, obj)
            }
        }
    }
}

