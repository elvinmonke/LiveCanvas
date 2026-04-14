/**
 * LiveCanvas Wallpaper Daemon
 *
 * A headless agent that renders a looping video behind the desktop icons
 * on a specific display.  Controlled via Darwin notifications and
 * NSUserDefaults so the main app never needs a direct IPC channel.
 *
 * Usage:
 *   WallpaperDaemon <videoPath> <volume> <scaleMode> <displayID>
 *
 *   videoPath  — absolute path to the video file
 *   volume     — 0.0 .. 1.0
 *   scaleMode  — 0 Fit, 1 Fill, 2 Stretch, 3 Center
 *   displayID  — CGDirectDisplayID (decimal)
 */

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
#pragma mark - Scale-mode helpers
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, LCScaleMode) {
    LCScaleModeFit     = 0,  // AVLayerVideoGravityResizeAspect
    LCScaleModeFill    = 1,  // AVLayerVideoGravityResizeAspectFill
    LCScaleModeStretch = 2,  // AVLayerVideoGravityResize
    LCScaleModeCenter  = 3,  // AVLayerVideoGravityResizeAspect (centered, no upscale)
};

static NSString *videoGravityForScaleMode(LCScaleMode mode) {
    switch (mode) {
        case LCScaleModeFill:    return AVLayerVideoGravityResizeAspectFill;
        case LCScaleModeStretch: return AVLayerVideoGravityResize;
        case LCScaleModeCenter:  return AVLayerVideoGravityResizeAspect;
        case LCScaleModeFit:
        default:                 return AVLayerVideoGravityResizeAspect;
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Power-source helper
// ---------------------------------------------------------------------------

static BOOL isOnBatteryPower(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return NO;

    CFArrayRef sources = IOPSCopyPowerSourcesList(info);
    if (!sources) {
        CFRelease(info);
        return NO;
    }

    BOOL onBattery = NO;
    CFIndex count = CFArrayGetCount(sources);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(info,
                                   CFArrayGetValueAtIndex(sources, i));
        if (!desc) continue;

        CFStringRef type = CFDictionaryGetValue(desc, CFSTR(kIOPSTransportTypeKey));
        CFStringRef state = CFDictionaryGetValue(desc, CFSTR(kIOPSPowerSourceStateKey));
        if (type && CFStringCompare(type, CFSTR(kIOPSInternalType), 0) == kCFCompareEqualTo) {
            if (state && CFStringCompare(state, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo) {
                onBattery = YES;
            }
        }
    }

    CFRelease(sources);
    CFRelease(info);
    return onBattery;
}

// ---------------------------------------------------------------------------
#pragma mark - Fullscreen-app detection
// ---------------------------------------------------------------------------

static BOOL isFullscreenAppActive(void) {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!windowList) return NO;

    BOOL found = NO;
    CFIndex count = CFArrayGetCount(windowList);
    NSRect screenFrame = [[NSScreen mainScreen] frame];

    for (CFIndex i = 0; i < count; i++) {
        NSDictionary *entry = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);
        NSNumber *layer = entry[(__bridge NSString *)kCGWindowLayer];

        // Normal window layer is 0.
        if (layer && [layer integerValue] == 0) {
            CGRect bounds;
            NSDictionary *boundsDict = entry[(__bridge NSString *)kCGWindowBounds];
            if (boundsDict) {
                CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &bounds);
                if (CGRectEqualToRect(bounds, screenFrame)) {
                    found = YES;
                    break;
                }
            }
        }
    }

    CFRelease(windowList);
    return found;
}

// ---------------------------------------------------------------------------
#pragma mark - WallpaperDaemon class
// ---------------------------------------------------------------------------

@interface WallpaperDaemon : NSObject

@property (nonatomic, strong) NSWindow        *window;
@property (nonatomic, strong) AVQueuePlayer   *player;
@property (nonatomic, strong) AVPlayerLooper  *looper;
@property (nonatomic, strong) AVPlayerLayer   *playerLayer;
@property (nonatomic, strong) NSTimer         *watchdogTimer;

@property (nonatomic, copy)   NSString        *videoPath;
@property (nonatomic, assign) float            volume;
@property (nonatomic, assign) LCScaleMode      scaleMode;
@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) BOOL             paused;

