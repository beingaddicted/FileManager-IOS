import SwiftUI
import AVKit
import AVFoundation

// MARK: - Media Player (Audio + Video)

struct MediaPlayerView: View {
    let url: URL
    let itemType: FileItemType

    @StateObject private var playerVM: MediaPlayerViewModel
    @State private var showControls: Bool = true
    @State private var controlsTimer: Timer?

    init(url: URL, itemType: FileItemType) {
        self.url      = url
        self.itemType = itemType
        self._playerVM = StateObject(wrappedValue: MediaPlayerViewModel(url: url))
    }

    var body: some View {
        ZStack {
            if itemType == .video {
                videoView
            } else {
                audioView
            }
        }
        .onAppear  { playerVM.play() }
        .onDisappear { playerVM.pause() }
    }

    // MARK: - Video

    private var videoView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayerRepresented(player: playerVM.player)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showControls.toggle() }
                    resetControlsTimer()
                }

            if showControls {
                videoControls
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var videoControls: some View {
        VStack {
            Spacer()
            VStack(spacing: 0) {
                // Scrubber
                Slider(
                    value: Binding(
                        get: { playerVM.currentTime },
                        set: { playerVM.seek(to: $0) }
                    ),
                    in: 0...(playerVM.duration > 0 ? playerVM.duration : 1)
                )
                .accentColor(.white)
                .padding(.horizontal, 20)

                HStack {
                    Text(playerVM.currentTimeFormatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                    Spacer()
                    Text(playerVM.durationFormatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 24)

                HStack(spacing: 40) {
                    Button { playerVM.skipBackward() } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }

                    Button { playerVM.togglePlayPause() } label: {
                        Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                    }

                    Button { playerVM.skipForward() } label: {
                        Image(systemName: "goforward.10")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Audio

    private var audioView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Album art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 220, height: 220)
                Image(systemName: "music.note")
                    .font(.system(size: 80))
                    .foregroundStyle(.purple)
            }

            // Title
            VStack(spacing: 6) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(url.pathExtension.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)

            // Progress
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { playerVM.currentTime },
                        set: { playerVM.seek(to: $0) }
                    ),
                    in: 0...(playerVM.duration > 0 ? playerVM.duration : 1)
                )
                .padding(.horizontal, 32)

                HStack {
                    Text(playerVM.currentTimeFormatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(playerVM.durationFormatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 36)
            }

            // Controls
            HStack(spacing: 44) {
                Button { playerVM.skipBackward() } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title)
                }

                Button { playerVM.togglePlayPause() } label: {
                    ZStack {
                        Circle()
                            .fill(.tint)
                            .frame(width: 64, height: 64)
                        Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }

                Button { playerVM.skipForward() } label: {
                    Image(systemName: "goforward.10")
                        .font(.title)
                }
            }
            .foregroundStyle(.primary)

            // Volume
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $playerVM.volume, in: 0...1)
                    .frame(maxWidth: 200)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48)

            Spacer()
        }
    }

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            Task { @MainActor in
                withAnimation { showControls = false }
            }
        }
    }
}

// MARK: - Video UIViewRepresentable

struct VideoPlayerRepresented: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view        = UIView(frame: .zero)
        let layer       = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame     = view.bounds
        view.layer.addSublayer(layer)
        context.coordinator.playerLayer = layer
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.playerLayer?.frame = view.bounds
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var playerLayer: AVPlayerLayer?
        deinit { playerLayer?.player = nil }
    }
}

// MARK: - MediaPlayerViewModel

@MainActor
final class MediaPlayerViewModel: ObservableObject {
    @Published var isPlaying: Bool   = false
    @Published var currentTime: Double = 0
    @Published var duration: Double  = 0
    @Published var volume: Float     = 1.0 {
        didSet { player.volume = volume }
    }

    let player: AVPlayer
    private var timeObserver: Any?

    init(url: URL) {
        let item    = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)

        Task {
            await loadDuration(item: item)
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.player.seek(to: .zero)
            }
        }
    }

    deinit {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
        }
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
    }

    func skipForward()  { seek(to: min(currentTime + 10, duration)) }
    func skipBackward() { seek(to: max(currentTime - 10, 0)) }

    var currentTimeFormatted: String { format(seconds: currentTime) }
    var durationFormatted:    String { format(seconds: duration) }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let m = Int(seconds / 60)
        let s = Int(seconds.truncatingRemainder(dividingBy: 60))
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func loadDuration(item: AVPlayerItem) async {
        let dur = try? await item.asset.load(.duration)
        if let dur = dur, dur.isValid, !dur.isIndefinite {
            duration = dur.seconds
        }
    }
}
