// Created by Angelo Cammalleri on 25.10.2026.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TargetConditionals.h>
#if !TARGET_OS_WATCH
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif

NS_ASSUME_NONNULL_BEGIN
/// A currently executable original menu button, in the engine's logical space.
/// Identity expires when the original menu is rebuilt; activation revalidates it.
@interface SDBMenuAction : NSObject
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) NSString *label;
@property(nonatomic, readonly) CGRect logicalFrame;
@property(nonatomic, readonly) BOOL selected;
@end

/// Executes the supplied, hash-checked 2008 gameplay code in bounded guest memory.
@interface SDBEngine : NSObject
- (instancetype)initWithResourcePath:(NSString *)path;
/// The native host offers haptics on iPhone and Watch. Other hosts keep their menu.
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
@property(nonatomic, readonly) NSArray<SDBMenuAction *> *menuActions;
/// Follows the original hit-test/selection/animation path; false for stale,
/// suspended, pending, offscreen or otherwise unavailable actions.
- (BOOL)activateMenuAction:(NSString *)identifier;
/// Calls the original pack/save routine; unchanged records cause no disk writes.
/// Storage failures are nonfatal and exposed separately from guest failures.
- (BOOL)saveProgress;
/// Captures original packing on the game thread; bounded/coalesced disk work
/// runs off the frame loop. Completion errors surface through lastSaveError.
- (void)checkpointProgress;
@property(nonatomic, readonly, nullable) NSString *lastSaveError;
@property(nonatomic, readonly, nullable) NSDictionary<NSString *,id> *progressPortableSnapshot;
/// Pure merge for account sync; no engine, disk, preferences or game mutation.
+ (nullable NSDictionary<NSString *,id> *)mergedPortableSnapshot:(NSDictionary<NSString *,id> *)local
    remote:(NSDictionary<NSString *,id> *)remote NS_SWIFT_NAME(mergeProgress(_:remote:));
/// Validated deterministic merge, only on the title screen. Preserves local
/// preferences and unknown save bytes, then uses the original unpack routine.
- (BOOL)importValidatedProgress:(NSDictionary<NSString *,id> *)snapshot;
/// Rebuilds audio graph state after a system media reset without starting audio.
- (BOOL)recoverAudioAfterMediaServicesReset;
/// Audio can remain stopped while the original paused menu updates and renders.
@property(nonatomic, readonly) BOOL audioSuspended;
@property(nonatomic, readonly, nullable) NSString *lastAudioError;
/// YES preserves music intent and drops transient effects; NO attempts the same
/// bounded activation as tryResumeAudio and may leave audio suspended on error.
- (void)setAudioSuspended:(BOOL)suspended NS_SWIFT_NAME(setAudioSuspended(_:));
/// Explicitly activates the native session and graph. Temporary OS/start errors
/// return NO without changing guest health; a later attempt may recover them.
- (BOOL)tryResumeAudio;
/// Releases inactive host scratch/readback caches without discarding visible
/// frame, decoded textures, audio, guest memory, progress or preferences.
- (void)trimTransientResources;
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
/// Cancels host ownership and ends original marker aiming without firing a
/// release volley. Ordinary touch-ended input retains its original firing path.
- (void)cancelHeldInput;
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
