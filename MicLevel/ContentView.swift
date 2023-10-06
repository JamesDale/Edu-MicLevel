//
//  ContentView.swift
//  MicLevel
//
//  Created by James Dale on 6/10/2023.
//

import SwiftUI
import Combine
import Charts

final class ContentViewModel: ObservableObject {
    
    @Published var micLevel: Float?
    
    @Published var micLevelData: [CapturedAudioLevel] = []
    
    private var audio = AudioCapture.shared
    private var cancellables = [AnyCancellable]()
    
    public var formattedMicLevel: String? {
        guard let micLevel = micLevel else { return nil }
        return String(format: "%.0f", micLevel)
    }
    
    init(micLevel: Float? = nil) {
        self.micLevel = micLevel
    }
    
    func start() async {
        await audio.start()
        await handleMicLevel()
    }
    
    func handleMicLevel() async {
        let micStream = audio.micLevelStream
            .map { $0 }
        
        for await micLevel in micStream {
            Task { @MainActor in
                self.micLevel = micLevel
                self.micLevelData.append(CapturedAudioLevel(timestamp: .now,
                                                            level: micLevel))
                self.micLevelData = micLevelData.suffix(200)
            }
        }
    }
}

struct ContentView: View {
    
    @StateObject var viewModel = ContentViewModel()
    
    var body: some View {
        VStack {
            HStack {
                Image(systemName: "mic.fill")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .font(.largeTitle)
                if let micLevel = viewModel.formattedMicLevel {
                    Text("\(micLevel) db")
                        .font(.largeTitle)
                }
            }
            
            Chart(viewModel.micLevelData) {
                LineMark(
                    x: .value("Date", $0.timestamp),
                    y: .value("Audio Level", $0.level)
                )
            }
        }
        .padding()
        .task {
            await viewModel.start()
        }
    }
}

#Preview {
    ContentView()
}
