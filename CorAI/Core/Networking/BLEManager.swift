import Foundation
import CoreBluetooth
import Combine

@Observable
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - State

    var isConnected = false
    var isScanning = false
    var errorMessage: String?

    // Buffer de datos crudos del Arduino (V, t_us)
    private(set) var recentSamples: [(voltage: Int, timestamp: UInt32)] = []

    // MARK: - Private

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var ecgLevelCharacteristic: CBCharacteristic?
    private var timestampCharacteristic: CBCharacteristic?

    private let kServiceUUID = CBUUID(string: "180A")
    private let kECGLevelUUID = CBUUID(string: "2A19")  // Heart Rate (reutilizado para V)
    private let kTimestampUUID = CBUUID(string: "2A3B")  // Report Time

    private let maxSampleBufferSize = 12000  // 120 Hz * 100 seconds

    // MARK: - Singleton

    static let shared = BLEManager()

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public Methods

    func startScanning() {
        guard let centralManager = centralManager, centralManager.state == .poweredOn else {
            errorMessage = "Bluetooth no disponible"
            return
        }

        isScanning = true
        errorMessage = nil
        centralManager.scanForPeripherals(withServices: [kServiceUUID], options: nil)
    }

    func stopScanning() {
        isScanning = false
        centralManager?.stopScan()
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[BLE] Bluetooth encendido")
            startScanning()
        case .poweredOff:
            errorMessage = "Bluetooth apagado"
            isConnected = false
        case .unauthorized:
            errorMessage = "Permiso Bluetooth denegado"
        case .unsupported:
            errorMessage = "Bluetooth no soportado"
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        if peripheral.name == "CorAI-ECG" {
            print("[BLE] Encontrado CorAI-ECG")
            stopScanning()
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLE] Conectado a \(peripheral.name ?? "Unknown")")
        isConnected = true
        errorMessage = nil
        recentSamples = []
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLE] Fallo de conexión: \(error?.localizedDescription ?? "Unknown")")
        errorMessage = "No se pudo conectar al Arduino"
        isConnected = false
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLE] Desconectado")
        isConnected = false
        errorMessage = "Arduino desconectado"
        recentSamples = []
        startScanning()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            print("[BLE] No services found")
            return
        }

        for service in services {
            if service.uuid == kServiceUUID {
                peripheral.discoverCharacteristics([kECGLevelUUID, kTimestampUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {
            print("[BLE] No characteristics found")
            return
        }

        for characteristic in characteristics {
            if characteristic.uuid == kECGLevelUUID {
                ecgLevelCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == kTimestampUUID {
                timestampCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            return
        }

        if characteristic.uuid == kECGLevelUUID {
            let voltage = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(as: UInt16.self) }))

            // Buscar timestamp más reciente
            if let lastSample = recentSamples.last {
                let newSample = (voltage: voltage, timestamp: lastSample.timestamp)
                addSample(newSample)
            }
        } else if characteristic.uuid == kTimestampUUID {
            let timestamp = UInt32(littleEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) })

            // Buscar voltaje más reciente
            if let lastSample = recentSamples.last {
                let newSample = (voltage: lastSample.voltage, timestamp: timestamp)
                recentSamples[recentSamples.count - 1] = newSample
            } else {
                let newSample = (voltage: 0, timestamp: timestamp)
                addSample(newSample)
            }
        }
    }

    // MARK: - Private

    private func addSample(_ sample: (voltage: Int, timestamp: UInt32)) {
        recentSamples.append(sample)

        if recentSamples.count > maxSampleBufferSize {
            recentSamples.removeFirst(recentSamples.count - maxSampleBufferSize)
        }
    }
}
