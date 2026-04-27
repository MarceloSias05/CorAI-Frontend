import Foundation
import Combine

@Observable
final class RecordingViewModel {

    // MARK: - State

    var isRecording = false
    var elapsedSeconds: Int = 0
    var liveSamples: [Double] = []
    var bpm: Int = 72
    var disconnectionError: String?

    // MARK: - Completion callback

    var onSessionSaved: ((ECGSession) -> Void)?

    // MARK: - Private

    private var recordedSegments: [ECGSecondSegment] = []
    private var timer: AnyCancellable?
    private var ecgTimer: AnyCancellable?
    private var connectionMonitor: AnyCancellable?
    private let deviceId: String
    private let recordingRepository: RecordingRepositoryProtocol
    private let session: SessionManager
    private let dataSource: ECGDataSource
    private let bleManager: BLEManager

    // MARK: - Init

    init(
        deviceId: String = "Camisa #829",
        recordingRepository: RecordingRepositoryProtocol = RecordingRepository(),
        session: SessionManager = .shared,
        dataSource: ECGDataSource? = nil,
        bleManager: BLEManager = .shared
    ) {
        self.deviceId = deviceId
        self.recordingRepository = recordingRepository
        self.session = session
        self.bleManager = bleManager
        self.dataSource = dataSource ?? BLEDataSource(bleManager: bleManager)
        self.liveSamples = self.dataSource.generateStream(complexes: 4, samplesPerComplex: 60)
    }

    // MARK: - Start Recording

    func startRecording() {
        isRecording = true
        elapsedSeconds = 0
        recordedSegments = []
        disconnectionError = nil
        liveSamples = dataSource.generateStream(complexes: 4, samplesPerComplex: 60)

        // Monitor desconexión BLE durante grabación
        connectionMonitor = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isRecording else { return }
                if !self.bleManager.isConnected {
                    self.handleBLEDisconnection()
                }
            }

        // 1-second tick: accumulate one second of ECG data
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }

        // Fast tick for live animation (~200ms)
        ecgTimer = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.advanceLiveECG()
            }
    }

    // MARK: - Stop Recording

    func stopRecording() {
        isRecording = false
        timer?.cancel()
        timer = nil
        ecgTimer?.cancel()
        ecgTimer = nil
        connectionMonitor?.cancel()
        connectionMonitor = nil

        let sessionStart = Date().addingTimeInterval(-Double(elapsedSeconds))
        let allSamples   = recordedSegments.flatMap { $0.samples }

        let ecgSession = ECGSession(
            date: sessionStart,
            durationSeconds: elapsedSeconds,
            deviceId: deviceId,
            filterOn: true,
            status: .normal,
            ecgSamples: Array(allSamples.prefix(120)),
            fullEcgData: recordedSegments
        )

        onSessionSaved?(ecgSession)

        // POST al backend en background — no bloquea la UI ni el guardado local
        let payload = SensorDataPayload.from(
            normalizedSamples: allSamples,
            sessionStart: sessionStart
        )
        let userId = session.userId
        Task {
            do {
                try await recordingRepository.ingestECG(userId: userId, payload: payload)
            } catch {
                print("[Recording] ingest error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Formatted elapsed time

    var elapsedFormatted: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Private

    private func tick() {
        // Generate ~1.2 PQRST complexes worth of samples for this second
        let segment = ECGSecondSegment(
            id: elapsedSeconds,
            samples: dataSource.generateStream(complexes: 2, samplesPerComplex: 60)
        )
        recordedSegments.append(segment)
        elapsedSeconds += 1

        // Simulate slight BPM variation
        bpm = Int.random(in: 68...78)
    }

    private func advanceLiveECG() {
        let shiftSize = 4
        var buffer = liveSamples
        buffer.removeFirst(min(shiftSize, buffer.count))

        let fragment = dataSource.generateComplex(sampleCount: 60)
        let slice = Array(fragment.prefix(shiftSize)).map { $0 + Double.random(in: -0.005...0.005) }
        buffer.append(contentsOf: slice)

        liveSamples = buffer
    }

    private func handleBLEDisconnection() {
        isRecording = false
        disconnectionError = bleManager.errorMessage ?? "Arduino desconectado durante la grabación"
        timer?.cancel()
        timer = nil
        ecgTimer?.cancel()
        ecgTimer = nil
        connectionMonitor?.cancel()
        connectionMonitor = nil
    }
}
