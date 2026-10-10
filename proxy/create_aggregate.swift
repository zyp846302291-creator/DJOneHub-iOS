#!/usr/bin/env swift
// create_aggregate.swift — Creates an Aggregate Audio Device combining Mac speakers + BlackHole
// This allows DJOneHub to output audio to both Mac speakers AND BlackHole simultaneously.
// Usage: ./create_aggregate

import CoreAudio
import Foundation

// MARK: - Find device UID by name substring
func findDeviceUID(named name: String) -> (AudioDeviceID, String)? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices)

    for dev in devices {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var devName: CFString = "" as CFString
        var ns = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &ns, &devName)

        if (devName as String).lowercased().contains(name.lowercased()) {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uid: CFString = "" as CFString
            var us = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &us, &uid)
            return (dev, uid as String)
        }
    }
    return nil
}

// Find Mac built-in output and BlackHole
guard let (macDev, macUID) = findDeviceUID(named: "MacBook Pro扬声器") ?? findDeviceUID(named: "MacBook Pro") else {
    fputs("Error: can't find MacBook Pro speakers\n", stderr)
    exit(1)
}
guard let (bhDev, bhUID) = findDeviceUID(named: "BlackHole") else {
    fputs("Error: can't find BlackHole device\n", stderr)
    exit(1)
}

fputs("Mac output: [\(macDev)] UID=\(macUID)\n", stderr)
fputs("BlackHole:  [\(bhDev)] UID=\(bhUID)\n", stderr)

// Check if aggregate already exists
var checkAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var ds: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &checkAddr, 0, nil, &ds)
let dc = Int(ds) / MemoryLayout<AudioDeviceID>.size
var devs = [AudioDeviceID](repeating: 0, count: dc)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &checkAddr, 0, nil, &ds, &devs)

for d in devs {
    var na = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var n: CFString = "" as CFString
    var s = UInt32(MemoryLayout<CFString>.size)
    AudioObjectGetPropertyData(d, &na, 0, nil, &s, &n)
    if (n as String).contains("DJOneHub Mix") {
        fputs("Found old 'DJOneHub Mix' [\(d)], destroying...\n", stderr)
        AudioHardwareDestroyAggregateDevice(d)
    }
}
fputs("Creating new stacked Multi-Output Device...\n", stderr)

// Create Multi-Output Device (stacked aggregate)
// kAudioAggregateDeviceIsStackedKey makes it a multi-output device:
// audio sent here gets replicated to all sub-devices (Mac speakers + BlackHole)
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "DJOneHub Mix",
    kAudioAggregateDeviceUIDKey as String: "com.djonehub.mix.\(UUID().uuidString.prefix(8))",
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: macUID],
        [kAudioSubDeviceUIDKey as String: bhUID],
    ],
    kAudioAggregateDeviceTapListKey as String: [] as [[String: Any]],
    kAudioAggregateDeviceIsPrivateKey as String: false,
    kAudioAggregateDeviceIsStackedKey as String: true,
]

let aggDesc = desc as NSDictionary
let mutableDesc = aggDesc.mutableCopy() as! CFMutableDictionary
var aggID: AudioObjectID = kAudioObjectUnknown
let status = AudioHardwareCreateAggregateDevice(mutableDesc, &aggID)
guard status == noErr else {
    fputs("Error: AudioHardwareCreateAggregateDevice failed: \(status)\n", stderr)
    exit(1)
}

fputs("✅ Created aggregate device 'DJOneHub Mix': ID=\(aggID)\n", stderr)

// Set as default output device
var defaultOutAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var newDefault = aggID
AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutAddr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &newDefault)
fputs("✅ Set as default output device\n", stderr)
