//
//  AudioMixerTests.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//
// Offline rendering never opens an output device or changes system volume.

#import <AVFoundation/AVFoundation.h>
#import "SDBAudioMixer.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

namespace {
unsigned checks = 0;
constexpr AVAudioFrameCount Quantum = 1024;
bool check(bool value, const char *label) {
    ++checks;
    if (!value) std::fprintf(stderr, "FAIL %s\n", label);
    return value;
}
#define REQUIRE(value, label) do { if (!check((value), (label))) return 1; } while (0)

AVAudioEngine *offlineEngine(AVAudioFormat *format) {
    @try {
        AVAudioEngine *engine = [AVAudioEngine new];
        NSError *error = nil;
        if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format
                            maximumFrameCount:Quantum error:&error]) {
            std::fprintf(stderr, "Unavailable offline Core Audio: %s\n", error.localizedDescription.UTF8String);
            return nil;
        }
        return engine;
    } @catch (NSException *exception) {
        // Restricted environments can hide the built-in mixer AudioComponent.
        std::fprintf(stderr, "Unavailable offline Core Audio: %s\n", exception.reason.UTF8String);
        return nil;
    }
}
std::vector<float> render(AVAudioEngine *engine, AVAudioPCMBuffer *output, AVAudioFrameCount frames = Quantum) {
    NSError *error = nil;
    for (unsigned retry = 0; retry < 10; ++retry) {
        auto status = [engine renderOffline:frames toBuffer:output error:&error];
        if (status == AVAudioEngineManualRenderingStatusCannotDoInCurrentContext) continue;
        if (status != AVAudioEngineManualRenderingStatusSuccess || output.frameLength != frames) {
            std::fprintf(stderr, "FAIL offline render status %ld: %s\n", (long)status,
                         error.localizedDescription.UTF8String ?: "incorrect frame count");
            return {};
        }
        std::vector<float> result(size_t(frames) * 2);
        for (unsigned index = 0; index < frames; ++index)
            for (unsigned channel = 0; channel < 2; ++channel)
                result[index * 2 + channel] = output.floatChannelData[channel][index];
        return result;
    }
    return {};
}
double peak(const std::vector<float>& samples) {
    double result = 0;
    for (float sample : samples) result = std::max(result, std::abs(double(sample)));
    return result;
}
double difference(const std::vector<float>& first, const std::vector<float>& second, float gain = 1) {
    if (first.empty() || first.size() != second.size()) return INFINITY;
    double result = 0;
    for (size_t index = 0; index < first.size(); ++index)
        result = std::max(result, std::abs(double(first[index] * gain) - second[index]));
    return result;
}
unsigned sourceCount(AVAudioEngine *engine) {
    unsigned count = 0;
    for (AVAudioNode *node in engine.attachedNodes) count += [node isKindOfClass:AVAudioSourceNode.class];
    return count;
}

