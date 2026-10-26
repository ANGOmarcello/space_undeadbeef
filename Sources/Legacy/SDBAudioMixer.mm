//
//  SDBAudioMixer.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

#import "SDBAudioMixer.h"
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <dispatch/dispatch.h>

namespace {
constexpr unsigned VoiceCount = 9, BufferCount = 12;
constexpr double MixingSampleRate = 44100;
constexpr AVAudioChannelCount MixingChannels = 2;
constexpr uint64_t MaximumDecodedBytes = 64 * 1024 * 1024;
constexpr AVAudioFrameCount ConversionChunkFrames = 4096;
char AudioControlQueueKey;
enum Transport : uint64_t { Idle, Ready, Playing, Paused };
constexpr uint64_t TransportMask = 3, BufferMask = 15 << 2, LoopMask = 1 << 6;
constexpr uint64_t CommandMask = 127, GenerationStep = 128;
struct PCMData { const float *left = nullptr, *right = nullptr; uint32_t frames = 0; };
struct VoiceState {
    std::atomic<uint64_t> command{Idle};
    std::atomic<uint64_t> finishedGeneration{UINT64_MAX};
    std::atomic<float> volume{1};
    // Only the render callback reads/writes these two fields.
    uint64_t renderGeneration = 0;
    uint32_t cursor = 0;
};
struct MixerState {
    std::array<PCMData, BufferCount> buffers;
    std::array<VoiceState, VoiceCount> voices;
    std::atomic<float> volume{1};
    std::atomic<bool> prepared{false};
};
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<float>::is_always_lock_free,
              "Audio controls must remain lock-free on supported architectures");

OSStatus render(MixerState& state, BOOL *silent, AVAudioFrameCount frames, AudioBufferList *output) {
    *silent = YES;
    if (output->mNumberBuffers != MixingChannels) return kAudio_ParamError;
    for (unsigned channel = 0; channel < MixingChannels; ++channel) {
        if (!output->mBuffers[channel].mData || output->mBuffers[channel].mNumberChannels != 1 ||
            output->mBuffers[channel].mDataByteSize < uint64_t(frames) * sizeof(float))
            return kAudio_ParamError;
        std::fill_n(static_cast<float *>(output->mBuffers[channel].mData), frames, 0.f);
    }
    float *left = static_cast<float *>(output->mBuffers[0].mData);
    float *right = static_cast<float *>(output->mBuffers[1].mData);
    if (!state.prepared.load(std::memory_order_acquire)) return noErr;
    const float master = state.volume.load(std::memory_order_relaxed);
    for (VoiceState& voice : state.voices) {
        const uint64_t command = voice.command.load(std::memory_order_acquire);
        const uint64_t generation = command & ~CommandMask;
        if (generation != voice.renderGeneration) { voice.cursor = 0; voice.renderGeneration = generation; }
        if ((command & TransportMask) != Playing) continue;
        const unsigned identifier = unsigned((command & BufferMask) >> 2);
        if (!identifier || identifier > BufferCount) continue;
        const PCMData& pcm = state.buffers[identifier - 1];
        if (!pcm.frames) continue;
        const float gain = master * voice.volume.load(std::memory_order_relaxed);
        uint32_t written = 0;
        while (written < frames) {
            if (voice.cursor == pcm.frames) {
                if (command & LoopMask) voice.cursor = 0;
                else { voice.finishedGeneration.store(generation, std::memory_order_release); break; }
            }
            const uint32_t count = std::min(frames - written, pcm.frames - voice.cursor);
            for (uint32_t index = 0; index < count; ++index) {
                left[written + index] += pcm.left[voice.cursor + index] * gain;
                right[written + index] += pcm.right[voice.cursor + index] * gain;
            }
            if (gain != 0 && count) *silent = NO;
            written += count; voice.cursor += count;
        }
        if (voice.cursor == pcm.frames && !(command & LoopMask))
            voice.finishedGeneration.store(generation, std::memory_order_release);
    }
    return noErr;
}
}

@interface SDBAudioMixer ()
- (nullable AVAudioPCMBuffer *)bufferForIdentifier:(uint32_t)identifier;
- (void)recordFailure:(NSString *)message;
- (BOOL)prepareOnControlQueue;
- (void)shutdownOnControlQueue;
@end

