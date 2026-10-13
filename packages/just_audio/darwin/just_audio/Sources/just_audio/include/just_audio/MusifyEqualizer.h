// Musify: a 10-band equalizer for just_audio on iOS/macOS.
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

/// Runs every song through a 10-band peaking equalizer (32 Hz to 16 kHz)
/// using an audio processing tap on its player item. Settings are global and
/// come from Dart over the "musify/equalizer" channel:
///
///   bands -> [32, 64, ..., 16000] (Hz)
///   set {enabled: bool, gains: [dB x 10]}
@interface MusifyEqualizer : NSObject

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar;

/// Adds the equalizer to [item] once its audio track is known. It is always
/// attached, so turning it on or changing a band applies straight away.
+ (void)attachToPlayerItem:(AVPlayerItem *)item;

@end
