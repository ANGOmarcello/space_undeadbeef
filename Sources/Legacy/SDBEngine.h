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
/// Coalesced original events: targeted volley=1, target acquired=2, damage=4,
/// accepted menu/ON preview=8, explosion=16, primary Bluster/Bullet shot=32.
/// Consuming clears events. Menu feedback survives menu transitions; gameplay
/// events require active gameplay. Audio preferences never gate these events.
- (NSUInteger)consumeHapticEvents;
@property(nonatomic, readonly) CGSize logicalSize;
@property(nonatomic, readonly) CGSize rasterSize;
/// Raster dimensions expressed in view points, including rounding overscan.
@property(nonatomic, readonly) CGSize rasterViewSize;
@property(nonatomic, readonly) BOOL usesMetalRenderer;
@property(nonatomic, readonly) NSString *menuVersion;
@property(nonatomic, readonly) BOOL canPause;
@property(nonatomic, readonly) NSInteger gameMenuType;
/// Explicit Watch HUD/pause policy; defaults to the compiled Watch platform.
/// Headless software-renderer verification may opt in without a Watch device.
@property(nonatomic) BOOL watchLayout;
/// Actual original ship position across its radius-inset vertical travel range.
@property(nonatomic, readonly) double shipNormalizedY;
/// False during original automatic entrance/death states as well as menus.
@property(nonatomic, readonly) BOOL canSteerShip;
/// Actual original marker hold state, independent of native pointer decoration.
@property(nonatomic, readonly) BOOL shipAiming;
/// Uses the original ship spring/physics without beginning an aiming touch.
/// Input is ignored in menus, during a touch, or while the ship is not playable.
- (void)steerShipToNormalizedY:(double)fraction NS_SWIFT_NAME(steerShip(toNormalizedY:));
/// Ends Crown input; original momentum/damping remain in control of the ship.
- (void)cancelShipSteering;
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
