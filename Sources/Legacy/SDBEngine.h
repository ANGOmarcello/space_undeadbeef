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
/// The native host offers haptics only on iPhone. Other hosts keep their menu.
- (instancetype)initWithResourcePath:(NSString *)path offersHaptics:(BOOL)offersHaptics;
@property(nonatomic, readonly, nullable) CGImageRef frame;
@property(nonatomic, readonly, nullable) NSString *failure;
@property(nonatomic, readonly) NSString *diagnostics;
@property(nonatomic) BOOL soundEnabled;
@property(nonatomic) BOOL respectsSilentMode;
@property(nonatomic) BOOL hapticsEnabled;
/// Coalesced original events: laser release=1, target acquired=2, player damage=4.
/// Consuming clears the events; no audio preference gates them.
- (NSUInteger)consumeHapticEvents;
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
/// Advances one original fixed 60 Hz step without generating an intermediate frame.
- (void)advanceSimulation:(double)delta;
/// Renders the current state once, independently of the number of simulation steps.
- (void)renderFrame;
- (void)touchPhase:(NSInteger)phase x:(double)x y:(double)y;
- (void)setSuspended:(BOOL)suspended;
@end
NS_ASSUME_NONNULL_END
