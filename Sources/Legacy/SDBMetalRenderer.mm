// Created by Angelo Cammalleri on 25.10.2026.
#import "SDBMetalRenderer.h"

#if !TARGET_OS_WATCH
#import <CoreImage/CoreImage.h>
#include <cmath>

namespace {
constexpr NSUInteger MaximumInFlightCommands = 3;
constexpr NSUInteger MaximumTextureCount = 256;
constexpr NSUInteger MaximumVertexCount = 262144;
constexpr NSUInteger MaximumDrawCount = 16384;
constexpr NSUInteger MaximumPixelDimension = 8192;
constexpr NSUInteger MaximumPixelCount = 16 * 1024 * 1024;
constexpr MTLPixelFormat FrameFormat = MTLPixelFormatBGRA8Unorm;

NSString *const ShaderSource = @R"metal(
#include <metal_stdlib>
using namespace metal;
struct LegacyVertex { float x, y, u, v, r, g, b, a; };
struct RasterVertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
};
struct DrawUniforms { uint textured, replace, distanceField; };
vertex RasterVertex legacyVertex(uint index [[vertex_id]],
                                device const LegacyVertex *vertices [[buffer(0)]],
                                constant float2 &logicalSize [[buffer(1)]]) {
    LegacyVertex v = vertices[index];
    RasterVertex out;
    out.position = float4(v.x / logicalSize.x * 2.0 - 1.0,
                         1.0 - v.y / logicalSize.y * 2.0, 0.0, 1.0);
    out.uv = float2(v.u, v.v);
    out.color = float4(v.r, v.g, v.b, v.a);
    return out;
}
fragment float4 legacyFragment(RasterVertex in [[stage_in]],
                               constant DrawUniforms &draw [[buffer(0)]],
                               texture2d<float> image [[texture(0)]],
                               sampler imageSampler [[sampler(0)]]) {
    float4 color = in.color;
    if (draw.textured) {
        float4 texel = image.sample(imageSampler, in.uv);
        if (draw.distanceField) {
            float halfWidth = max(fwidth(texel.a), 0.0001) * 0.5;
            texel.a = smoothstep(0.5 - halfWidth, 0.5 + halfWidth, texel.a);
            if (draw.distanceField == 2) {
                float foreground = texel.a;
                float alpha = foreground + texel.r * (1.0 - foreground);
                float gray = alpha > 0.0 ? (238.0 / 255.0) * foreground / alpha : 0.0;
                texel = float4(gray, gray, gray, alpha);
            }
        }
        color = draw.replace ? texel : color * texel;
    }
    return color;
}
)metal";

bool PowerOfTwo(NSUInteger value) { return value && !(value & (value - 1)); }
bool BlendFactor(uint32_t value, MTLBlendFactor &factor) {
    switch (value) {
        case 0: factor = MTLBlendFactorZero; return true;
        case 1: factor = MTLBlendFactorOne; return true;
        case 0x302: factor = MTLBlendFactorSourceAlpha; return true;
        case 0x303: factor = MTLBlendFactorOneMinusSourceAlpha; return true;
        default: return false;
    }
}
}

