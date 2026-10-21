//
//  BluetoothManager.swift
//  RideLab
//
//  Created by Ely on 24/09/26.
//

import CoreBluetooth
import Observation

struct DiscoveredDevice: Identifiable {
    let id: UUID    // stable identifier assigned by macOS
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var services: [CBUUID]
}

@Observable
final class BluetoothManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // Standard cycling/fitness service UUIDs
    static let heartRate = CBUUID(string: "180D")
    static let cyclingPower = CBUUID(string: "1818")
    static let fitnessMachine = CBUUID(string: "1826")
    static let fitnessServices = [heartRate, cyclingPower, fitnessMachine]
    
    static let hearRateMeasurement = CBUUID(string: "2A37")
    static let cyclingPowerMeasurement = CBUUID(string: "2A63")
    
    var devices: [DiscoveredDevice] = []
    var isScanning = false
    var stateText = "Starting..."
    
    // Live data, now keyed by role rather than one slot each
    var heartRate: Int?
    var contactDetected: Bool?
    var power: Int?
    
    var connectedNames: [UUID: String] = [:] // peripheral id -> display name
    
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:] // must hold strong refs
    
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    
    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        // nil = report every device. Pass an array of UUIDs to filter
        central.scanForPeripherals(withServices: nil)
        isScanning = true
    }
    
    func stopScan() {
        central.stopScan()
        isScanning = false
    }
    
    func connect(_ device: DiscoveredDevice) {
        peripherals[device.id] = device.peripheral
        connectedNames[device.id] = device.name
        stateText = "Connecting to \(device.name)..."
        central.connect(device.peripheral)
    }
    
    func disconnect(_ id: UUID) {
        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    
    // Called when Bluetooth state changes (also once right after creation)
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    stateText = "Bluetooth ready"
        case .poweredOff:   stateText = "Bluetooth is off"
        case .unauthorized: stateText = "Permission denied (System Settings -> Privacy -> Bluetooth)"
        case .unsupported:  stateText = "Bluetooth not supported"
        default:            stateText = "Bluetooth unavailable"
        }
    }
    
    // Called every time an advertisement packet is received
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let device = DiscoveredDevice(id: peripheral.identifier,
                                      peripheral: peripheral,
                                      name: name,
                                      rssi: RSSI.intValue,
                                      services: services)
        
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device     // known device: update it
        } else {
            devices.append(device)      // new device: add it
        }
    }
    
    
    // MARK: - Connection callbacks
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stateText = "Connected to \(peripheral.name ?? "device")"
        peripheral.delegate = self                                             // receive peripheral callbacks
        peripheral.discoverServices([Self.heartRate, Self.cyclingPower])       // only ask for what we need
    }
    
    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        stateText = "Failed to connect: \(error?.localizedDescription ?? "unknown error")"
        peripherals[peripheral.identifier] = nil
        connectedNames[peripheral.identifier] = nil
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stateText = "Disconnected from \(peripheral.name ?? "device")"
        peripherals[peripheral.identifier] = nil
        connectedNames[peripheral.identifier] = nil
    }
    
    // MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            if service.uuid == Self.heartRate {
                peripheral.discoverCharacteristics([Self.hearRateMeasurement], for: service)
            } else if service.uuid == Self.cyclingPower {
                peripheral.discoverCharacteristics([Self.cyclingPowerMeasurement], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.hearRateMeasurement || characteristic.uuid == Self.cyclingPowerMeasurement {
                peripheral.setNotifyValue(true, for: characteristic)    // subscribe
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.hearRateMeasurement: parseHeartRate(data)
        case Self.cyclingPowerMeasurement: parsePower(data)
        default: break
        }
    }
    
    // MARK: - Parsing
    
    private func parseHeartRate(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        
        let flags = bytes[0]
        let is16Bit = (flags & 0x01) != 0
        
        if is16Bit {
            guard bytes.count >= 3 else { return }
            heartRate = Int(bytes[1]) | (Int(bytes[2]) << 8)     // little-endian
        } else {
            heartRate = Int(bytes[1])
        }
        
        // Bits 1-2: 0b10 = supported but no contact, 0b11 = contact detected
        let contact = (flags >> 1) & 0b11
        contactDetected = contact == 0b11 ? true : (contact == 0b10 ? false : nil)
    }
    
    private func parsePower(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }  // 2 flag bytes + 2 power bytes minimum
        
        // Power sits right after the flags, regardless of which optional fields follow
        let raw = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        power = Int(Int16(bitPattern: raw)) // reinterpret as signed
    }
}
