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
    
    var devices: [DiscoveredDevice] = []
    var isScanning = false
    var stateText = "Starting..."
    var heartRate: Int?
    var connectedName: String?
    var contactDetected: Bool?
    
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    
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
        stopScan()
        connectedPeripheral = device.peripheral
        connectedName = device.name
        stateText = "Connecting to \(device.name)..."
        central.connect(device.peripheral)
    }
    
    func disconnect() {
        if let p = connectedPeripheral {
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
            ?? advertisementData[CBAdvertisementDataServiceUUIDsKey] as? String
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
        peripheral.delegate = self                          // receive peripheral callbacks
        peripheral.discoverServices([Self.heartRate])       // only ask for what we need
    }
    
    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        stateText = "Failed to connect: \(error?.localizedDescription ?? "unknown error")"
        connectedPeripheral = nil
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stateText = "Disconnected"
        connectedPeripheral = nil
        connectedName = nil
        heartRate = nil
        contactDetected = nil
    }
    
    // MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.heartRate {
            peripheral.discoverCharacteristics([Self.hearRateMeasurement], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? []
        where characteristic.uuid == Self.hearRateMeasurement {
            peripheral.setNotifyValue(true, for: characteristic)    // subscribe
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.hearRateMeasurement,
              let data = characteristic.value else { return }
        parseHeartRate(data)
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
}
