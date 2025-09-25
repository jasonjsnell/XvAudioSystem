//
//  FFTProcessor.swift
//  XvAudioSystem
//
//  Created by Jason Snell on 3/29/25.
//  Copyright © 2025 Jason J. Snell. All rights reserved.
//

import Accelerate
import AVFoundation

class FFTProcessor {
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length
    private var bufferSize: Int
    private var window: [Float]
    
    init(bufferSize: Int) {
        self.bufferSize = bufferSize
        self.log2n = vDSP_Length(log2(Float(bufferSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        self.window = [Float](repeating: 0.0, count: bufferSize)
        vDSP_hann_window(&window, vDSP_Length(bufferSize), Int32(vDSP_HANN_NORM))
    }

    func performFFT(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0] else { return [] }

        var windowedSignal = [Float](repeating: 0.0, count: bufferSize)
        vDSP_vmul(channelData, 1, window, 1, &windowedSignal, 1, vDSP_Length(bufferSize))

        var magnitudes = [Float](repeating: 0.0, count: bufferSize / 2)

        var realp = [Float](repeating: 0.0, count: bufferSize / 2)
        var imagp = [Float](repeating: 0.0, count: bufferSize / 2)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var complexBuffer = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                windowedSignal.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bufferSize) {
                        vDSP_ctoz($0, 2, &complexBuffer, 1, vDSP_Length(bufferSize / 2))
                    }
                }

                vDSP_fft_zrip(fftSetup!, &complexBuffer, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&complexBuffer, 1, &magnitudes, 1, vDSP_Length(bufferSize / 2))
            }
        }

        return magnitudes
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }
}