@interface SDBAudioVoice ()
- (instancetype)initWithMixer:(SDBAudioMixer *)mixer state:(const std::shared_ptr<MixerState>&)state index:(unsigned)index;
@end

@implementation SDBAudioMixer {
    AVAudioEngine *_engine;
    AVAudioFormat *_format;
    AVAudioSourceNode *_source;
    std::shared_ptr<MixerState> _state;
    NSArray<SDBAudioVoice *> *_voices;
    __strong AVAudioPCMBuffer *_buffers[BufferCount];
    uint64_t _decodedBytes;
    std::atomic<bool> _prepared;
    std::atomic<bool> _wakePending;
    dispatch_queue_t _controlQueue;
    std::mutex _failureMutex;
    NSString *_failure;
}

- (instancetype)init { return [self initWithEngine:[AVAudioEngine new]]; }

- (instancetype)initWithEngine:(AVAudioEngine *)engine {
    self = [super init];
    if (!self) return nil;
    _prepared.store(false, std::memory_order_relaxed);
    _wakePending.store(false, std::memory_order_relaxed);
    _engine = engine;
    _controlQueue = dispatch_queue_create("dev.cammalleri.SpaceUndeadbeef.audio-control", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_controlQueue, &AudioControlQueueKey, (__bridge void *)self, nullptr);
    _state = std::make_shared<MixerState>();
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:MixingSampleRate channels:MixingChannels];
    if (!_engine || !_format) { [self recordFailure:@"Unable to create the persistent audio graph."]; return self; }
    const auto state = _state;
    _source = [[AVAudioSourceNode alloc] initWithFormat:_format renderBlock:
        ^OSStatus(BOOL *silent, const AudioTimeStamp *, AVAudioFrameCount frames, AudioBufferList *output) {
            // No Objective-C messaging, allocation, locks, file access or
            // decoder work occurs on the real-time render thread.
            return render(*state, silent, frames, output);
        }];
    [_engine attachNode:_source];
    NSError *error = nil;
    if (@available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, *)) {
        if (![_engine connect:_source to:_engine.mainMixerNode format:_format error:&error]) {
            [self recordFailure:error.localizedDescription ?: @"Unable to connect the persistent audio source."];
            return self;
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [_engine connect:_source to:_engine.mainMixerNode format:_format];
#pragma clang diagnostic pop
    }
    NSMutableArray<SDBAudioVoice *> *voices = [NSMutableArray arrayWithCapacity:VoiceCount];
    for (unsigned index = 0; index < VoiceCount; ++index)
        [voices addObject:[[SDBAudioVoice alloc] initWithMixer:self state:_state index:index]];
    _voices = [voices copy];
    return self;
}

- (void)dealloc {
    _state->prepared.store(false, std::memory_order_release);
    for (SDBAudioVoice *voice in _voices) [voice stop];
    if (dispatch_get_specific(&AudioControlQueueKey) == (__bridge void *)self) [self shutdownOnControlQueue];
    else {
        __unsafe_unretained SDBAudioMixer *owner = self;
        dispatch_sync(_controlQueue, ^{ [owner shutdownOnControlQueue]; });
    }
}
- (void)shutdownOnControlQueue {
    [_engine stop];
    if (_source) [_engine detachNode:_source];
}
- (NSString *)failure { std::lock_guard<std::mutex> lock(_failureMutex); return _failure; }
- (float)outputVolume { return _state->volume.load(std::memory_order_relaxed); }
- (void)setOutputVolume:(float)volume {
    _state->volume.store(std::isfinite(volume) ? std::clamp(volume, 0.f, 1.f) : 0, std::memory_order_relaxed);
}
- (void)recordFailure:(NSString *)message {
    NSString *copy = [message copy];
    std::lock_guard<std::mutex> lock(_failureMutex);
    if (!_failure) _failure = copy;
}

- (AVAudioPCMBuffer *)bufferForIdentifier:(uint32_t)identifier {
    return identifier && identifier <= BufferCount ? _buffers[identifier - 1] : nil;
}

