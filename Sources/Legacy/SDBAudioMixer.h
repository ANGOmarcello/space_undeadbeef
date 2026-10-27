//
//  SDBAudioMixer.h
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

#import <Foundation/Foundation.h>
#include <stdint.h>

@class AVAudioEngine;
@class SDBAudioVoice;

NS_ASSUME_NONNULL_BEGIN

/// One persistent source node mixes nine logical voices: sources 1...8 are
/// original SFX voices and source 9 is music. Voice controls publish atomics;
/// they never wait for an audio render cycle or create a player/decoder.
/// Load original PCM WAV buffers 1...12 before prepare. Control calls are serial;
/// the render callback alone owns each voice's playback cursor.
@interface SDBAudioMixer : NSObject
- (instancetype)init;
/// Allows a caller to supply an engine already configured for offline rendering.
- (instancetype)initWithEngine:(AVAudioEngine *)engine NS_DESIGNATED_INITIALIZER;
@property(nonatomic, readonly, nullable) NSString *failure;
/// Set before prepare for process-local test muting, without system-volume edits.
@property(nonatomic) float outputVolume;
- (BOOL)loadBuffer:(uint32_t)identifier URL:(NSURL *)url;
/// Configures the graph and starts the engine. Repeated calls are cheap
/// while running; after a system interruption it can restart the same graph.
- (BOOL)prepare;
/// Stops native callbacks while retaining decoded PCM and logical voice state.
- (void)suspend;
/// Recreates orphaned native audio objects after a media-services reset. Does
/// not start playback; the caller must wait for explicit user initiation.
- (BOOL)rebuildAfterMediaServicesReset;
/// Offline verification supplies a new manual-rendering engine here.
- (BOOL)rebuildWithEngine:(AVAudioEngine *)engine;
/// Coalesces an asynchronous engine running-check/restart after an audio event.
/// No hardware API or render-cycle wait runs on the calling game thread.
- (void)wakeIfNeeded;
- (nullable SDBAudioVoice *)voiceForSource:(uint32_t)source;
@end

@interface SDBAudioVoice : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) BOOL isPlaying;
@property(nonatomic) float volume;
/// Original game uses 0 for one shot and -1 for an indefinite music loop.
@property(nonatomic, readonly) NSInteger numberOfLoops;
/// Stops/rewinds the current event and schedules a decoded shared buffer.
- (BOOL)configureBuffer:(uint32_t)identifier loop:(BOOL)loop;
/// Starts a configured/stopped voice, or resumes a paused voice in place.
/// Call mixer.prepare before initial playback and after system interruptions.
- (BOOL)play;
- (void)pause;
/// Clears the scheduled event; a later play restarts the configured buffer.
- (void)stop;
@end

NS_ASSUME_NONNULL_END