@implementation SDBMetalRenderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLFunction> _vertexFunction;
    id<MTLFunction> _fragmentFunction;
    id<MTLSamplerState> _nearestSampler;
    id<MTLSamplerState> _linearSampler;
    id<MTLTexture> _whiteTexture;
    id<MTLTexture> _latestTexture;
    id<MTLCommandBuffer> _latestRender;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *_textures;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_pipelines;
    // Completion handlers retain this small state and semaphore, never self.
    NSMutableDictionary<NSString *, NSString *> *_completionState;
    dispatch_semaphore_t _commandSlots;
    CIContext *_imageContext;
    CGColorSpaceRef _colorSpace;
    CGImageRef _cachedFrame;
    NSString *_failure;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _textures = [NSMutableDictionary dictionary];
    _pipelines = [NSMutableDictionary dictionary];
    _completionState = [NSMutableDictionary dictionary];
    _commandSlots = dispatch_semaphore_create(MaximumInFlightCommands);
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) { _failure = @"Metal is unavailable on this device."; return self; }
    _queue = [_device newCommandQueue];
    _queue.label = @"SPACE UNDEADBEEF ordered rendering";
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion2_4;
    id<MTLLibrary> library = [_device newLibraryWithSource:ShaderSource options:options error:&error];
    _vertexFunction = [library newFunctionWithName:@"legacyVertex"];
    _fragmentFunction = [library newFunctionWithName:@"legacyFragment"];
    if (!_queue || !_vertexFunction || !_fragmentFunction) {
        _failure = error.localizedDescription ?: @"Unable to prepare the Metal renderer.";
        return self;
    }
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.minFilter = MTLSamplerMinMagFilterNearest;
    sampler.magFilter = MTLSamplerMinMagFilterNearest;
    _nearestSampler = [_device newSamplerStateWithDescriptor:sampler];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    _linearSampler = [_device newSamplerStateWithDescriptor:sampler];
    const uint8_t white[4] = {255, 255, 255, 255};
    if (![self setTexture:0 rgba:white byteLength:sizeof(white) width:1 height:1]) return self;
    _whiteTexture = _textures[@0];
    [_textures removeObjectForKey:@0];
    _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    _imageContext = [CIContext contextWithMTLCommandQueue:_queue options:@{
        kCIContextWorkingColorSpace: NSNull.null,
        kCIContextCacheIntermediates: @NO
    }];
    if (!_nearestSampler || !_linearSampler || !_imageContext || !_colorSpace) {
        _failure = @"Unable to prepare Metal image resources.";
    }
    return self;
}

- (void)dealloc {
    if (_cachedFrame) CGImageRelease(_cachedFrame);
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (BOOL)isSupported {
    return _device && _queue && _vertexFunction && _fragmentFunction &&
        _nearestSampler && _linearSampler && _whiteTexture && _imageContext && _colorSpace;
}
- (id<MTLDevice>)device { return _device; }
- (id<MTLTexture>)latestTexture { return _latestTexture; }
- (NSString *)failure {
    @synchronized (_completionState) {
        return _completionState[@"error"] ?: _failure;
    }
}

- (BOOL)setTexture:(uint32_t)identifier rgba:(const uint8_t *)bytes
       byteLength:(NSUInteger)byteLength width:(NSUInteger)width height:(NSUInteger)height {
    _failure = nil;
    if (!_device || !bytes || !PowerOfTwo(width) || !PowerOfTwo(height) ||
        width > MaximumPixelDimension || height > MaximumPixelDimension ||
        width > MaximumPixelCount / height || byteLength < width * height * 4 ||
        (!_textures[@(identifier)] && _textures.count >= MaximumTextureCount)) {
        _failure = @"Invalid or oversized Metal texture upload.";
        return NO;
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    // Shared textures cover Apple Silicon. Older supported Intel Macs with a
    // discrete GPU still require managed CPU uploads. The deprecated mode is
    // never selected for the Apple Silicon path.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    descriptor.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
#pragma clang diagnostic pop
#else
    descriptor.storageMode = MTLStorageModeShared;
#endif
    id<MTLTexture> texture = [_device newTextureWithDescriptor:descriptor];
    if (!texture) { _failure = @"Unable to allocate a Metal game texture."; return NO; }
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
                withBytes:bytes bytesPerRow:width * 4];
    _textures[@(identifier)] = texture;
    return YES;
}

- (id<MTLRenderPipelineState>)pipelineForDraw:(const SDBMetalDraw &)draw {
    const uint64_t key = draw.blend ? (uint64_t(draw.sourceBlend) << 32) | draw.destBlend : UINT64_MAX;
    id<MTLRenderPipelineState> existing = _pipelines[@(key)];
    if (existing) return existing;
    MTLBlendFactor source = MTLBlendFactorOne, destination = MTLBlendFactorZero;
    if (draw.blend && (!BlendFactor(draw.sourceBlend, source) || !BlendFactor(draw.destBlend, destination))) {
        _failure = @"Unsupported original blend factor in Metal draw.";
        return nil;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = @"Original OpenGL ES triangle compatibility";
    descriptor.vertexFunction = _vertexFunction;
    descriptor.fragmentFunction = _fragmentFunction;
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.pixelFormat = FrameFormat;
    color.blendingEnabled = draw.blend != 0;
    color.sourceRGBBlendFactor = source;
    color.destinationRGBBlendFactor = destination;
    // Legacy output is always opaque; fragment alpha still controls RGB blending.
    color.writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) { _failure = error.localizedDescription ?: @"Unable to create a Metal blend pipeline."; return nil; }
    _pipelines[@(key)] = pipeline;
    return pipeline;
}

- (void)completeCommand:(id<MTLCommandBuffer>)command {
    dispatch_semaphore_t slots = _commandSlots;
    NSMutableDictionary<NSString *, NSString *> *state = _completionState;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError) {
            @synchronized (state) {
                state[@"error"] = completed.error.localizedDescription ?: @"Metal command execution failed.";
            }
        }
        dispatch_semaphore_signal(slots);
    }];
}

