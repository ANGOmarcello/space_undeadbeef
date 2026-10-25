// Created by Angelo Cammalleri on 25.10.2026.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TargetConditionals.h>
#if !TARGET_OS_WATCH
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif

NS_ASSUME_NONNULL_BEGIN
/// Executes the supplied, hash-checked 2008 gameplay code in bounded guest memory.
@interface SDBEngine : NSObject
- (instancetype)initWithResourcePath:(NSString *)path;
@property(nonatomic, readonly, nullable) CGImageRef frame;
@property(nonatomic, readonly, nullable) NSString *failure;
@property(nonatomic, readonly) NSString *diagnostics;
@property(nonatomic) BOOL soundEnabled;
@property(nonatomic) BOOL respectsSilentMode;
@property(nonatomic, readonly) CGSize logicalSize;
@property(nonatomic, readonly) CGSize rasterSize;
/// Raster dimensions expressed in view points, including rounding overscan.
@property(nonatomic, readonly) CGSize rasterViewSize;
@property(nonatomic, readonly) BOOL usesMetalRenderer;
@property(nonatomic, readonly) NSString *menuVersion;
@property(nonatomic, readonly) BOOL canPause;
@property(nonatomic, readonly) NSInteger gameMenuType;
- (void)pauseGame;
- (void)configureViewport:(CGSize)size displayScale:(double)scale safeArea:(CGRect)safeArea;
- (CGPoint)logicalPointForViewPoint:(CGPoint)point;
#if !TARGET_OS_WATCH
@property(nonatomic, readonly, nullable) id<MTLDevice> metalDevice;
- (BOOL)presentToDrawable:(id<CAMetalDrawable>)drawable;
#endif
- (void)update:(double)delta;
- (void)touchPhase:(NSInteger)phase x:(double)x y:(double)y;
- (void)setSuspended:(BOOL)suspended;
@end
NS_ASSUME_NONNULL_END
