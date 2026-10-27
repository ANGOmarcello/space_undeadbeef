// Created by Angelo Cammalleri on 25.10.2026.
#import "SDBMetalRenderer.h"

#if !TARGET_OS_WATCH
#import <CoreImage/CoreImage.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>

namespace {
constexpr NSUInteger MaximumInFlightCommands = 3;
constexpr NSUInteger MaximumTextureCount = 256;
constexpr NSUInteger MaximumVertexCount = 262144;
constexpr NSUInteger MaximumDrawCount = 16384;
constexpr NSUInteger MaximumPixelDimension = 8192;
constexpr NSUInteger MaximumPixelCount = 16 * 1024 * 1024;
constexpr MTLPixelFormat FrameFormat = MTLPixelFormatBGRA8Unorm;

// A command's completion owns the usage marker independently of the renderer.
// Buffers are not overwritten until the GPU has finished their own submission.
struct VertexBufferUsage {
    std::array<std::atomic<bool>, MaximumInFlightCommands> busy;
    VertexBufferUsage() {
        for (auto &slot : busy) slot.store(false, std::memory_order_relaxed);
    }
};


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
bool SameDrawState(const SDBMetalDraw &a, const SDBMetalDraw &b) {
    return a.textureID == b.textureID && a.textured == b.textured &&
        a.textureEnv == b.textureEnv && a.blend == b.blend &&
        a.sourceBlend == b.sourceBlend && a.destBlend == b.destBlend &&
        a.nearest == b.nearest && a.distanceField == b.distanceField &&
        a.glyphAtlas == b.glyphAtlas;
}
uint64_t PipelineKey(const SDBMetalDraw &draw) {
    return draw.blend ? (uint64_t(draw.sourceBlend) << 32) | draw.destBlend : UINT64_MAX;
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
    id<MTLBuffer> _vertexBuffers[MaximumInFlightCommands];
    NSUInteger _vertexBufferCapacities[MaximumInFlightCommands];
    NSUInteger _nextVertexBuffer;
    std::shared_ptr<VertexBufferUsage> _vertexBufferUsage;
    CIContext *_imageContext;
    CGColorSpaceRef _colorSpace;
    CGImageRef _cachedFrame;
    NSString *_failure;
    BOOL _pipelinesReady;
    // Last successful submission diagnostics also let integration checks verify
    // that equivalent original ranges actually share native draw commands.
    NSUInteger _lastEncodedDrawCount;
    NSUInteger _lastPipelineBindingCount;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _textures = [NSMutableDictionary dictionary];
    _pipelines = [NSMutableDictionary dictionary];
    _completionState = [NSMutableDictionary dictionary];
    _commandSlots = dispatch_semaphore_create(MaximumInFlightCommands);
    _vertexBufferUsage = std::make_shared<VertexBufferUsage>();
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) { _failure = @"Metal is unavailable on this device."; return self; }
    _queue = [_device newCommandQueue];
    _queue.label = @"SPACE UNDEADBEEF ordered rendering";
    NSError *error = nil;
    // Application targets compile SDBShaders.metal into their bundled default
    // library. Explicit command-line fixtures compile the same source into a
    // task-owned library; application builds have no source-compiler fallback.
#if defined(SDB_HEADLESS_TESTS) && SDB_HEADLESS_TESTS
    NSString *libraryPath = NSProcessInfo.processInfo.environment[@"SDB_METAL_LIBRARY"];
    if (!libraryPath.length) {
        _failure = @"Headless Metal tests require their explicitly prepared library.";
        return self;
    }
    NSURL *libraryURL = [NSURL fileURLWithPath:libraryPath];
    id<MTLLibrary> library = [_device newLibraryWithURL:libraryURL error:&error];
#else
    id<MTLLibrary> library = [_device newDefaultLibraryWithBundle:NSBundle.mainBundle error:&error];
#endif
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
        return self;
    }
    // Compile the original opaque, straight-alpha and additive states before
    // gameplay. Other supported blend combinations retain the same lazy path.
    for (const SDBMetalDraw &draw : {
        SDBMetalDraw{0, 0, 0, 0, 0x1e01, 0, 1, 0, 0, 0, 0},
        SDBMetalDraw{0, 0, 0, 0, 0x1e01, 1, 0x302, 0x303, 0, 0, 0},
        SDBMetalDraw{0, 0, 0, 0, 0x1e01, 1, 0x302, 1, 0, 0, 0}}) {
        if (![self pipelineForDraw:draw]) return self;
    }
    _pipelinesReady = YES;
    return self;
}