int originalAudio(NSString *root, NSString *scratch, AVAudioFormat *format) {
    AVAudioEngine *engine = offlineEngine(format);
    if (!engine) return 77;
    SDBAudioMixer *mixer = [[SDBAudioMixer alloc] initWithEngine:engine];
    NSError *error = nil;
    NSData *manifestData = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]];
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error] : nil;
    NSArray *sounds = manifest[@"sounds"];
    REQUIRE(sounds.count == 12, "authoritative manifest contains twelve original sounds");
    NSString *copy = [scratch stringByAppendingPathComponent:@"cached-TypewriterA_08.wav"];
    for (NSDictionary *entry in sounds) {
        NSString *path = [root stringByAppendingPathComponent:entry[@"name"]];
        uint32_t identifier = [entry[@"entry"] unsignedIntValue] + 1;
        if (identifier == 4) {
            REQUIRE([NSFileManager.defaultManager copyItemAtPath:path toPath:copy error:&error], "copy short source into task scratch");
            path = copy;
        }
        REQUIRE([mixer loadBuffer:identifier URL:[NSURL fileURLWithPath:path]], "predecode original PCM16 buffer");
    }
    REQUIRE([NSFileManager.defaultManager removeItemAtPath:copy error:&error], "remove only copied source before playback");
    REQUIRE([mixer prepare] && !mixer.failure, "prepare original PCM graph after source copy removal");
    REQUIRE(sourceCount(engine) == 1, "one persistent source mixes all original voices");
    REQUIRE([mixer voiceForSource:0] == nil && [mixer voiceForSource:10] == nil, "source identifiers stay within original nine voices");
    for (unsigned source = 1; source <= 9; ++source)
        REQUIRE([mixer voiceForSource:source] == [mixer voiceForSource:source], "logical source identity persists");
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:Quantum];
    SDBAudioVoice *voice = [mixer voiceForSource:1];
    REQUIRE([voice configureBuffer:4 loop:NO] && [voice play] && voice.isPlaying, "start cached original short sound");
    auto first = render(engine, output), second = render(engine, output);
    REQUIRE(peak(first) > .001 && !second.empty(), "cached original waveform renders after deleting copied WAV");
    [voice stop];
    REQUIRE(!voice.isPlaying && [voice play], "stop then play rewinds original source");
    REQUIRE(difference(first, render(engine, output)) < .000001, "rewind reproduces exact original samples");
    [voice pause];
    REQUIRE(!voice.isPlaying && peak(render(engine, output)) < .000001, "paused source renders silence");
    REQUIRE([voice play], "resume paused original source");
    REQUIRE(difference(second, render(engine, output)) < .000001, "resume keeps exact original sample cursor");
    [voice stop];
    voice.volume = .5;
    REQUIRE([voice play], "start original sound at half gain");
    REQUIRE(difference(first, render(engine, output), .5) < .000001, "gain applies exactly from first sample without parameter ramp");
    voice.volume = 1;
    REQUIRE([voice configureBuffer:4 loop:YES] && [voice play] && voice.numberOfLoops == -1, "configure original indefinite loop");
    for (unsigned block = 0; block < 32; ++block) REQUIRE(!render(engine, output).empty(), "render cached loop across endpoint");
    REQUIRE(voice.isPlaying, "loop remains active across multiple original durations");
    [voice stop];
    // Each original rate/channel configuration must finish near its PCM duration,
    // guarding against a converter that consumes only its first input chunk.
    for (NSDictionary *entry in sounds) {
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:
            [root stringByAppendingPathComponent:entry[@"name"]]] error:&error];
        const double expected = double(file.length) * format.sampleRate / file.processingFormat.sampleRate;
        REQUIRE(file && std::isfinite(expected) && expected > 0, "read independent original duration");
        REQUIRE([voice configureBuffer:[entry[@"entry"] unsignedIntValue] + 1 loop:NO] && [voice play] &&
                voice.numberOfLoops == 0, "replace loop or completed source with original one-shot");
        unsigned blocks = 0;
        double signal = 0;
        while (voice.isPlaying && blocks < unsigned(std::ceil(expected / Quantum)) + 2) {
            auto samples = render(engine, output);
            if (samples.empty()) return 1;
            signal = std::max(signal, peak(samples));
            ++blocks;
        }
        REQUIRE(!voice.isPlaying && signal > .001 && double(blocks * Quantum) >= expected - 256 &&
                double(blocks * Quantum) < expected + Quantum + 256, "entire original one-shot duration renders and completes");
    }
    REQUIRE([mixer prepare] && sourceCount(engine) == 1 && engine.isInManualRenderingMode,
            "repeated preparation reuses graph without hardware output");
    return 0;
}

