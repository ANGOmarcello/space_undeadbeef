//
//  PerformanceSmoke.mm
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//
// Headless CPU stage benchmark. Keep the warm-up and input sequence compatible
// with the original 1,800-sample baseline. Menu phases are reported separately;
// neither CPU work nor queued Metal submissions measure display scanout.

#import <Foundation/Foundation.h>
#import "SDBEngine.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr unsigned DefaultSamples = 1800;
constexpr unsigned MaximumSamples = 36000;
constexpr unsigned WarmupSamples = 90;
constexpr double SimulationStep = 1.0 / 60.0;
constexpr double FrameBudgetMilliseconds = SimulationStep * 1000;

struct Samples {
    std::vector<double> simulation, rendering, total;

    void reserve(size_t count) {
        simulation.reserve(count);
        rendering.reserve(count);
        total.reserve(count);
    }

    void record(double simulationMilliseconds, double renderingMilliseconds) {
        simulation.push_back(simulationMilliseconds);
        rendering.push_back(renderingMilliseconds);
        total.push_back(simulationMilliseconds + renderingMilliseconds);
    }
};

double milliseconds(Clock::duration duration) {
    return std::chrono::duration<double, std::milli>(duration).count();
}

double percentile(const std::vector<double> &sorted, double fraction) {
    // Nearest-rank percentile, including the maximum when there is one sample.
    const size_t rank = size_t(std::ceil(fraction * sorted.size()));
    return sorted[std::max(size_t(1), rank) - 1];
}

void report(const char *label, std::vector<double> values) {
    if (values.empty()) {
        printf("%s n=0\n", label);
        return;
    }
    std::sort(values.begin(), values.end());
    const double sum = std::accumulate(values.begin(), values.end(), 0.0);
    const size_t overBudget = std::count_if(values.begin(), values.end(),
        [](double value) { return value > FrameBudgetMilliseconds; });
    printf("%s n=%zu mean=%.3f p50=%.3f p95=%.3f p99=%.3f max=%.3f over16.67=%zu\n",
           label, values.size(), sum / values.size(), percentile(values, 0.50),
           percentile(values, 0.95), percentile(values, 0.99), values.back(), overBudget);
}

void reportStages(const std::string &prefix, const Samples &samples) {
    report((prefix + "simulation").c_str(), samples.simulation);
    report((prefix + "renderCPU+submit").c_str(), samples.rendering);
    report((prefix + "totalCPU").c_str(), samples.total);
}

bool check(SDBEngine *engine, const char *stage) {
    if (!engine) {
        fprintf(stderr, "FAIL %s: engine was not created\n", stage);
        return false;
    }
    if (!engine.failure) return true;
    fprintf(stderr, "FAIL %s: %s\n%s\n", stage, engine.failure.UTF8String,
            engine.diagnostics.UTF8String);
    return false;
}

bool parseCount(const char *text, unsigned &count) {
    char *end = nullptr;
    errno = 0;
    const unsigned long parsed = strtoul(text, &end, 10);
    if (errno || !text[0] || *end || !parsed || parsed > MaximumSamples) return false;
    count = unsigned(parsed);
    return true;
}

NSString *prepareIsolatedSaveDirectory(const char *argument) {
    NSString *path = [NSString stringWithUTF8String:argument];
    if (!path.length || !path.isAbsolutePath) {
        fprintf(stderr, "Save directory must be an absolute task-owned temporary path.\n");
        return nil;
    }
    // Resolve the existing prefix with the same API for roots and a not-yet-
    // created child. Foundation can spell those as /tmp and /private/tmp.
    std::error_code pathError;
    const auto resolved = std::filesystem::weakly_canonical(path.fileSystemRepresentation, pathError);
    if (pathError) {
        fprintf(stderr, "Cannot resolve isolated save directory.\n");
        return nil;
    }
    path = [NSString stringWithUTF8String:resolved.c_str()];
    bool temporary = false;
    for (NSString *root in @[NSTemporaryDirectory(), @"/private/tmp"]) {
        const auto resolvedRoot = std::filesystem::weakly_canonical(root.fileSystemRepresentation, pathError);
        if (pathError) continue;
        NSString *canonical = [NSString stringWithUTF8String:resolvedRoot.c_str()];
        NSString *prefix = [canonical stringByAppendingString:@"/"];
        temporary |= [path hasPrefix:prefix];
    }
    if (!temporary) {
        fprintf(stderr, "Save directory must be inside the system temporary directory.\n");
        return nil;
    }
    NSError *error = nil;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "Cannot create isolated save directory: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    NSArray<NSString *> *contents = [files contentsOfDirectoryAtPath:path error:&error];
    if (!contents || contents.count) {
        fprintf(stderr, "Save directory must be empty for a reproducible isolated run.\n");
        return nil;
    }
    return path;
}

void applyBaselineInput(SDBEngine *engine, unsigned index, double offsetX, double offsetY) {
    const unsigned phase = index % 150;
    if (phase == 0) [engine touchPhase:0 x:60 + offsetX y:160 + offsetY];
    if (phase == 60) [engine touchPhase:2 x:60 + offsetX y:160 + offsetY];
    if (phase == 75) [engine touchPhase:0 x:300 + offsetX y:80 + offsetY];
    if (phase >= 75 && phase < 135) {
        [engine touchPhase:1 x:300 + offsetX + 120 * std::sin((phase - 75) * M_PI / 60)
                         y:80 + offsetY + (phase - 75) * 2];
    }
    if (phase == 135) [engine touchPhase:2 x:300 + offsetX y:200 + offsetY];
}