- (BOOL)renderVertices:(const SDBMetalVertex *)vertices vertexCount:(NSUInteger)vertexCount
                draws:(const SDBMetalDraw *)draws drawCount:(NSUInteger)drawCount
          logicalSize:(CGSize)logicalSize pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight {
    if (!self.supported) return NO;
    _failure = nil;
    if ((vertexCount && !vertices) || (drawCount && !draws) ||
        vertexCount > MaximumVertexCount || drawCount > MaximumDrawCount ||
        !std::isfinite(logicalSize.width) || !std::isfinite(logicalSize.height) ||
        logicalSize.width <= 0 || logicalSize.height <= 0 ||
        !pixelWidth || !pixelHeight || pixelWidth > MaximumPixelDimension ||
        pixelHeight > MaximumPixelDimension || pixelWidth > MaximumPixelCount / pixelHeight) {
        _failure = @"Invalid or oversized Metal frame.";
        return NO;
    }
    // Validate before acquiring a slot or encoding, so invalid input never leaves
    // a partial frame or an uncommitted command holding a semaphore permit.
    for (NSUInteger i = 0; i < drawCount; ++i) {
        const SDBMetalDraw &draw = draws[i];
        if (draw.firstVertex > vertexCount || draw.vertexCount > vertexCount - draw.firstVertex ||
            draw.vertexCount % 3 || (draw.textured && !_textures[@(draw.textureID)]) ||
            (draw.textured && draw.textureEnv != 0x1e01 && draw.textureEnv != 0x2100)) {
            _failure = @"Invalid original triangle draw submitted to Metal.";
            return NO;
        }
        if (![self pipelineForDraw:draw]) return NO;
    }
    if (dispatch_semaphore_wait(_commandSlots, DISPATCH_TIME_NOW)) return NO;
    id<MTLTexture> target = _latestTexture;
    if (!target || target.width != pixelWidth || target.height != pixelHeight) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:FrameFormat width:pixelWidth height:pixelHeight mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        target = [_device newTextureWithDescriptor:descriptor];
    }
    id<MTLBuffer> buffer = vertexCount ? [_device newBufferWithBytes:vertices
        length:vertexCount * sizeof(SDBMetalVertex) options:MTLResourceStorageModeShared] : nil;
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    if (!target || (vertexCount && !buffer) || !command) {
        dispatch_semaphore_signal(_commandSlots);
        _failure = @"Unable to allocate Metal frame resources.";
        return NO;
    }
    command.label = @"Render original game at display resolution";
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        dispatch_semaphore_signal(_commandSlots);
        _failure = @"Unable to encode a Metal game frame.";
        return NO;
    }
    [encoder setCullMode:MTLCullModeNone];
    [encoder setViewport:(MTLViewport){0, 0, double(pixelWidth), double(pixelHeight), 0, 1}];
    if (buffer) [encoder setVertexBuffer:buffer offset:0 atIndex:0];
    const float logical[2] = {float(logicalSize.width), float(logicalSize.height)};
    [encoder setVertexBytes:logical length:sizeof(logical) atIndex:1];
    for (NSUInteger i = 0; i < drawCount; ++i) {
        const SDBMetalDraw &draw = draws[i];
        if (!draw.vertexCount) continue;
        const uint32_t flags[3] = {draw.textured, draw.textureEnv == 0x1e01, draw.distanceField};
        [encoder setRenderPipelineState:[self pipelineForDraw:draw]];
        [encoder setFragmentBytes:flags length:sizeof(flags) atIndex:0];
        [encoder setFragmentTexture:draw.textured ? _textures[@(draw.textureID)] : _whiteTexture atIndex:0];
        [encoder setFragmentSamplerState:draw.nearest && !draw.distanceField ? _nearestSampler : _linearSampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:draw.firstVertex vertexCount:draw.vertexCount];
    }
    [encoder endEncoding];
    [self completeCommand:command];
    [command commit];
    _latestTexture = target;
    _latestRender = command;
    if (_cachedFrame) { CGImageRelease(_cachedFrame); _cachedFrame = nullptr; }
    return YES;
}