// A short direct-rate stereo PCM fixture has distinct channels and no trailing
// silence, so exact endpoint wrapping/zero-fill cannot pass by chance.
std::vector<float> fixtureSamples() {
    std::vector<float> result;
    for (unsigned frame = 0; frame < 23; ++frame) {
        result.push_back(float(int(frame % 7) - 3) / 16);
        result.push_back(float(int(frame % 5) + 1) / 32);
    }
    return result;
}
bool writeFixture(NSString *path, const std::vector<float>& samples) {
    NSMutableData *data = [NSMutableData data];
    auto text = [&](const char *value) { [data appendBytes:value length:4]; };
    auto word = [&](uint32_t value, unsigned bytes) {
        for (unsigned byte = 0; byte < bytes; ++byte) { uint8_t x = uint8_t(value >> (byte * 8)); [data appendBytes:&x length:1]; }
    };
    text("RIFF"); word(36 + uint32_t(samples.size()) * 2, 4); text("WAVE"); text("fmt ");
    word(16, 4); word(1, 2); word(2, 2); word(44100, 4); word(44100 * 4, 4); word(4, 2); word(16, 2);
    text("data"); word(uint32_t(samples.size()) * 2, 4);
    for (float sample : samples) word(uint16_t(int16_t(sample * 32768)), 2);
    return [data writeToFile:path atomically:YES];
}
std::vector<float> repeated(const std::vector<float>& samples, unsigned first, unsigned frames, float gain = 1) {
    std::vector<float> result(size_t(frames) * 2);
    const unsigned length = unsigned(samples.size() / 2);
    for (unsigned frame = 0; frame < frames; ++frame)
        for (unsigned channel = 0; channel < 2; ++channel)
            result[frame * 2 + channel] = samples[((first + frame) % length) * 2 + channel] * gain;
    return result;
}
int exactTransport(NSString *scratch, AVAudioFormat *format) {
    AVAudioEngine *engine = offlineEngine(format);
    if (!engine) return 77;
    SDBAudioMixer *mixer = [[SDBAudioMixer alloc] initWithEngine:engine];
    const auto samples = fixtureSamples();
    NSString *path = [scratch stringByAppendingPathComponent:@"stereo-endpoint.wav"];
    REQUIRE(writeFixture(path, samples), "write bounded PCM16 stereo fixture in task scratch");
    REQUIRE([mixer loadBuffer:1 URL:[NSURL fileURLWithPath:path]], "decode exact direct-rate stereo fixture");
    REQUIRE([mixer prepare], "prepare exact transport graph");
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:Quantum];
    SDBAudioVoice *voice = [mixer voiceForSource:1];
    REQUIRE([voice configureBuffer:1 loop:NO] && [voice play], "play one-shot endpoint fixture");
    std::vector<float> oneShot(128, 0);
    std::copy(samples.begin(), samples.end(), oneShot.begin());
    REQUIRE(difference(oneShot, render(engine, output, 64)) < .000001 && !voice.isPlaying,
            "one-shot preserves stereo PCM then zero-fills exact endpoint");
    REQUIRE([voice play], "completed voice can replay without reconfiguration");
    REQUIRE(difference(samples, render(engine, output, 23)) < .000001 && !voice.isPlaying,
            "replayed completed voice begins at first sample and completes at exact frame");
    REQUIRE([voice configureBuffer:1 loop:YES] && [voice play], "loop short stereo fixture");
    REQUIRE(difference(repeated(samples, 0, 64), render(engine, output, 64)) < .000001,
            "loop wraps exact source endpoint within output block");
    [voice pause];
    REQUIRE(peak(render(engine, output, 17)) == 0 && !voice.isPlaying, "pause emits exact silence without consuming samples");
    REQUIRE([voice play], "resume short loop");
    REQUIRE(difference(repeated(samples, 64, 17), render(engine, output, 17)) < .000001,
            "resume retains cursor across nonquantum-sized blocks");
    [voice stop];
    REQUIRE([voice play], "play after stop restarts loop");
    REQUIRE(difference(repeated(samples, 0, 17), render(engine, output, 17)) < .000001,
            "stop rewinds independent of prior cursor");
    voice.volume = .25;
    REQUIRE(difference(repeated(samples, 17, 17, .25), render(engine, output, 17)) < .000001,
            "live voice gain applies on next render block without delay");
    mixer.outputVolume = 0;
    REQUIRE(peak(render(engine, output, 17)) == 0, "master process mute is exact while transport advances");
    mixer.outputVolume = .5;
    REQUIRE(difference(repeated(samples, 51, 17, .125), render(engine, output, 17)) < .000001,
            "master gain combines with voice gain and mute preserved cursor");
    mixer.outputVolume = 1;
    [voice stop];
    for (unsigned source = 1; source <= 9; ++source) {
        SDBAudioVoice *v = [mixer voiceForSource:source];
        v.volume = .0625;
        REQUIRE([v configureBuffer:1 loop:YES] && [v play], "activate each original logical source simultaneously");
    }
    REQUIRE(difference(repeated(samples, 0, 64, 9 * .0625), render(engine, output, 64)) < .000001,
            "nine simultaneous source gains sum exact stereo samples");
    for (unsigned source = 2; source <= 9; ++source) [[mixer voiceForSource:source] stop];
    voice.volume = 1;
    // Simulate an engine stopped by the OS (including watchOS auto shutdown).
    // Event controls stay queued; only wakeIfNeeded may restart the engine.
    [engine stop];
    REQUIRE(!engine.isRunning, "simulate system stopping persistent engine");
    REQUIRE([voice configureBuffer:1 loop:YES] && [voice play], "queue transport while engine is stopped");
    for (unsigned event = 0; event < 64; ++event) [mixer wakeIfNeeded];
    for (unsigned retry = 0; retry < 500 && !engine.isRunning; ++retry) [NSThread sleepForTimeInterval:.001];
    REQUIRE(engine.isRunning && !mixer.failure, "asynchronous event wake restarts engine without blocking play");
    REQUIRE([mixer prepare] && sourceCount(engine) == 1, "wake and lifecycle preparation share one persistent source graph");
    REQUIRE(difference(repeated(samples, 0, 64), render(engine, output, 64)) < .000001,
            "commands queued during engine shutdown retain exact playback state");
    [voice pause];
    [engine stop];
    REQUIRE([mixer prepare] && [voice play], "lifecycle preparation resumes existing paused voice");
    REQUIRE(difference(repeated(samples, 64, 17), render(engine, output, 17)) < .000001,
            "engine restart retains paused loop sample cursor");
    voice.volume = NAN; mixer.outputVolume = INFINITY;
    REQUIRE(voice.volume == 0 && mixer.outputVolume == 0, "nonfinite gains become process-local silence");
    voice.volume = -1; mixer.outputVolume = 2;
    REQUIRE(voice.volume == 0 && mixer.outputVolume == 1, "gains clamp to original volume range");
    return 0;
}
}

int main(int argc, const char *argv[]) {
    if (argc != 3) { std::fprintf(stderr, "Usage: AudioMixerTests Resources/Original task-scratch\n"); return 64; }
    @autoreleasepool {
        @try {
            NSString *root = [NSString stringWithUTF8String:argv[1]], *scratch = [NSString stringWithUTF8String:argv[2]];
            AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
            int result = originalAudio(root, scratch, format);
            if (!result) result = exactTransport(scratch, format);
            if (result) return result;
            std::printf("PASS %u audio checks: twelve complete original PCM decodes; exact stereo, loop/EOF, stop/rewind, pause/resume, gains/mute, nine-voice sum, cached playback, asynchronous wake; offline, no hardware output.\n", checks);
            return 0;
        } @catch (NSException *exception) {
            std::fprintf(stderr, "FAIL audio exception: %s\n", exception.reason.UTF8String);
            return 1;
        }
    }
}
