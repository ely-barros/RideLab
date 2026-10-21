import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @State private var ble = BluetoothManager()
    @State private var onlyFitness = true
    
    private var visibleDevices: [DiscoveredDevice] {
        ble.devices
            .filter { device in
                !onlyFitness || device.services.contains { BluetoothManager.fitnessServices.contains($0) }
            }
            .sorted { $0.rssi > $1.rssi }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ble.stateText).font(.headline)
                Spacer()
                Toggle("Fitness devices only", isOn: $onlyFitness)
                Button(ble.isScanning ? "Stop" : "Scan") {
                    ble.isScanning ? ble.stopScan() : ble.startScan()
                }
            }
            
            HStack(spacing: 40) {
                VStack {
                    Text(ble.power.map { "\($0) W" } ?? "-- W")
                        .font(.system(size: 56, weight: .bold))
                    Text("Power")
                }
                VStack {
                    Text(ble.heartRate.map { "\($0)" } ?? "--")
                        .font(.system(size: 56, weight: .bold))
                    Text("♥ Heart rate")
                    if ble.contactDetected == false {
                        Text("No contact").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            
            List(visibleDevices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        Text(device.services.map(\.uuidString).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(device.rssi) dBm").foregroundStyle(.secondary)
                    if ble.connectedNames[device.id] != nil {
                        Button("Disconnect") { ble.disconnect(device.id) }
                    } else {
                        Button("Connect") { ble.connect(device) }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
    }
}

#Preview {
    ContentView()
}
