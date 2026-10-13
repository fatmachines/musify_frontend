// Musify: a 10-band equalizer for just_audio on iOS/macOS.
#import "./include/just_audio/MusifyEqualizer.h"
#import <MediaToolbox/MediaToolbox.h>
#include <math.h>
#include <stdatomic.h>

#define MUSIFY_EQ_BANDS 10
#define MUSIFY_EQ_MAX_CHANNELS 8

static const double kMusifyFrequencies[MUSIFY_EQ_BANDS] = {
    32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
};

// Written on the main thread, read on the audio thread. A tap rebuilds its
// filters whenever the version changes.
static double gMusifyGains[MUSIFY_EQ_BANDS];
static atomic_int gMusifyEnabled = 0;
static atomic_int gMusifyVersion = 1;

typedef struct {
    double b0, b1, b2, a1, a2;
} MusifyBiquad;

typedef struct {
    double x1, x2, y1, y2;
} MusifyBiquadState;

typedef struct {
    double sampleRate;
    int isFloat;
    int interleaved;
    int version;
    int enabled;
    double outputGain;
    int active[MUSIFY_EQ_BANDS];
    MusifyBiquad filters[MUSIFY_EQ_BANDS];
    MusifyBiquadState state[MUSIFY_EQ_MAX_CHANNELS][MUSIFY_EQ_BANDS];
} MusifyTapContext;

/// Band width: about an octave, as usual for a 10-band graphic equalizer,
/// so neighbouring bands don't pile up much.
static const double kMusifyQ = 1.41;

/// Peaking filters from the RBJ audio EQ cookbook.
static void MusifyComputeFilters(MusifyTapContext *ctx) {
    ctx->version = atomic_load(&gMusifyVersion);
    ctx->enabled = atomic_load(&gMusifyEnabled);
    double maxGain = 0;
    for (int i = 0; i < MUSIFY_EQ_BANDS; i++) {
        double gain = gMusifyGains[i];
        if (gain > maxGain) maxGain = gain;
        double frequency = kMusifyFrequencies[i];
        ctx->active[i] = fabs(gain) > 0.01 && frequency < ctx->sampleRate * 0.45;
        if (!ctx->active[i]) continue;
        double A = pow(10.0, gain / 40.0);
        double w0 = 2.0 * M_PI * frequency / ctx->sampleRate;
        double alpha = sin(w0) / (2.0 * kMusifyQ);
        double cosw0 = cos(w0);
        double a0 = 1.0 + alpha / A;
        ctx->filters[i].b0 = (1.0 + alpha * A) / a0;
        ctx->filters[i].b1 = (-2.0 * cosw0) / a0;
        ctx->filters[i].b2 = (1.0 - alpha * A) / a0;
        ctx->filters[i].a1 = (-2.0 * cosw0) / a0;
        ctx->filters[i].a2 = (1.0 - alpha / A) / a0;
    }
    // Some headroom so boosted bands don't clip.
    ctx->outputGain = pow(10.0, -maxGain * 0.5 / 20.0);
}

static inline float MusifyProcessSample(MusifyTapContext *ctx, int channel, float input) {
    double x = input;
    for (int i = 0; i < MUSIFY_EQ_BANDS; i++) {
        if (!ctx->active[i]) continue;
        MusifyBiquad *f = &ctx->filters[i];
        MusifyBiquadState *s = &ctx->state[channel][i];
        double y = f->b0 * x + f->b1 * s->x1 + f->b2 * s->x2 - f->a1 * s->y1 - f->a2 * s->y2;
        s->x2 = s->x1;
        s->x1 = x;
        s->y2 = s->y1;
        s->y1 = y;
        x = y;
    }
    x *= ctx->outputGain;
    if (x > 1.0) x = 1.0;
    if (x < -1.0) x = -1.0;
    return (float)x;
}

static void MusifyTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    MusifyTapContext *ctx = calloc(1, sizeof(MusifyTapContext));
    ctx->sampleRate = 44100;
    ctx->version = -1;
    *tapStorageOut = ctx;
}

static void MusifyTapFinalize(MTAudioProcessingTapRef tap) {
    free(MTAudioProcessingTapGetStorage(tap));
}

