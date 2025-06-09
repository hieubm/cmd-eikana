//
//  KeyEvent.swift
//  ⌘英かな
//
//  MIT License
//  Copyright (c) 2016 iMasanari
//

import Cocoa
import Foundation

var activeAppsList: [AppData] = []
var exclusionAppsList: [AppData] = []

var exclusionAppsDict: [String: String] = [:]

class KeyEvent: NSObject {
    var keyCode: CGKeyCode? = nil
    var isExclusionApp = false
    let bundleId = Bundle.main.infoDictionary?["CFBundleIdentifier"] as! String
    var hasConvertedEventLog: KeyMapping? = nil
    var config: [String: Any] = [:]

    override init() {
        super.init()
        
    }

    func start() {
       NSWorkspace.shared.notificationCenter.addObserver(self,
                                                           selector: #selector(KeyEvent.setActiveApp(_:)),
                                                           name: NSWorkspace.didActivateApplicationNotification,
                                                           object:nil)

        let checkOptionPrompt = kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString
        let options: CFDictionary = [checkOptionPrompt: true] as NSDictionary

        if !AXIsProcessTrustedWithOptions(options) {
            // アクセシビリティに設定されていない場合、設定されるまでループで待つ
            Timer.scheduledTimer(timeInterval: 1.0,
                                 target: self,
                                 selector: #selector(KeyEvent.watchAXIsProcess(_:)),
                                 userInfo: nil,
                                 repeats: true)
        }
        else {
            self.watch()
        }
    }

    @objc func watchAXIsProcess(_ timer: Timer) {
        if AXIsProcessTrusted() {
            timer.invalidate()
            self.watch()
        }
    }

    @objc func setActiveApp(_ notification: NSNotification) {
        let app = notification.userInfo!["NSWorkspaceApplicationKey"] as! NSRunningApplication

        if let name = app.localizedName, let id = app.bundleIdentifier {
            isExclusionApp = exclusionAppsDict[id] != nil

            if (id != bundleId && !isExclusionApp) {
                activeAppsList = activeAppsList.filter {$0.id != id}
                activeAppsList.insert(AppData(name: name, id: id), at: 0)

                if activeAppsList.count > 10 {
                    activeAppsList.removeLast()
                }
            }
        }
    }

    func watch() {
        // マウスのドラッグバグ回避のため、NSEventとCGEventを併用
        // CGEventのみでやる方法を捜索中
//        let nsEventMaskList: NSEvent.EventTypeMask = [
//            .leftMouseDown,
//            .leftMouseUp,
//            .rightMouseDown,
//            .rightMouseUp,
//            .otherMouseDown,
//            .otherMouseUp,
//            .scrollWheel
//        ]
//
//        NSEvent.addGlobalMonitorForEvents(matching: nsEventMaskList) {(event: NSEvent) -> Void in
//            self.keyCode = nil
//        }
//
//        NSEvent.addLocalMonitorForEvents(matching: nsEventMaskList) {(event: NSEvent) -> NSEvent? in
//            self.keyCode = nil
//            return event
//        }

        let eventMaskList = [
            CGEventType.keyDown.rawValue,
            CGEventType.keyUp.rawValue,
//            CGEventType.mediaKeyDown.rawValue,
//            CGEventType.mediaKeyUp.rawValue,
            CGEventType.flagsChanged.rawValue,
            CGEventType.otherMouseDown.rawValue,
            CGEventType.otherMouseUp.rawValue,
            CGEventType.scrollWheel.rawValue,
            UInt32(NX_SYSDEFINED) // Media key Event
        ]
        var eventMask: UInt32 = 0

        for mask in eventMaskList {
            eventMask |= (1 << mask)
        }

        let observer = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? in
                if let observer = refcon {
                    let mySelf = Unmanaged<KeyEvent>.fromOpaque(observer).takeUnretainedValue()
                    return mySelf.eventCallback(proxy: proxy, type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: observer
            ) else {
                print("failed to create event tap")
                exit(1)
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopRun()
    }

    func eventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if isExclusionApp {
            return Unmanaged.passUnretained(event)
        }

        if let mediaKeyEvent = MediaKeyEvent(event) {
            return mediaKeyEvent.keyDown ? mediaKeyDown(mediaKeyEvent) : mediaKeyUp(mediaKeyEvent)
        }
//        print("Debug - Type: \(type.rawValue)")
//        print("""
//"Debug
//- Val-1: \(event.getIntegerValueField(CGEventField.mouseEventSubtype))
//- Val-2 \(event.getIntegerValueField(.keyboardEventKeycode))
//- Val-3 \(event.getIntegerValueField(.mouseEventButtonNumber))
//- Val-4 \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
//- Val-5 \(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
//""")

        // print(event.getIntegerValueField(.keyboardEventKeycode))
        // print("keyCode: \(KeyboardShortcut(event).keyCode)")
        // print(KeyboardShortcut(event).toString())
//        print(event.sour)


//        print(event)
        switch type {
        case CGEventType.flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            if modifierMasks[keyCode] == nil {
                return Unmanaged.passUnretained(event)
            }
            return event.flags.rawValue & modifierMasks[keyCode]!.rawValue != 0 ?
                modifierKeyDown(event) : modifierKeyUp(event)

        case CGEventType.keyDown, CGEventType.otherMouseDown, CGEventType.scrollWheel:
            return keyDown(event)

        case CGEventType.keyUp, CGEventType.otherMouseUp:
            return keyUp(event)

        default:
            self.keyCode = nil

            return Unmanaged.passUnretained(event)
        }
    }
    
    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/zsh"
        task.standardInput = nil
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)!
        
