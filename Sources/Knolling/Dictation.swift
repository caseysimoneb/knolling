import AVFoundation
import Speech

/// Speech to text for notes, on-device when the Mac supports it.
/// Words land in the field exactly as heard; nothing is cleaned up.
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0 // late results from a cancelled run are ignored

    func toggle(base: String, onText: @escaping (String) -> Void) {
        if isListening { finish(); return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.problem = "Turn on Speech Recognition for Knolling in System Settings → Privacy & Security."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.problem = "Turn on the Microphone for Knolling in System Settings → Privacy & Security."
                            return
                        }
                        self.begin(base: base, onText: onText)
                    }
                }
            }
        }
    }

    /// Stop listening and let the last words arrive.
    func finish() {
        guard isListening else { return }
        request?.endAudio()
        stopEngine()
    }

    /// Stop listening and drop anything still in flight (used when a note is submitted).
    func cancel() {
        generation += 1
        task?.cancel()
        stopEngine()
        request = nil
        task = nil
    }

    private func begin(base: String, onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Dictation isn't available right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't start the microphone."
            return
        }

        generation += 1
        let run = generation
        let prefix = base.trimmingCharacters(in: .whitespacesAndNewlines)
        self.request = request
        problem = nil
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, run == self.generation else { return }
                if let result {
                    let heard = result.bestTranscription.formattedString
                    onText(prefix.isEmpty ? heard : prefix + " " + heard)
                }
                if error != nil || result?.isFinal == true {
                    self.stopEngine()
                    self.request = nil
                    self.task = nil
                }
            }
        }
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        isListening = false
    }
}