- (instancetype)initWithVideoPath:(NSString *)path
                           volume:(float)volume
                        scaleMode:(LCScaleMode)mode
                        displayID:(CGDirectDisplayID)displayID;
- (void)start;

@end

// ---------------------------------------------------------------------------
#pragma mark - Implementation
// ---------------------------------------------------------------------------

@implementation WallpaperDaemon

- (instancetype)initWithVideoPath:(NSString *)path
                           volume:(float)vol
                        scaleMode:(LCScaleMode)mode
                        displayID:(CGDirectDisplayID)dID {
    self = [super init];
    if (self) {
        _videoPath  = [path copy];
        _volume     = vol;
        _scaleMode  = mode;
        _displayID  = dID;
        _paused     = NO;
    }
    return self;
}

// ---- public ---------------------------------------------------------------

- (void)start {
    [self createWindow];
    [self createPlayer];
    [self registerNotifications];
    [self startWatchdog];
    [self applyPowerPolicy];
}

// ---- window ---------------------------------------------------------------

- (void)createWindow {
    // Resolve the target display frame.
    NSRect displayFrame = NSZeroRect;
    for (NSScreen *screen in [NSScreen screens]) {
        NSDictionary *desc = [screen deviceDescription];
        NSNumber *screenNumber = desc[@"NSScreenNumber"];
        if (screenNumber && (CGDirectDisplayID)[screenNumber unsignedIntValue] == _displayID) {
            displayFrame = [screen frame];
            break;
        }
    }
    if (NSIsEmptyRect(displayFrame)) {
        // Fallback: use main screen.
        displayFrame = [[NSScreen mainScreen] frame];
    }

    NSUInteger styleMask = NSWindowStyleMaskBorderless;
    _window = [[NSWindow alloc] initWithContentRect:displayFrame
                                          styleMask:styleMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];

    [_window setLevel:(kCGDesktopWindowLevel - 1)];
    [_window setOpaque:NO];
    [_window setBackgroundColor:[NSColor clearColor]];
    [_window setHasShadow:NO];
    [_window setIgnoresMouseEvents:YES];
    [_window setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary      |
                                    NSWindowCollectionBehaviorIgnoresCycle    |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary)];
    [_window setFrame:displayFrame display:YES];
    [_window orderFront:nil];
}

// ---- player ---------------------------------------------------------------

- (void)createPlayer {
    NSURL *fileURL = [NSURL fileURLWithPath:_videoPath];
    AVPlayerItem *templateItem = [AVPlayerItem playerItemWithURL:fileURL];

    _player = [AVQueuePlayer queuePlayerWithItems:@[templateItem]];
    _player.volume = _volume;
    _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;

    // AVPlayerLooper keeps re-enqueuing the template item.
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player
                                        templateItem:templateItem];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _playerLayer.videoGravity = videoGravityForScaleMode(_scaleMode);
    _playerLayer.frame = _window.contentView.bounds;
    _playerLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;

    [_window.contentView setWantsLayer:YES];
    [_window.contentView.layer addSublayer:_playerLayer];

    [_player play];
}

// ---- Darwin notifications -------------------------------------------------