- (BOOL)loadBuffer:(uint32_t)identifier URL:(NSURL *)url {
    if (self.failure) return NO;
    if (!identifier || identifier > BufferCount || !url.isFileURL || _prepared.load(std::memory_order_acquire)) {
        [self recordFailure:@"Invalid original audio buffer or load after preparation."]; return NO;
    }
    if (_buffers[identifier - 1]) return YES;
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url commonFormat:AVAudioPCMFormatFloat32
                                              interleaved:NO error:&error];
    const AudioStreamBasicDescription *description = file.fileFormat.streamDescription;
    if (!file || file.length <= 0 || !description || description->mFormatID != kAudioFormatLinearPCM ||
        description->mBitsPerChannel != 16 || file.processingFormat.channelCount < 1 ||
        file.processingFormat.channelCount > MixingChannels ||
        !std::isfinite(file.processingFormat.sampleRate) || file.processingFormat.sampleRate <= 0) {
        [self recordFailure:error.localizedDescription ?: @"Original audio is not a supported PCM16 WAV."]; return NO;
    }
    const BOOL direct = [file.processingFormat isEqual:_format];
    const double requestedFrames = direct ? double(file.length) :
        std::ceil(double(file.length) * MixingSampleRate / file.processingFormat.sampleRate) + ConversionChunkFrames;
    const uint64_t bytesPerFrame = MixingChannels * sizeof(float);
    if (!std::isfinite(requestedFrames) || requestedFrames < 1 ||
        requestedFrames > double((MaximumDecodedBytes - _decodedBytes) / bytesPerFrame)) {
        [self recordFailure:@"Original decoded audio exceeds the bounded PCM cache."]; return NO;
    }
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format
        frameCapacity:AVAudioFrameCount(requestedFrames)];
    if (!output) { [self recordFailure:@"Unable to allocate original decoded audio."]; return NO; }
    if (direct) {
        if (![file readIntoBuffer:output error:&error]) {
            [self recordFailure:error.localizedDescription ?: @"Unable to read original audio."]; return NO;
        }
    } else {
        AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:file.processingFormat toFormat:_format];
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
            frameCapacity:ConversionChunkFrames];
        if (!converter || !input) { [self recordFailure:@"Unable to prepare original audio conversion."]; return NO; }
        if (file.processingFormat.channelCount == 1) converter.channelMap = @[@0, @0];
        __block NSError *readError = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&error
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount frames, AVAudioConverterInputStatus *state) {
                if (file.framePosition >= file.length || readError) { *state = AVAudioConverterInputStatus_EndOfStream; return nil; }
                if (![file readIntoBuffer:input frameCount:std::min(frames, input.frameCapacity) error:&readError]) {
                    *state = AVAudioConverterInputStatus_EndOfStream; return nil;
                }
                *state = input.frameLength ? AVAudioConverterInputStatus_HaveData : AVAudioConverterInputStatus_EndOfStream;
                return input.frameLength ? input : nil;
            }];
        if (status == AVAudioConverterOutputStatus_Error || readError ||
            output.frameLength == output.frameCapacity) {
            [self recordFailure:readError.localizedDescription ?: error.localizedDescription ?:
                @"Unable to complete bounded original audio conversion."]; return NO;
        }
    }
    if (!output.frameLength) { [self recordFailure:@"Original audio decoded no sample frames."]; return NO; }
    _decodedBytes += uint64_t(output.frameCapacity) * bytesPerFrame;
    _buffers[identifier - 1] = output;
    _state->buffers[identifier - 1] = {output.floatChannelData[0], output.floatChannelData[1], output.frameLength};
    return YES;
}

- (BOOL)prepare {
    if (dispatch_get_specific(&AudioControlQueueKey) == (__bridge void *)self) return [self prepareOnControlQueue];
    __block BOOL prepared = NO;
    dispatch_sync(_controlQueue, ^{ prepared = [self prepareOnControlQueue]; });
    return prepared;
}
- (BOOL)prepareOnControlQueue {
    if (self.failure || _voices.count != VoiceCount) return NO;
    if (_engine.isRunning) {
        _prepared.store(true, std::memory_order_release);
        _state->prepared.store(true, std::memory_order_release);
        return YES;
    }
    [_engine prepare];
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) {
        [self recordFailure:error.localizedDescription ?: @"Unable to start the persistent audio graph."]; return NO;
    }
    _prepared.store(true, std::memory_order_release);
    _state->prepared.store(true, std::memory_order_release);
    return YES;
}