int run(int argc, char **argv) {
    if (argc < 3 || argc > 6) {
        fprintf(stderr, "Usage: PerformanceSmoke RESOURCE_DIRECTORY TEMP_SAVE_DIRECTORY [FRAMES=1800] [metal|watch] [paced|unpaced]\n");
        return 64;
    }
    unsigned count = DefaultSamples;
    if (argc > 3 && !parseCount(argv[3], count)) {
        fprintf(stderr, "Frame count must be between 1 and %u.\n", MaximumSamples);
        return 64;
    }
    const char *backend = argc > 4 ? argv[4] : "metal";
    const char *pacing = argc > 5 ? argv[5] : "paced";
    if ((strcmp(backend, "metal") && strcmp(backend, "watch")) ||
        (strcmp(pacing, "paced") && strcmp(pacing, "unpaced"))) {
        fprintf(stderr, "Backend must be metal or watch; pacing must be paced or unpaced.\n");
        return 64;
    }
    NSString *save = prepareIsolatedSaveDirectory(argv[2]);
    NSString *resources = [NSString stringWithUTF8String:argv[1]];
    if (!save || !resources.length) return 64;
    setenv("SDB_SAVE_DIRECTORY", save.UTF8String, 1);
    setenv("SDB_MUTE_AUDIO", "1", 1); // Only this process's mixer is muted.
    const bool watch = strcmp(backend, "watch") == 0;
    const bool paced = strcmp(pacing, "paced") == 0;
    if (watch) setenv("SDB_CPU_RENDERER", "1", 1);
    else unsetenv("SDB_CPU_RENDERER");

    SDBEngine *engine = [[SDBEngine alloc] initWithResourcePath:resources];
    if (!check(engine, "initialize")) return 1;
    if (!watch && !engine.usesMetalRenderer) {
        fprintf(stderr, "SKIP: Metal was requested but is unavailable in this process.\n");
        return 77;
    }
    const CGSize size = watch ? CGSizeMake(416, 496) : CGSizeMake(2622, 1206);
    [engine configureViewport:size displayScale:1 safeArea:CGRectMake(0, 0, size.width, size.height)];
    if (!check(engine, "configure viewport")) return 1;
    for (unsigned index = 0; index < WarmupSamples; ++index) {
        [engine update:SimulationStep];
        if (!check(engine, "warm-up")) return 1;
    }
    const double offsetX = (engine.logicalSize.width - 480) / 2;
    const double offsetY = (engine.logicalSize.height - 320) / 2;
    [engine touchPhase:0 x:160 + offsetX y:40 + offsetY];
    [engine update:SimulationStep];
    [engine touchPhase:2 x:160 + offsetX y:40 + offsetY];
    if (!check(engine, "Game Start")) return 1;

    printf("workload=original-baseline samples=%u pacing=%s renderer=%s raster=%.0fx%.0f\n",
           count, pacing, engine.usesMetalRenderer ? "Metal" : "CPU", size.width, size.height);
    printf("CPU stage milliseconds exclude input, bookkeeping and sleep; no GPU completion or display FPS is measured.\n");
    if (!paced) printf("Unpaced Metal submissions may encounter bounded queue backpressure.\n");
    fflush(stdout);

    Samples all;
    all.reserve(count);
    std::map<NSInteger, Samples> phases;
    unsigned gameFrames = 0, gameToTitleTransitions = 0, missedDeadlines = 0;
    double maximumLateness = 0;
    const auto began = Clock::now();
    for (unsigned index = 0; index < count; ++index) {
        @autoreleasepool {
            applyBaselineInput(engine, index, offsetX, offsetY);
            const NSInteger before = engine.gameMenuType;
            const auto start = Clock::now();
            [engine advanceSimulation:SimulationStep];
            const auto afterSimulation = Clock::now();
            [engine renderFrame];
            const auto afterRender = Clock::now();
            if (!check(engine, "measured frame")) return 1;
            const NSInteger after = engine.gameMenuType;
            const double simulation = milliseconds(afterSimulation - start);
            const double rendering = milliseconds(afterRender - afterSimulation);
            all.record(simulation, rendering);
            phases[after].record(simulation, rendering);
            gameFrames += after == 0;
            gameToTitleTransitions += before == 0 && after == 1;

            if (paced) {
                const auto deadline = began + std::chrono::duration_cast<Clock::duration>(
                    std::chrono::duration<double>((index + 1) * SimulationStep));
                const double lateness = milliseconds(Clock::now() - deadline);
                if (lateness > 0) {
                    ++missedDeadlines;
                    maximumLateness = std::max(maximumLateness, lateness);
                }
                std::this_thread::sleep_until(deadline);
            }
        }
    }
    const double wallSeconds = std::chrono::duration<double>(Clock::now() - began).count();
    reportStages("", all); // Retain the original aggregate labels for comparisons.
    for (const auto &phase : phases) {
        const char *name = phase.first == 0 ? "game" : phase.first == 1 ? "title" : "other";
        const std::string prefix = "menuType" + std::to_string(phase.first) + "_" + name + ".";
        reportStages(prefix, phase.second);
    }
    printf("gameFrames=%u/%u gameToTitleTransitions=%u restarts=0 wallSeconds=%.3f simulatedSeconds=%.3f\n",
           gameFrames, count, gameToTitleTransitions, wallSeconds, count * SimulationStep);
    printf("Phase labels use the post-step original menuType; game includes death animations and transitions.\n");
    if (paced) {
        printf("pacedCPUDeadlineMisses=%u/%u maxLateness=%.3fms budget=%.3fms\n",
               missedDeadlines, count, maximumLateness, FrameBudgetMilliseconds);
    } else {
        printf("pacedCPUDeadlineMisses=not-applicable\n");
    }
    printf("%s\n", engine.diagnostics.UTF8String);
    fflush(stdout);
    return 0;
}
} // namespace

int main(int argc, char **argv) {
    @autoreleasepool {
        return run(argc, argv);
    }
}