- (void)dealloc {
    if (_cachedFrame) CGImageRelease(_cachedFrame);
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (BOOL)isSupported {
    return _device && _queue && _vertexFunction && _fragmentFunction &&
        _nearestSampler && _linearSampler && _whiteTexture && _imageContext && _colorSpace && _pipelinesReady;
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
    MTLBlendFactor source = MTLBlendFactorOne, destination = MTLBlendFactorZero;
    if (draw.blend && (!BlendFactor(draw.sourceBlend, source) || !BlendFactor(draw.destBlend, destination))) {
        _failure = @"Unsupported original blend factor in Metal draw.";
        return nil;
    }
    const uint64_t key = PipelineKey(draw);
    id<MTLRenderPipelineState> existing = _pipelines[@(key)];
    if (existing) return existing;
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

- (void)completeCommand:(id<MTLCommandBuffer>)command vertexSlot:(NSUInteger)vertexSlot {
    dispatch_semaphore_t slots = _commandSlots;
    NSMutableDictionary<NSString *, NSString *> *state = _completionState;
    const auto usage = _vertexBufferUsage;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError) {
            @synchronized (state) {
                state[@"error"] = completed.error.localizedDescription ?: @"Metal command execution failed.";
            }
        }
        if (vertexSlot != NSNotFound) usage->busy[vertexSlot].store(false, std::memory_order_release);
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
    bool hasValidatedPipeline = false;
    uint64_t validatedPipeline = 0;
    for (NSUInteger i = 0; i < drawCount; ++i) {
        const SDBMetalDraw &draw = draws[i];
        if (draw.firstVertex > vertexCount || draw.vertexCount > vertexCount - draw.firstVertex ||
            draw.vertexCount % 3 || (draw.textured && !_textures[@(draw.textureID)]) ||
            (draw.textured && draw.textureEnv != 0x1e01 && draw.textureEnv != 0x2100)) {
            _failure = @"Invalid original triangle draw submitted to Metal.";
            return NO;
        }
        // Validate even when the prior range used the same pipeline key. Two
        // invalid UINT32_MAX factors must not alias the opaque key or turn a
        // malformed zero-length record into an unchecked batch barrier.
        MTLBlendFactor source, destination;
        if (draw.blend && (!BlendFactor(draw.sourceBlend, source) || !BlendFactor(draw.destBlend, destination))) {
            _failure = @"Unsupported original blend factor in Metal draw.";
            return NO;
        }
        const uint64_t key = PipelineKey(draw);
        if (!hasValidatedPipeline || key != validatedPipeline) {
            if (![self pipelineForDraw:draw]) return NO;
            validatedPipeline = key;
            hasValidatedPipeline = true;
        }
    }
    if (dispatch_semaphore_wait(_commandSlots, DISPATCH_TIME_NOW)) return NO;
    NSUInteger vertexSlot = NSNotFound;
    id<MTLBuffer> buffer = nil;
    if (vertexCount) {
        for (NSUInteger i = 0; i < MaximumInFlightCommands; ++i) {
            const NSUInteger candidate = (_nextVertexBuffer + i) % MaximumInFlightCommands;
            if (!_vertexBufferUsage->busy[candidate].exchange(true, std::memory_order_acq_rel)) {
                vertexSlot = candidate;
                _nextVertexBuffer = (candidate + 1) % MaximumInFlightCommands;
                break;
            }
        }
        if (vertexSlot == NSNotFound) {
            dispatch_semaphore_signal(_commandSlots);
            _failure = @"Metal vertex-buffer slots are unexpectedly exhausted.";
            return NO;
        }
        const NSUInteger length = vertexCount * sizeof(SDBMetalVertex);
        if (_vertexBufferCapacities[vertexSlot] < length) {
            NSUInteger capacity = std::max(NSUInteger(4096), _vertexBufferCapacities[vertexSlot]);
            while (capacity < length) capacity = std::min(capacity * 2, MaximumVertexCount * sizeof(SDBMetalVertex));
            id<MTLBuffer> grown = [_device newBufferWithLength:capacity options:MTLResourceStorageModeShared];
            if (grown) {
                _vertexBuffers[vertexSlot] = grown;
                _vertexBufferCapacities[vertexSlot] = capacity;
            }
        }
        buffer = _vertexBuffers[vertexSlot];
        if (!buffer || _vertexBufferCapacities[vertexSlot] < length) {
            _vertexBufferUsage->busy[vertexSlot].store(false, std::memory_order_release);
            dispatch_semaphore_signal(_commandSlots);
            _failure = @"Unable to allocate a Metal vertex buffer.";
            return NO;
        }
        std::memcpy(buffer.contents, vertices, length);
    }
    id<MTLTexture> target = _latestTexture;
    if (!target || target.width != pixelWidth || target.height != pixelHeight) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:FrameFormat width:pixelWidth height:pixelHeight mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        target = [_device newTextureWithDescriptor:descriptor];
    }
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    if (!target || (vertexCount && !buffer) || !command) {
        if (vertexSlot != NSNotFound) _vertexBufferUsage->busy[vertexSlot].store(false, std::memory_order_release);
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
        if (vertexSlot != NSNotFound) _vertexBufferUsage->busy[vertexSlot].store(false, std::memory_order_release);
        dispatch_semaphore_signal(_commandSlots);
        _failure = @"Unable to encode a Metal game frame.";
        return NO;
    }
    [encoder setCullMode:MTLCullModeNone];
    [encoder setViewport:(MTLViewport){0, 0, double(pixelWidth), double(pixelHeight), 0, 1}];
    if (buffer) [encoder setVertexBuffer:buffer offset:0 atIndex:0];
    const float logical[2] = {float(logicalSize.width), float(logicalSize.height)};
    [encoder setVertexBytes:logical length:sizeof(logical) atIndex:1];
    id<MTLRenderPipelineState> previousPipeline = nil;
    uint64_t previousPipelineKey = 0;
    id<MTLTexture> previousTexture = nil;
    id<MTLSamplerState> previousSampler = nil;
    uint32_t previousFlags[4] = {};
    struct GlyphBinding {
        uint32_t enabled, firstVertex;
        float inverseWidth, inverseHeight;
    } previousGlyph = {};
    bool hasFlags = false, hasGlyph = false;
    NSUInteger encodedDrawCount = 0, pipelineBindingCount = 0;
    for (NSUInteger i = 0; i < drawCount;) {
        const SDBMetalDraw &draw = draws[i];
        if (!draw.vertexCount) { ++i; continue; }
        NSUInteger vertexCountInBatch = draw.vertexCount;
        NSUInteger next = i + 1;
        // Consecutive triangle lists can share a draw only when every render
        // state agrees and the vertex ranges touch. Never sort or cross a gap.
        // Counts are multiples of three, so the shader's per-triangle glyph
        // bounds keep the same local three vertices after this merge, including
        // an original firstVertex that is not itself divisible by three.
        while (next < drawCount && draws[next].vertexCount &&
               draws[next].firstVertex == draw.firstVertex + vertexCountInBatch &&
               SameDrawState(draw, draws[next])) {
            vertexCountInBatch += draws[next].vertexCount;
            ++next;
        }
        id<MTLTexture> texture = draw.textured ? _textures[@(draw.textureID)] : _whiteTexture;
        const bool glyphAtlas = draw.textured && draw.glyphAtlas && !draw.distanceField &&
            texture.width >= 16 && texture.height >= 8;
        const uint32_t flags[4] = {draw.textured, draw.textureEnv == 0x1e01, draw.distanceField, glyphAtlas};
        const GlyphBinding glyph = {uint32_t(glyphAtlas), glyphAtlas ? draw.firstVertex : 0,
            1.f / texture.width, 1.f / texture.height};
        const uint64_t key = PipelineKey(draw);
        if (!previousPipeline || key != previousPipelineKey) {
            id<MTLRenderPipelineState> pipeline = [self pipelineForDraw:draw];
            [encoder setRenderPipelineState:pipeline];
            previousPipeline = pipeline;
            previousPipelineKey = key;
            ++pipelineBindingCount;
        }
        if (!hasGlyph || std::memcmp(&glyph, &previousGlyph, sizeof(glyph))) {
            [encoder setVertexBytes:&glyph length:sizeof(glyph) atIndex:2];
            previousGlyph = glyph;
            hasGlyph = true;
        }
        if (!hasFlags || std::memcmp(flags, previousFlags, sizeof(flags))) {
            [encoder setFragmentBytes:flags length:sizeof(flags) atIndex:0];
            std::memcpy(previousFlags, flags, sizeof(flags));
            hasFlags = true;
        }
        if (texture != previousTexture) {
            [encoder setFragmentTexture:texture atIndex:0];
            previousTexture = texture;
        }
        id<MTLSamplerState> sampler = draw.nearest && !draw.distanceField ? _nearestSampler : _linearSampler;
        if (sampler != previousSampler) {
            [encoder setFragmentSamplerState:sampler atIndex:0];
            previousSampler = sampler;
        }
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:draw.firstVertex vertexCount:vertexCountInBatch];
        ++encodedDrawCount;
        i = next;
    }
    [encoder endEncoding];
    [self completeCommand:command vertexSlot:vertexSlot];
    [command commit];
    _latestTexture = target;
    _latestRender = command;
    _lastEncodedDrawCount = encodedDrawCount;
    _lastPipelineBindingCount = pipelineBindingCount;
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
    [self completeCommand:command vertexSlot:NSNotFound];
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

- (void)trimTransientResources {
    if (_cachedFrame) { CGImageRelease(_cachedFrame); _cachedFrame = nullptr; }
    [_imageContext clearCaches];
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
- (void)trimTransientResources {}
@end

#endif