- (void)wakeIfNeeded {
    if (!_prepared.load(std::memory_order_acquire) || _wakePending.exchange(true, std::memory_order_acq_rel)) return;
    __weak SDBAudioMixer *owner = self;
    dispatch_async(_controlQueue, ^{
        SDBAudioMixer *mixer = owner;
        if (!mixer) return;
        [mixer prepareOnControlQueue];
        mixer->_wakePending.store(false, std::memory_order_release);
    });
}

- (SDBAudioVoice *)voiceForSource:(uint32_t)source {
    return source && source <= _voices.count ? _voices[source - 1] : nil;
}
@end

@implementation SDBAudioVoice {
    __weak SDBAudioMixer *_mixer;
    std::shared_ptr<MixerState> _state;
    unsigned _index;
}

- (instancetype)initWithMixer:(SDBAudioMixer *)mixer state:(const std::shared_ptr<MixerState>&)state index:(unsigned)index {
    self = [super init];
    if (self) { _mixer = mixer; _state = state; _index = index; }
    return self;
}

- (BOOL)isPlaying {
    const VoiceState& voice = _state->voices[_index];
    const uint64_t command = voice.command.load(std::memory_order_acquire);
    return (command & TransportMask) == Playing &&
        voice.finishedGeneration.load(std::memory_order_acquire) != (command & ~CommandMask);
}
- (float)volume { return _state->voices[_index].volume.load(std::memory_order_relaxed); }
- (void)setVolume:(float)volume {
    _state->voices[_index].volume.store(std::isfinite(volume) ? std::clamp(volume, 0.f, 1.f) : 0,
                                      std::memory_order_relaxed);
}
- (NSInteger)numberOfLoops {
    return (_state->voices[_index].command.load(std::memory_order_relaxed) & LoopMask) ? -1 : 0;
}

- (BOOL)configureBuffer:(uint32_t)identifier loop:(BOOL)loop {
    SDBAudioMixer *mixer = _mixer;
    AVAudioPCMBuffer *buffer = [mixer bufferForIdentifier:identifier];
    if (!buffer || !mixer) { [mixer recordFailure:@"Original audio voice selected an unloaded buffer."]; return NO; }
    VoiceState& voice = _state->voices[_index];
    const uint64_t generation = (voice.command.load(std::memory_order_relaxed) & ~CommandMask) + GenerationStep;
    voice.command.store(generation | (uint64_t(identifier) << 2) | (loop ? LoopMask : 0) | Ready,
                        std::memory_order_release);
    return YES;
}

- (BOOL)play {
    VoiceState& voice = _state->voices[_index];
    if (!_state->prepared.load(std::memory_order_acquire)) return NO;
    uint64_t command = voice.command.load(std::memory_order_acquire);
    if (!(command & BufferMask)) return NO;
    if ([self isPlaying]) return YES;
    if (voice.finishedGeneration.load(std::memory_order_acquire) == (command & ~CommandMask) ||
        ((command & TransportMask) != Ready && (command & TransportMask) != Paused))
        command = (command & CommandMask) | ((command & ~CommandMask) + GenerationStep);
    voice.command.store((command & ~TransportMask) | Playing, std::memory_order_release);
    return YES;
}

- (void)pause {
    VoiceState& voice = _state->voices[_index];
    if (![self isPlaying]) return;
    const uint64_t command = voice.command.load(std::memory_order_relaxed);
    if ((command & TransportMask) == Playing)
        voice.command.store((command & ~TransportMask) | Paused, std::memory_order_release);
}

- (void)stop {
    VoiceState& voice = _state->voices[_index];
    const uint64_t command = voice.command.load(std::memory_order_relaxed);
    voice.command.store(((command & ~CommandMask) + GenerationStep) |
        (command & (BufferMask | LoopMask)) | Idle, std::memory_order_release);
}
@end
