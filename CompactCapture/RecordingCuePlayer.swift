import AVFoundation
import Foundation

final class RecordingCuePlayer: NSObject, AVAudioPlayerDelegate {
    enum Cue {
        case start
        case end

        fileprivate var resourceName: String {
            switch self {
            case .start: "RecordStart"
            case .end: "RecordEnd"
            }
        }
    }

    private var player: AVAudioPlayer?
    private var completion: ((Bool) -> Void)?

    func play(_ cue: Cue, completion: @escaping (Bool) -> Void) {
        cancel()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try audioSession.setActive(true)

            guard let url = Bundle.main.url(
                forResource: cue.resourceName,
                withExtension: "wav",
                subdirectory: "RecordingCues"
            ) ?? Bundle.main.url(forResource: cue.resourceName, withExtension: "wav") else {
                completion(false)
                return
            }

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = 1
            player.numberOfLoops = 0
            player.prepareToPlay()

            self.player = player
            self.completion = completion
            if !player.play() {
                finish(successfully: false)
            }
        } catch {
            completion(false)
        }
    }

    func cancel() {
        player?.stop()
        player = nil
        completion = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(successfully: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(successfully: false)
    }

    private func finish(successfully: Bool) {
        player = nil
        let completion = completion
        self.completion = nil
        completion?(successfully)
    }
}