- (BOOL)presentCurrentFrameToDrawable:(id<CAMetalDrawable>)drawable {
    _failure = nil;
    id<MTLTexture> source = _latestTexture, destination = drawable.texture;
    if (!source || !destination || source.width != destination.width || source.height != destination.height) return NO;
    if (destination.device != _device || destination.pixelFormat != FrameFormat ||
        destination.sampleCount != 1 || destination.framebufferOnly) {
        _failure = @"Metal presentation requires a matching, non-framebuffer-only BGRA8 drawable.";
        return NO;
    }
    if (dispatch_semaphore_wait(_commandSlots, DISPATCH_TIME_NOW)) return NO;
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!command || !blit) {
        dispatch_semaphore_signal(_commandSlots);
        _failure = @"Unable to encode Metal presentation.";
        return NO;
    }
    command.label = @"Present original game without CPU image readback";
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(source.width, source.height, 1) toTexture:destination
         destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [command presentDrawable:drawable];
    [self completeCommand:command];
    [command commit];
    return YES;
}

- (CGImageRef)copyCurrentFrame {
    if (_cachedFrame) return CGImageRetain(_cachedFrame);
    if (!_latestTexture || !_latestRender) return nullptr;
    [_latestRender waitUntilCompleted];
    if (_latestRender.status == MTLCommandBufferStatusError) return nullptr;
    CIImage *image = [CIImage imageWithMTLTexture:_latestTexture options:@{kCIImageColorSpace: NSNull.null}];
    if (!image) { _failure = @"Unable to wrap the Metal frame for a capture."; return nullptr; }
    // Metal rows start at the top; Core Image uses a bottom-left image origin.
    // Direct drawable presentation keeps the original texture unchanged.
    image = [image imageByApplyingTransform:CGAffineTransformMake(1, 0, 0, -1, 0, _latestTexture.height)];
    // Materialize now. A deferred CGImage could observe the next frame written
    // into the reusable texture, breaking snapshot ownership and frame order.
    _cachedFrame = [_imageContext createCGImage:image fromRect:image.extent format:kCIFormatRGBA8
                                   colorSpace:_colorSpace deferred:NO];
    if (!_cachedFrame) { _failure = @"Unable to capture the Metal frame."; return nullptr; }
    return CGImageRetain(_cachedFrame);
}
@end

#else

@implementation SDBMetalRenderer
- (BOOL)isSupported { return NO; }
- (NSString *)failure { return nil; }
- (BOOL)setTexture:(uint32_t)identifier rgba:(const uint8_t *)bytes byteLength:(NSUInteger)byteLength
            width:(NSUInteger)width height:(NSUInteger)height { return NO; }
- (BOOL)renderVertices:(const SDBMetalVertex *)vertices vertexCount:(NSUInteger)vertexCount
                draws:(const SDBMetalDraw *)draws drawCount:(NSUInteger)drawCount
          logicalSize:(CGSize)logicalSize pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight { return NO; }
- (CGImageRef)copyCurrentFrame { return nullptr; }
@end

#endif