        return output
    }

    func keyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        #if DEBUG
//             print(KeyboardShortcut(event).toString())
        #endif

        let originalKeyShortcut = KeyboardShortcut(event)
        let keyCode = originalKeyShortcut.keyCode
//        print("keyCode: \(keyCode)")
//        print(event.flags)
        
        if (keyCode == 122) {
            // F1
            let keyShortcut = KeyboardShortcut(event)
            if keyShortcut.isCommandDown() && keyShortcut.isShiftDown() {
                // Cmd + Shift + F1
                if (profile == "mappings") {
                    profile = "mappings_2"
                } else if (profile == "mappings_2") {
                    profile = "mappings_3"
                } else {
                    profile = "mappings"
                }
            
                UserDefaults.standard.set(profile , forKey: "profile")
                
                let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
                let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = [path]
                task.launch()
                exit(0)
            }
                
        }

        self.keyCode = nil

        if let keyTextField = activeKeyTextField {
            print("text field")
            keyTextField.shortcut = KeyboardShortcut(event)
            keyTextField.stringValue = keyTextField.shortcut!.toString()

            return nil
        }

        if hasConvertedEvent(event) {
//            print("Has event")
            if let event = getConvertedEvent(event) {
                let convertedKeyShortcut = KeyboardShortcut(event)
//                print("Converted Shortcut")
//                print(convertedKeyShortcut.keyCode)
                
                if convertedKeyShortcut.keyCode >= 98 && convertedKeyShortcut.keyCode <= 122 {
                    // Forward to Python if the target hotkey is Function keys
//                    print("Forwarded to Python")
                    let ret = shell("/usr/bin/python3 ~/Works/tools/key_mapper/main.py \(originalKeyShortcut.keyCode) \(originalKeyShortcut.isCommandDown() ? 1 : 0) \(originalKeyShortcut.isShiftDown() ? 1 : 0)")
//                    print(ret)
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    func keyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        self.keyCode = nil

        if hasConvertedEvent(event) {
            if let event = getConvertedEvent(event) {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    func modifierKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        #if DEBUG
            print(KeyboardShortcut(event).toString())
        #endif

        self.keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if let keyTextField = activeKeyTextField, keyTextField.isAllowModifierOnly {
            let shortcut = KeyboardShortcut(event)

            keyTextField.shortcut = shortcut
            keyTextField.stringValue = shortcut.toString()
        }

        return Unmanaged.passUnretained(event)
    }

    func modifierKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if activeKeyTextField != nil {
            self.keyCode = nil
        }
        else if self.keyCode == CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) {
            if let convertedEvent = getConvertedEvent(event) {
                KeyboardShortcut(convertedEvent).postEvent()
            }
        }

        self.keyCode = nil

        return Unmanaged.passUnretained(event)
    }

    func mediaKeyDown(_ mediaKeyEvent: MediaKeyEvent) -> Unmanaged<CGEvent>? {
        #if DEBUG
            print(KeyboardShortcut(keyCode: CGKeyCode(1000 + mediaKeyEvent.keyCode), flags: mediaKeyEvent.flags).toString())
        #endif

        self.keyCode = nil
        

//        let keyCode = KeyboardShortcut(mediaKeyEvent).keyCode
//        print("keyCode: \(keyCode)")
        
//        print(mediaKeyEvent.flags)
//        print("mediake")
//        print(KeyboardShortcut(keyCode: CGKeyCode(1000 + mediaKeyEvent.keyCode), flags: mediaKeyEvent.flags).toString())
        

        if let keyTextField = activeKeyTextField {
//            if keyTextField.isAllowModifierOnly {
            print("media text field")
                keyTextField.shortcut = KeyboardShortcut(keyCode: CGKeyCode(1000 + mediaKeyEvent.keyCode),
                                                         flags: mediaKeyEvent.flags)
                keyTextField.stringValue = keyTextField.shortcut!.toString()
//            }

            return nil
        }

        if hasConvertedEvent(mediaKeyEvent.event, keyCode: CGKeyCode(1000 + mediaKeyEvent.keyCode)) {
            if let event = getConvertedEvent(mediaKeyEvent.event, keyCode: CGKeyCode(1000 + mediaKeyEvent.keyCode)) {
//                print(KeyboardShortcut(event).toString())

//                print(event.type == CGEventType.keyDown)
                event.post(tap: CGEventTapLocation.cghidEventTap)
            }
            return nil
        }

        return Unmanaged.passUnretained(mediaKeyEvent.event)
    }

    func mediaKeyUp(_ mediaKeyEvent: MediaKeyEvent) -> Unmanaged<CGEvent>? {
        // if hasConvertedEvent(mediaKeyEvent.event, keyCode: CGKeyCode(1000 + mediaKeyEvent.keyCode)) {
        //     if let event = getConvertedEvent(mediaKeyEvent.event, keyCode: CGKeyCode(1000 + Int(mediaKeyEvent.keyCode))) {
                // event.post(tap: CGEventTapLocation.cghidEventTap)
        //     }
        //     return nil
        // }

        return Unmanaged.passUnretained(mediaKeyEvent.event)
    }

    func hasConvertedEvent(_ event: CGEvent, keyCode: CGKeyCode? = nil) -> Bool {
        let shortcht = event.type.rawValue == UInt32(NX_SYSDEFINED) ?
            KeyboardShortcut(keyCode: 0, flags: MediaKeyEvent(event)!.flags) : KeyboardShortcut(event)

        if let mappingList = shortcutList[keyCode ?? shortcht.keyCode] {
            for mappings in mappingList {
                if shortcht.isCover(mappings.input) {
                    hasConvertedEventLog = mappings
                    return true
                }
            }
        }
        hasConvertedEventLog = nil
        return false
    }
    func getConvertedEvent(_ event: CGEvent, keyCode: CGKeyCode? = nil) -> CGEvent? {
        var event = event

        if event.type.rawValue == UInt32(NX_SYSDEFINED) {
//            print("Convert media event")
            let flags = MediaKeyEvent(event)!.flags
            event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            event.flags = flags
        }

        let shortcht = KeyboardShortcut(event)

        func getEvent(_ mappings: KeyMapping) -> CGEvent? {
            if mappings.output.keyCode == 999 {
                // 999 is Disable
                return nil
            }

            if (event.type == CGEventType.otherMouseDown) {
                print ("Cnv aouse down")
                event.type = CGEventType.keyDown
                event.setIntegerValueField(.mouseEventNumber, value: 0)
                event.setIntegerValueField(.mouseEventClickState, value: 0)
                event.setIntegerValueField(.mouseEventPressure, value: 0)
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
//                event.flags = CGEventFlags(rawValue: 256)
            } else if (event.type == CGEventType.otherMouseUp) {
                print ("Cnv aouse up")
                event.type = CGEventType.keyUp
                event.setIntegerValueField(.mouseEventNumber, value: 0)
                event.setIntegerValueField(.mouseEventClickState, value: 0)
                event.setIntegerValueField(.mouseEventPressure, value: 0)
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
//                event.
//                event.flags = CGEventFlags(rawValue: 256)

            } else if (event.type == CGEventType.scrollWheel) {
                print ("Cnv aouse up")
                event.type = CGEventType.keyDown
                event.setIntegerValueField(.mouseEventNumber, value: 0)
                event.setIntegerValueField(.mouseEventClickState, value: 0)
                event.setIntegerValueField(.mouseEventPressure, value: 0)
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
//                event.
//                event.flags = CGEventFlags(rawValue: 256)

            } else {
                print ("KB")
            }
            print(event.flags)

            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(mappings.output.keyCode))
            event.flags = CGEventFlags(
                rawValue: (event.flags.rawValue & ~mappings.input.flags.rawValue) | mappings.output.flags.rawValue
            )

            return event
        }

//        print("kc \(shortcht.keyCode)")

        if let mappingList = shortcutList[keyCode ?? shortcht.keyCode] {
//            print("kc \(mappingList)")
            if let mappings = hasConvertedEventLog,
                shortcht.isCover(mappings.input) {
//                print("route 1")
//                print(mappings)
                return getEvent(mappings)
            }
//            print("route 2")
            for mappings in mappingList {
                if shortcht.isCover(mappings.input) {
                    return getEvent(mappings)
                }
            }
        }
//        print("No mapping")
        return nil
    }
}