static void MusifyTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                             const AudioStreamBasicDescription *format) {
    MusifyTapContext *ctx = MTAudioProcessingTapGetStorage(tap);
    ctx->sampleRate = format->mSampleRate > 0 ? format->mSampleRate : 44100;
    ctx->isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mBitsPerChannel == 32;
    ctx->interleaved = !(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    memset(ctx->state, 0, sizeof(ctx->state));
    ctx->version = -1;
}

static void MusifyTapUnprepare(MTAudioProcessingTapRef tap) {}

static void MusifyTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                             MTAudioProcessingTapFlags flags, AudioBufferList *bufferList,
                             CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, NULL, numberFramesOut);
    if (status != noErr) return;
    MusifyTapContext *ctx = MTAudioProcessingTapGetStorage(tap);
    if (!ctx->isFloat) return;
    if (ctx->version != atomic_load(&gMusifyVersion)) MusifyComputeFilters(ctx);
    if (!ctx->enabled) return;

    CMItemCount frames = *numberFramesOut;
    for (UInt32 b = 0; b < bufferList->mNumberBuffers; b++) {
        AudioBuffer *buffer = &bufferList->mBuffers[b];
        float *samples = (float *)buffer->mData;
        if (samples == NULL) continue;
        if (ctx->interleaved) {
            UInt32 channels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
            for (CMItemCount f = 0; f < frames; f++) {
                for (UInt32 c = 0; c < channels; c++) {
                    int channel = c < MUSIFY_EQ_MAX_CHANNELS ? (int)c : MUSIFY_EQ_MAX_CHANNELS - 1;
                    samples[f * channels + c] = MusifyProcessSample(ctx, channel, samples[f * channels + c]);
                }
            }
        } else {
            int channel = b < MUSIFY_EQ_MAX_CHANNELS ? (int)b : MUSIFY_EQ_MAX_CHANNELS - 1;
            for (CMItemCount f = 0; f < frames; f++) {
                samples[f] = MusifyProcessSample(ctx, channel, samples[f]);
            }
        }
    }
}

static FlutterMethodChannel *gMusifyChannel;

@implementation MusifyEqualizer

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    gMusifyChannel = [FlutterMethodChannel methodChannelWithName:@"musify/equalizer"
                                                 binaryMessenger:[registrar messenger]];
    [gMusifyChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
        if ([@"bands" isEqualToString:call.method]) {
            NSMutableArray<NSNumber *> *bands = [NSMutableArray array];
            for (int i = 0; i < MUSIFY_EQ_BANDS; i++) {
                [bands addObject:@(kMusifyFrequencies[i])];
            }
            result(bands);
        } else if ([@"set" isEqualToString:call.method]) {
            NSDictionary *args = (NSDictionary *)call.arguments;
            NSArray *gains = args[@"gains"];
            for (int i = 0; i < MUSIFY_EQ_BANDS; i++) {
                gMusifyGains[i] = i < (int)gains.count ? [gains[i] doubleValue] : 0;
            }
            atomic_store(&gMusifyEnabled, [args[@"enabled"] boolValue] ? 1 : 0);
            atomic_fetch_add(&gMusifyVersion, 1);
            result(nil);
        } else {
            result(FlutterMethodNotImplemented);
        }
    }];
}

+ (void)attachToPlayerItem:(AVPlayerItem *)item {
    AVAsset *asset = item.asset;
    __weak AVPlayerItem *weakItem = item;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) return;
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (tracks.count == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *item = weakItem;
            if (item == nil) return;
            MTAudioProcessingTapCallbacks callbacks;
            callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
            callbacks.clientInfo = NULL;
            callbacks.init = MusifyTapInit;
            callbacks.finalize = MusifyTapFinalize;
            callbacks.prepare = MusifyTapPrepare;
            callbacks.unprepare = MusifyTapUnprepare;
            callbacks.process = MusifyTapProcess;
            MTAudioProcessingTapRef tap = NULL;
            OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
            if (status != noErr || tap == NULL) {
                NSLog(@"[Musify] equalizer tap failed: %d", (int)status);
                return;
            }
            AVMutableAudioMixInputParameters *params =
                [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
            params.audioTapProcessor = tap;
            CFRelease(tap);
            AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
            mix.inputParameters = @[params];
            item.audioMix = mix;
        });
    }];
}

@end
