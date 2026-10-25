// Created by Angelo Cammalleri on 25.10.2026.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TargetConditionals.h>
#include <stdint.h>

#if !TARGET_OS_WATCH
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// Already transformed positions use a top-left origin in the logical viewport.
typedef struct {
    float x, y, u, v, r, g, b, a;
} SDBMetalVertex;

/// Each range is a triangle list. Ranges render in array order, without sorting.
/// Texture environment and blend factors use the original OpenGL ES constants:
/// REPLACE 0x1e01, MODULATE 0x2100; ZERO 0, ONE 1, SRC_ALPHA 0x302,
/// ONE_MINUS_SRC_ALPHA 0x303. Boolean fields are zero or one.
typedef struct {
    uint32_t firstVertex, vertexCount, textureID;
    uint32_t textured, textureEnv, blend, sourceBlend, destBlend, nearest;
    /// 0: original RGBA; 1: font alpha distance, contour0.5; 2: menu foreground
    /// alpha distance plus original shadow coverage in R. Both fields reconstruct
    /// foreground coverage at the final pixel density.
    uint32_t distanceField;
} SDBMetalDraw;

/// A bounded, ordered GPU renderer. Call its methods from one CPU thread.
/// watchOS compiles the same interface as an unsupported stub without Metal.
@interface SDBMetalRenderer : NSObject
@property(nonatomic, readonly, getter=isSupported) BOOL supported;
@property(nonatomic, readonly, nullable) NSString *failure;

/// Copies tightly packed, straight-alpha RGBA8 data; uploads are independent of
/// subsequent caller mutations. Dimensions must be powers of two.
- (BOOL)setTexture:(uint32_t)identifier
             rgba:(const uint8_t *)bytes
       byteLength:(NSUInteger)byteLength
            width:(NSUInteger)width
           height:(NSUInteger)height;

/// Copies vertices before returning and submits an opaque frame at native pixel
/// dimensions. No CPU rasterization, image creation, or GPU wait occurs here.
/// A full GPU queue returns NO with no failure, retaining the previous frame.
- (BOOL)renderVertices:(const SDBMetalVertex * _Nullable)vertices
          vertexCount:(NSUInteger)vertexCount
                draws:(const SDBMetalDraw * _Nullable)draws
            drawCount:(NSUInteger)drawCount
          logicalSize:(CGSize)logicalSize
           pixelWidth:(NSUInteger)pixelWidth
          pixelHeight:(NSUInteger)pixelHeight;

/// Explicit synchronous bridge for headless captures. Normal display should use
/// presentCurrentFrameToDrawable: instead. The caller owns the returned image.
- (nullable CGImageRef)copyCurrentFrame CF_RETURNS_RETAINED;

#if !TARGET_OS_WATCH
@property(nonatomic, readonly, nullable) id<MTLDevice> device;
/// Contents become ready in command-queue order; callers must not mutate them.
@property(nonatomic, readonly, nullable) id<MTLTexture> latestTexture;
/// The drawable must be BGRA8Unorm, framebufferOnly=NO, sampleCount=1 and exactly
/// match latestTexture dimensions. A resize mismatch returns NO without failure.
/// A same-queue blit and presentation are committed without waiting for the GPU.
- (BOOL)presentCurrentFrameToDrawable:(id<CAMetalDrawable>)drawable;
#endif
@end

NS_ASSUME_NONNULL_END