let modifierMasks: [CGKeyCode: CGEventFlags] = [
    54: CGEventFlags.maskCommand,
    55: CGEventFlags.maskCommand,
    56: CGEventFlags.maskShift,
    60: CGEventFlags.maskShift,
    59: CGEventFlags.maskControl,
    62: CGEventFlags.maskControl,
    58: CGEventFlags.maskAlternate,
    61: CGEventFlags.maskAlternate,
    63: CGEventFlags.maskSecondaryFn,
    57: CGEventFlags.maskAlphaShift
]


//            print("mouseEventNumber \(event.getIntegerValueField(.mouseEventNumber))")
//            print("mouseEventClickState \(event.getIntegerValueField(.mouseEventClickState))")
//            print("mouseEventPressure \(event.getIntegerValueField(.mouseEventPressure))")
//            print("mouseEventButtonNumber \(event.getIntegerValueField(.mouseEventButtonNumber))")
//            print("mouseEventDeltaX \(event.getIntegerValueField(.mouseEventDeltaX))")
//            print("mouseEventDeltaY \(event.getIntegerValueField(.mouseEventDeltaY))")
//            print("mouseEventInstantMouser \(event.getIntegerValueField(.mouseEventInstantMouser))")
//            print("mouseEventSubtype \(event.getIntegerValueField(.mouseEventSubtype))")
//            print("keyboardEventAutorepeat \(event.getIntegerValueField(.keyboardEventAutorepeat))")
//            print("keyboardEventKeycode \(event.getIntegerValueField(.keyboardEventKeycode))")
//            print("keyboardEventKeyboardType \(event.getIntegerValueField(.keyboardEventKeyboardType))")
//            print("scrollWheelEventDeltaAxis1 \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))")
//            print("scrollWheelEventDeltaAxis2 \(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))")
//            print("scrollWheelEventDeltaAxis3 \(event.getIntegerValueField(.scrollWheelEventDeltaAxis3))")
//            print("scrollWheelEventFixedPtDeltaAxis1 \(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1))")
//            print("scrollWheelEventFixedPtDeltaAxis2 \(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2))")
//            print("scrollWheelEventFixedPtDeltaAxis3 \(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis3))")
//            print("scrollWheelEventPointDeltaAxis1 \(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))")
//            print("scrollWheelEventPointDeltaAxis2 \(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))")
//            print("scrollWheelEventPointDeltaAxis3 \(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3))")
//            print("scrollWheelEventScrollPhase \(event.getIntegerValueField(.scrollWheelEventScrollPhase))")
//            print("scrollWheelEventScrollCount \(event.getIntegerValueField(.scrollWheelEventScrollCount))")
//            print("scrollWheelEventMomentumPhase \(event.getIntegerValueField(.scrollWheelEventMomentumPhase))")
//            print("scrollWheelEventInstantMouser \(event.getIntegerValueField(.scrollWheelEventInstantMouser))")
//            print("tabletEventPointX \(event.getIntegerValueField(.tabletEventPointX))")
//            print("tabletEventPointY \(event.getIntegerValueField(.tabletEventPointY))")
//            print("tabletEventPointZ \(event.getIntegerValueField(.tabletEventPointZ))")
//            print("tabletEventPointButtons \(event.getIntegerValueField(.tabletEventPointButtons))")
//            print("tabletEventPointPressure \(event.getIntegerValueField(.tabletEventPointPressure))")
//            print("tabletEventTiltX \(event.getIntegerValueField(.tabletEventTiltX))")
//            print("tabletEventTiltY \(event.getIntegerValueField(.tabletEventTiltY))")
//            print("tabletEventRotation \(event.getIntegerValueField(.tabletEventRotation))")
//            print("tabletEventTangentialPressure \(event.getIntegerValueField(.tabletEventTangentialPressure))")
//            print("tabletEventDeviceID \(event.getIntegerValueField(.tabletEventDeviceID))")
//            print("tabletEventVendor1 \(event.getIntegerValueField(.tabletEventVendor1))")
//            print("tabletEventVendor2 \(event.getIntegerValueField(.tabletEventVendor2))")
//            print("tabletEventVendor3 \(event.getIntegerValueField(.tabletEventVendor3))")
//            print("tabletProximityEventVendorID \(event.getIntegerValueField(.tabletProximityEventVendorID))")
//            print("tabletProximityEventTabletID \(event.getIntegerValueField(.tabletProximityEventTabletID))")
//            print("tabletProximityEventPointerID \(event.getIntegerValueField(.tabletProximityEventPointerID))")
//            print("tabletProximityEventDeviceID \(event.getIntegerValueField(.tabletProximityEventDeviceID))")
//            print("tabletProximityEventSystemTabletID \(event.getIntegerValueField(.tabletProximityEventSystemTabletID))")
//            print("tabletProximityEventVendorPointerType \(event.getIntegerValueField(.tabletProximityEventVendorPointerType))")
//            print("tabletProximityEventVendorPointerSerialNumber \(event.getIntegerValueField(.tabletProximityEventVendorPointerSerialNumber))")
//            print("tabletProximityEventVendorUniqueID \(event.getIntegerValueField(.tabletProximityEventVendorUniqueID))")
//            print("tabletProximityEventCapabilityMask \(event.getIntegerValueField(.tabletProximityEventCapabilityMask))")
//            print("tabletProximityEventPointerType \(event.getIntegerValueField(.tabletProximityEventPointerType))")
//            print("tabletProximityEventEnterProximity \(event.getIntegerValueField(.tabletProximityEventEnterProximity))")
//            print("eventTargetProcessSerialNumber \(event.getIntegerValueField(.eventTargetProcessSerialNumber))")
//            print("eventTargetUnixProcessID \(event.getIntegerValueField(.eventTargetUnixProcessID))")
//            print("eventSourceUnixProcessID \(event.getIntegerValueField(.eventSourceUnixProcessID))")
//            print("eventSourceUserData \(event.getIntegerValueField(.eventSourceUserData))")
//            print("eventSourceUserID \(event.getIntegerValueField(.eventSourceUserID))")
//            print("eventSourceGroupID \(event.getIntegerValueField(.eventSourceGroupID))")
//            print("eventSourceStateID \(event.getIntegerValueField(.eventSourceStateID))")
//            print("scrollWheelEventIsContinuous \(event.getIntegerValueField(.scrollWheelEventIsContinuous))")
//            print("mouseEventWindowUnderMousePointer \(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))")
//            print("mouseEventWindowUnderMousePointerThatCanHandleThisEvent \(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))")
//            print("eventUnacceleratedPointerMovementX \(event.getIntegerValueField(.eventUnacceleratedPointerMovementX))")
//            print("eventUnacceleratedPointerMovementY \(event.getIntegerValueField(.eventUnacceleratedPointerMovementY))")
