//
//  AudioCapture.swift
//  MicLevel
//
//  Created by James Dale on 6/10/2023.
//

import AVFoundation
import os.log

public class AudioCapture: NSObject {
    public let captureSession = AVCaptureSession()
    private var isCaptureSessionConfigured = false
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var fileOutput: AVCaptureMovieFileOutput?
    private var audioConnection: AVCaptureConnection?
    private var sessionQueue: DispatchQueue!
    
    public static let shared = AudioCapture()
    
    private var allAudioDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [AVCaptureDevice.DeviceType.microphone,
                                                       AVCaptureDevice.DeviceType.external],
                                         mediaType: .audio,
                                         position: .unspecified).devices
    }
    
    private var captureDevices: [AVCaptureDevice] {
        var devices = [AVCaptureDevice]()
        #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
        devices += allAudioDevices
        #else
        if let backDevice = backCaptureDevices.first {
            devices += [backDevice]
        }
        if let frontDevice = frontCaptureDevices.first {
            devices += [frontDevice]
        }
        #endif
        return devices
    }
    
    // MARK: Audio
    public var availableAudioCaptureDevices: [AVCaptureDevice] {
        allAudioDevices
            .filter( { $0.isConnected } )
            .filter( { !$0.isSuspended } )
    }
    
    //MARK: Audio
    private var audioCaptureDevice: AVCaptureDevice? {
        didSet {
            guard let captureDevice = audioCaptureDevice else { return }
            logger.debug("Using capture device: \(captureDevice.localizedName)")
            sessionQueue.async {
                self.updateSessionForCaptureDevice(captureDevice)
            }
        }
    }
    
    public var isRunning: Bool {
        captureSession.isRunning
    }
    
    private var addToMicLevelStream: ((Float) -> Void)?
    
    public lazy var micLevelStream: AsyncStream<Float> = {
        AsyncStream { continuation in
            addToMicLevelStream = { floatLevel in
                continuation.yield(floatLevel)
            }
        }
    }()
        
    private override init() {
        super.init()
        initialize()
    }
    
    private func getAudioCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }
    
    private func initialize() {
        sessionQueue = DispatchQueue(label: "MicSessionQueue")
        audioCaptureDevice = getAudioCaptureDevice()
    }
    
    private func configureCaptureSession(completionHandler: (_ success: Bool) -> Void) {
        
        var success = false
        
        self.captureSession.beginConfiguration()
        
        defer {
            self.captureSession.commitConfiguration()
            completionHandler(success)
        }
        
        
        guard
            let audioCaptureDevice = audioCaptureDevice,
            let audioDeviceInput = try? AVCaptureDeviceInput(device: audioCaptureDevice)
        else {
            logger.error("Failed to obtain video input.")
            return
        }
        
        let audioSettings = [AVFormatIDKey : kAudioFormatLinearPCM,
                           AVSampleRateKey : 48000,
                    AVLinearPCMBitDepthKey : 16,
                     AVLinearPCMIsFloatKey : false,
               AVLinearPCMIsNonInterleaved : false] as [String : Any]
        
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "AudioDataOutputQueue"))
        audioOutput.audioSettings = audioSettings
  
        guard captureSession.canAddInput(audioDeviceInput) else {
            logger.error("Unable to add audio device input to capture session.")
            return
        }
    
        guard captureSession.canAddOutput(audioOutput) else {
            logger.error("Unable to add audio output to capture session.")
            return
        }
        
        captureSession.addInput(audioDeviceInput)
        captureSession.addOutput(audioOutput)
        
        self.audioDeviceInput = audioDeviceInput
        self.audioOutput = audioOutput
        
        self.audioConnection = audioOutput.connection(with: .audio)
        
        isCaptureSessionConfigured = true
        
        success = true
    }
    
    private func checkAuthorization() async -> Bool {
        let micStratus = await checkMicAuthorization()
        return micStratus
    }
    
    private func checkMicAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            logger.debug("Microphone access authorized.")
            return true
        case .notDetermined:
            logger.debug("Microphone access not determined.")
            sessionQueue.suspend()
            let status = await AVCaptureDevice.requestAccess(for: .audio)
            sessionQueue.resume()
            return status
        case .denied:
            logger.debug("Microphone access denied.")
            return false
        case .restricted:
            logger.debug("Microphone library access restricted.")
            return false
        @unknown default:
            return false
        }
    }
    
    private func deviceInputFor(device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let validDevice = device else { return nil }
        do {
            return try AVCaptureDeviceInput(device: validDevice)
        } catch let error {
            logger.error("Error getting capture device input: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func updateSessionForCaptureDevice(_ captureDevice: AVCaptureDevice) {
        guard isCaptureSessionConfigured else { return }
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput {
                captureSession.removeInput(deviceInput)
            }
        }
        
        if let deviceInput = deviceInputFor(device: captureDevice) {
            if !captureSession.inputs.contains(deviceInput), captureSession.canAddInput(deviceInput) {
                captureSession.addInput(deviceInput)
            }
        }
    }
    
    public func start() async {
        let authorized = await checkAuthorization()
        guard authorized else {
            logger.error("Access was not authorized.")
            return
        }
        
        if isCaptureSessionConfigured {
            if !captureSession.isRunning {
                sessionQueue.async { [self] in
                    self.captureSession.startRunning()
                }
            }
            return
        }
        
        sessionQueue.async { [self] in
            self.configureCaptureSession { success in
                guard success else { return }
                self.captureSession.startRunning()
            }
        }
    }
    
    public func stop() {
        guard isCaptureSessionConfigured else { return }
        
        if captureSession.isRunning {
            sessionQueue.async {
                self.captureSession.stopRunning()
            }
        }
    }
    
}



extension AudioCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let avgFloat = audioConnection?.audioChannels
            .compactMap { $0.averagePowerLevel }
            .reduce(0, +)
        
        if let avgFloat = avgFloat {
            self.addToMicLevelStream?(avgFloat)
        }
    }
}

fileprivate let logger = Logger(subsystem: "com.miclevel.app", category: "AudioManager")

