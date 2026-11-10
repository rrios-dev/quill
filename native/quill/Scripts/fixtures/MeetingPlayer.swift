import AVFAudio
import Foundation

// A stand-in meeting app for Scripts/meetings-agent.sh: plays one audio file and quits.
// Built into an .app so Core Audio reports it under a bundle identifier, as Teams or
// Zoom are, and an agent can name it to Quill.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let player = try AVAudioPlayer(contentsOf: url)
player.play()
while player.isPlaying { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
