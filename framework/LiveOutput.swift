//
//  LiveOutput.swift
//  GPUImage-iOS
//
//  Created by Thanh Tran on 9/29/16.
//  Copyright © 2016 Sunset Lake Software LLC. All rights reserved.
//

import Foundation
import AVFoundation

public class LiveOutput: ImageConsumer, AudioEncodingTarget {
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    
    let size:Size
    let colorSwizzlingShader:ShaderProgram
    private var isRecording = false
    private var videoEncodingIsFinished = false
    private var audioEncodingIsFinished = false
    private var startTime:CMTime?
    private var previousFrameTime = kCMTimeNegativeInfinity
    private var previousAudioTime = kCMTimeNegativeInfinity
    private var encodingLiveVideo:Bool
    var pixelBuffer:CVPixelBuffer? = nil
    var renderFramebuffer:Framebuffer!
    
    open var delegate: LiveOuputDelegate?
    
    public init(size:Size, liveVideo:Bool = false, settings:[String:AnyObject]? = nil) throws {
        if sharedImageProcessingContext.supportsTextureCaches() {
            self.colorSwizzlingShader = sharedImageProcessingContext.passthroughShader
        } else {
            self.colorSwizzlingShader = crashOnShaderCompileFailure("MovieOutput"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(1), fragmentShader:ColorSwizzlingFragmentShader)}
        }
        
        self.size = size
        
        var localSettings:[String:AnyObject]
        if let settings = settings {
            localSettings = settings
        } else {
            localSettings = [String:AnyObject]()
        }
        
        localSettings[AVVideoWidthKey] = localSettings[AVVideoWidthKey] ?? NSNumber(value:size.width)
        localSettings[AVVideoHeightKey] = localSettings[AVVideoHeightKey] ?? NSNumber(value:size.height)
        localSettings[AVVideoCodecKey] =  localSettings[AVVideoCodecKey] ?? AVVideoCodecH264 as NSString
        
        encodingLiveVideo = liveVideo
        
        // You need to use BGRA for the video in order to get realtime encoding. I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
        let sourcePixelBufferAttributesDictionary:[String:AnyObject] = [kCVPixelBufferPixelFormatTypeKey as String:NSNumber(value:Int32(kCVPixelFormatType_32BGRA)),
                                                                        kCVPixelBufferWidthKey as String:NSNumber(value:size.width),
                                                                        kCVPixelBufferHeightKey as String:NSNumber(value:size.height)]
    }
    
    public func startRecording() {
        startTime = nil
        sharedImageProcessingContext.runOperationSynchronously{
            self.isRecording = true
            
            //CVPixelBufferPoolCreatePixelBuffer(nil, self.assetWriterPixelBufferInput.pixelBufferPool!, &self.pixelBuffer)
            
            let pixelBufferOptions : NSDictionary = [kCVPixelBufferCGImageCompatibilityKey as NSString:true, kCVPixelBufferCGBitmapContextCompatibilityKey as NSString:true];
            
            pixelBuffer = nil;
            
            let status : CVReturn = CVPixelBufferCreate(kCFAllocatorDefault,
                                                        Int(self.size.width),
                                                        Int(self.size.height),
                                                        kCVPixelFormatType_32BGRA,
                                                        pixelBufferOptions as NSDictionary,
                                                        &pixelBuffer)
            
            
            /* AVAssetWriter will use BT.601 conversion matrix for RGB to YCbCr conversion
             * regardless of the kCVImageBufferYCbCrMatrixKey value.
             * Tagging the resulting video file as BT.601, is the best option right now.
             * Creating a proper BT.709 video is not possible at the moment.
             */
            CVBufferSetAttachment(self.pixelBuffer!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(self.pixelBuffer!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            CVBufferSetAttachment(self.pixelBuffer!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            
            let bufferSize = GLSize(self.size)
            var cachedTextureRef:CVOpenGLESTexture? = nil
            let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, self.pixelBuffer!, nil, GLenum(GL_TEXTURE_2D), GL_RGBA, bufferSize.width, bufferSize.height, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &cachedTextureRef)
            let cachedTexture:GLuint? = nil//CVOpenGLESTextureGetName(cachedTextureRef!)
            
            self.renderFramebuffer = try! Framebuffer(context:sharedImageProcessingContext, orientation:.portrait, size:bufferSize, textureOnly:false, overriddenTexture:cachedTexture)
        }
    }
    
    public func finishRecording(_ completionCallback:(() -> Void)? = nil) {
        sharedImageProcessingContext.runOperationSynchronously{
            self.isRecording = false

        }
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        defer {
            framebuffer.unlock()
        }
        guard isRecording else { return }
        // Ignore still images and other non-video updates (do I still need this?)
        guard let frameTime = framebuffer.timingStyle.timestamp?.asCMTime else { return }
        // If two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
        guard (frameTime != previousFrameTime) else { return }
        
        if (startTime == nil) {
            startTime = frameTime
        }
        
        renderIntoPixelBuffer(pixelBuffer!, framebuffer:framebuffer)
        
        if let delegate = delegate {
            delegate.newFramebufferAvailable(pixelBuffer!, fromSourceIndex: fromSourceIndex)
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        if !sharedImageProcessingContext.supportsTextureCaches() {
            //pixelBuffer = nil
        }
    }
    
    func renderIntoPixelBuffer(_ pixelBuffer:CVPixelBuffer, framebuffer:Framebuffer) {
        if !sharedImageProcessingContext.supportsTextureCaches() {
            renderFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:framebuffer.orientation, size:GLSize(self.size))
            renderFramebuffer.lock()
        }
        
        renderFramebuffer.activateFramebufferForRendering()
        clearFramebufferWithColor(Color.black)
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        renderQuadWithShader(colorSwizzlingShader, uniformSettings:ShaderUniformSettings(), vertices:standardImageVertices, inputTextures:[framebuffer.texturePropertiesForOutputRotation(.noRotation)])
        
//        if sharedImageProcessingContext.supportsTextureCaches() {
//            glFinish()
//        } else {
            glReadPixels(0, 0, renderFramebuffer.size.width, renderFramebuffer.size.height, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(pixelBuffer))
            renderFramebuffer.unlock()
        //glFinish()
//        }
    }
    
    // MARK: -
    // MARK: Audio support
    
    public func activateAudioTrack() {
        // TODO: Add ability to set custom output settings
//        assetWriterAudioInput = AVAssetWriterInput(mediaType:AVMediaTypeAudio, outputSettings:nil)
//        assetWriterAudioInput?.expectsMediaDataInRealTime = encodingLiveVideo
    }
    
    public func processAudioBuffer(_ sampleBuffer:CMSampleBuffer) {
//        guard let assetWriterAudioInput = assetWriterAudioInput else { return }
        
        sharedImageProcessingContext.runOperationSynchronously{
            let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            if (self.startTime == nil) {
                self.startTime = currentSampleTime
            }
            
//            guard (assetWriterAudioInput.isReadyForMoreMediaData || (!self.encodingLiveVideo)) else {
//                return
//            }
//            
//            if (!assetWriterAudioInput.append(sampleBuffer)) {
//                print("Trouble appending audio sample buffer")
//            }
        }
    }
}
