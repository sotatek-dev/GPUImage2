//
//  LiveOutputDelegate.swift
//  GPUImage-iOS
//
//  Created by Thanh Tran on 9/29/16.
//  Copyright © 2016 Sunset Lake Software LLC. All rights reserved.
//

import Foundation

public protocol LiveOuputDelegate {
    func newFramebufferAvailable(_ framebuffer: CVImageBuffer, fromSourceIndex:UInt)
}
