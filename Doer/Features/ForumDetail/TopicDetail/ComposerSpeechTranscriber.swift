import Foundation
import Speech

enum ComposerSpeechTranscriber {
    enum TranscribeError: Error, LocalizedError {
        case recognizerUnavailable
        case notAuthorized
        case emptyResult
        case retry

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return String(localized: "speech.unavailable", defaultValue: "当前无法使用语音识别")
            case .notAuthorized:
                return String(localized: "speech.not_authorized", defaultValue: "没有语音识别权限")
            case .emptyResult:
                return String(localized: "speech.empty", defaultValue: "没有听清，请按住再说一次")
            case .retry:
                return String(localized: "speech.retry", defaultValue: "识别失败，请再试一次")
            }
        }
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func transcribeChinese(fileURL: URL) async throws -> String {
        let status = await requestAuthorization()
        guard status == .authorized else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable
        else {
            throw TranscribeError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false
        return try await withCheckedThrowingContinuation { continuation in
            final class TaskBox {
                var task: SFSpeechRecognitionTask?
                var recognizer: SFSpeechRecognizer?
            }
            let box = TaskBox()
            box.recognizer = recognizer
            var finished = false
            box.task = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: mappedError(error))
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                box.task = nil
                box.recognizer = nil
                if text.isEmpty {
                    continuation.resume(throwing: TranscribeError.emptyResult)
                } else {
                    continuation.resume(returning: text)
                }
            }
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        mappedError(error).localizedDescription
    }

    private static func mappedError(_ error: Error) -> Error {
        if error is TranscribeError { return error }
        let nsError = error as NSError
        let blob = [
            error.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if nsError.code == 1110
            || blob.contains("no speech")
            || blob.contains("speech detected")
        {
            return TranscribeError.emptyResult
        }
        if blob.contains("not authorized")
            || blob.contains("denied")
            || nsError.code == 1700
        {
            return TranscribeError.notAuthorized
        }
        if blob.contains("unavailable") {
            return TranscribeError.recognizerUnavailable
        }
        return TranscribeError.retry
    }
}