- (void)registerNotifications {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();

    // Volume changed
    CFNotificationCenterAddObserver(
        center,
        (__bridge const void *)(self),
        volumeChangedCallback,
        CFSTR("com.livecanvas.volumeChanged"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // Scale-mode changed
    CFNotificationCenterAddObserver(
        center,
        (__bridge const void *)(self),
        scaleModeChangedCallback,
        CFSTR("com.livecanvas.scaleModeChanged"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // Terminate
    CFNotificationCenterAddObserver(
        center,
        (__bridge const void *)(self),
        terminateCallback,
        CFSTR("com.livecanvas.terminate"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // Display sleep / wake via NSWorkspace
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(handleScreenSleep:)
               name:NSWorkspaceScreensDidSleepNotification
             object:nil];

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(handleScreenWake:)
               name:NSWorkspaceScreensDidWakeNotification
             object:nil];

    // Power source change (battery <-> AC)
    CFRunLoopSourceRef powerSource = IOPSNotificationCreateRunLoopSource(
        powerSourceCallback, (__bridge void *)(self));
    if (powerSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, kCFRunLoopDefaultMode);
        CFRelease(powerSource);
    }
}

// ---- notification callbacks (C functions) ---------------------------------

static void volumeChangedCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFNotificationName name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    WallpaperDaemon *daemon = (__bridge WallpaperDaemon *)observer;
    NSUserDefaults *defaults = [[NSUserDefaults alloc]
        initWithSuiteName:@"com.elvin.livecanvas"];
    float vol = [defaults floatForKey:@"lc_volume"];
    daemon.volume = vol;
    daemon.player.volume = vol;
}

static void scaleModeChangedCallback(CFNotificationCenterRef center,
                                     void *observer,
                                     CFNotificationName name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    WallpaperDaemon *daemon = (__bridge WallpaperDaemon *)observer;
    NSUserDefaults *defaults = [[NSUserDefaults alloc]
        initWithSuiteName:@"com.elvin.livecanvas"];
    LCScaleMode mode = (LCScaleMode)[defaults integerForKey:@"lc_scaleMode"];
    daemon.scaleMode = mode;
    daemon.playerLayer.videoGravity = videoGravityForScaleMode(mode);
}

static void terminateCallback(CFNotificationCenterRef center,
                               void *observer,
                               CFNotificationName name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    WallpaperDaemon *daemon = (__bridge WallpaperDaemon *)observer;
    [daemon shutdown];
}

static void powerSourceCallback(void *context) {
    WallpaperDaemon *daemon = (__bridge WallpaperDaemon *)context;
    [daemon applyPowerPolicy];
}

// ---- screen sleep / wake --------------------------------------------------

- (void)handleScreenSleep:(NSNotification *)note {
    _paused = YES;
    [_player pause];
}

- (void)handleScreenWake:(NSNotification *)note {
    _paused = NO;
    [_player play];
    [self applyPowerPolicy];
}

// ---- watchdog: pause when fullscreen app is active ------------------------

- (void)startWatchdog {
    _watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                     target:self
                                                   selector:@selector(watchdogTick:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)watchdogTick:(NSTimer *)timer {
    if (_paused) return;

    if (isFullscreenAppActive()) {
        if (_player.rate != 0.0) {
            [_player pause];
        }
    } else {
        if (_player.rate == 0.0) {
            [_player play];
            [self applyPowerPolicy];
        }
    }
}

// ---- power policy ---------------------------------------------------------

- (void)applyPowerPolicy {
    if (isOnBatteryPower()) {
        // Reduce playback rate to save energy.
        _player.rate = 0.5;
    } else {
        _player.rate = 1.0;
    }
}

// ---- shutdown -------------------------------------------------------------

- (void)shutdown {
    [_watchdogTimer invalidate];
    _watchdogTimer = nil;

    CFNotificationCenterRemoveEveryObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self));

    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];

    [_player pause];
    _player = nil;
    _looper = nil;

    [_playerLayer removeFromSuperlayer];
    _playerLayer = nil;

    [_window orderOut:nil];
    _window = nil;

    [NSApp terminate:nil];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - main
// ---------------------------------------------------------------------------

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 5) {
            fprintf(stderr,
                "Usage: WallpaperDaemon <videoPath> <volume> <scaleMode> <displayID>\n"
                "  videoPath  — absolute path to video file\n"
                "  volume     — 0.0 .. 1.0\n"
                "  scaleMode  — 0 Fit | 1 Fill | 2 Stretch | 3 Center\n"
                "  displayID  — CGDirectDisplayID (decimal)\n");
            return 1;
        }

        NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
        float volume        = (float)atof(argv[2]);
        LCScaleMode mode    = (LCScaleMode)atoi(argv[3]);
        CGDirectDisplayID displayID = (CGDirectDisplayID)atoi(argv[4]);

        // Clamp volume.
        if (volume < 0.0f) volume = 0.0f;
        if (volume > 1.0f) volume = 1.0f;

        // Validate video file exists.
        if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            fprintf(stderr, "Error: video file not found at %s\n", [videoPath UTF8String]);
            return 1;
        }

        // Set up the application (headless, no dock icon — controlled by Info.plist).
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        WallpaperDaemon *daemon = [[WallpaperDaemon alloc] initWithVideoPath:videoPath
                                                                      volume:volume
                                                                   scaleMode:mode
                                                                   displayID:displayID];
        [daemon start];

        // Enter the run loop.
        [NSApp run];
    }
    return 0;
}
