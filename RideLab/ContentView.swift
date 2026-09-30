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
                if ble.connectedName != nil {
                    Button("Disconnect") {ble.disconnect() }
                } else {
                    Toggle("Fitness devices only", isOn: $onlyFitness)
                    Button(ble.isScanning ? "Stop" : "Scan") {
                        ble.isScanning ? ble.stopScan() : ble.startScan()
                    }
                }
            }
            
            if let name = ble.connectedName {
                VStack(spacing: 8) {
                    Text(name).foregroundStyle(.secondary)
                    Text(ble.heartRate.map {"♥ \($0)"} ?? "♥ --")
                        .font(.system(size: 72, weight: .bold))
                    if ble.contactDetected == false {
                        Text("No skin contact. Moisten the strap")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                        Button("Connect") { ble.connect(device) }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

#Preview {
    ContentView()
}
