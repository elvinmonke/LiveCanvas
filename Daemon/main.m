/**
 * LiveCanvas Wallpaper Daemon
 *
 * Renders a looping video as the actual macOS desktop wallpaper.
 *
 * Strategy: Uses a two-layer approach for true wallpaper behavior:
 *   1. Finds the Finder's desktop window (the real wallpaper surface)
 *      and places our video window directly above it at the same level
 *   2. Falls back to kCGDesktopWindowLevel + kCGDesktopIconWindowLevel
 *      positioning to sit between wallpaper and icons
 *
 * Usage:
 *   wallpaperdaemon <videoPath> <volume> <scaleMode> <displayID>
 */

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
#pragma mark - Private API declarations
// ---------------------------------------------------------------------------

// Private CoreGraphics API to attach window to a specific space/desktop
typedef int CGSConnection;
typedef int CGSWindow;
extern CGSConnection _CGSDefaultConnection(void);
extern CGError CGSSetWindowLevel(CGSConnection cid, CGSWindow wid, CGWindowLevel level);

// ---------------------------------------------------------------------------
#pragma mark - Scale-mode helpers
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, LCScaleMode) {
    LCScaleModeFit     = 0,
    LCScaleModeFill    = 1,
    LCScaleModeStretch = 2,
    LCScaleModeCenter  = 3,
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
#pragma mark - Find Finder desktop window level
// ---------------------------------------------------------------------------

/**
 * Finds the actual Finder desktop window level by examining on-screen windows.
 * The Finder's desktop window is the lowest-level visible window owned by "Finder".
 * Returns the level, or kCGDesktopWindowLevel if not found.
 */
static CGWindowLevel findDesktopWindowLevel(void) {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!windowList) return kCGDesktopWindowLevel;

    CGWindowLevel desktopLevel = kCGDesktopWindowLevel;
    CGWindowLevel iconLevel = kCGDesktopWindowLevel;
    CFIndex count = CFArrayGetCount(windowList);

    for (CFIndex i = 0; i < count; i++) {
        NSDictionary *entry = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);
        NSString *ownerName = entry[(__bridge NSString *)kCGWindowOwnerName];
        NSNumber *layer = entry[(__bridge NSString *)kCGWindowLayer];

        if (!ownerName || !layer) continue;

        NSInteger level = [layer integerValue];

        if ([ownerName isEqualToString:@"Finder"]) {
            // Finder owns the desktop wallpaper window and the icon window
            // Desktop wallpaper is at kCGDesktopWindowLevel (typically -2147483623)
            // Desktop icons are at kCGDesktopIconWindowLevel (typically -2147483603)
            if (level <= kCGDesktopWindowLevel) {
                desktopLevel = (CGWindowLevel)level;
            }
            if (level > desktopLevel && level <= kCGDesktopIconWindowLevel) {
                iconLevel = (CGWindowLevel)level;
            }
        }
    }

    CFRelease(windowList);

    // We want to be ABOVE the wallpaper but BELOW the icons.
    // If we found both levels, place ourselves between them.
    if (iconLevel > desktopLevel) {
        return desktopLevel + 1;
    }
    return desktopLevel;
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
@property (nonatomic, assign) BOOL             screenLocked;
@property (nonatomic, assign) CGWindowLevel    desktopLevel;

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
        _paused       = NO;
        _screenLocked = NO;
        _desktopLevel = kCGDesktopWindowLevel;
    }
    return self;
}

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
        displayFrame = [[NSScreen mainScreen] frame];
    }

    NSUInteger styleMask = NSWindowStyleMaskBorderless;
    _window = [[NSWindow alloc] initWithContentRect:displayFrame
                                          styleMask:styleMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];

    // Find the exact level between Finder's wallpaper and desktop icons
    _desktopLevel = findDesktopWindowLevel();
    [_window setLevel:_desktopLevel];

    // Also try using the private CGS API to set the precise level
    CGSConnection cid = _CGSDefaultConnection();
    if (cid) {
        CGSSetWindowLevel(cid, (CGSWindow)[_window windowNumber], _desktopLevel);
    }

    [_window setOpaque:YES];
    [_window setBackgroundColor:[NSColor blackColor]];
    [_window setHasShadow:NO];
    [_window setIgnoresMouseEvents:YES];

    // Critical: these behaviors make the window act like part of the desktop
    [_window setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary      |
                                    NSWindowCollectionBehaviorIgnoresCycle    |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorTransient)];

    // Make the window the full size of the display
    [_window setFrame:displayFrame display:YES];

    // Order it to the front at our level
    [_window orderFront:nil];

    // Observe display configuration changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(displayConfigChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
}

- (void)displayConfigChanged:(NSNotification *)note {
    // Re-fit window to display on configuration changes
    for (NSScreen *screen in [NSScreen screens]) {
        NSDictionary *desc = [screen deviceDescription];
        NSNumber *screenNumber = desc[@"NSScreenNumber"];
        if (screenNumber && (CGDirectDisplayID)[screenNumber unsignedIntValue] == _displayID) {
            [_window setFrame:[screen frame] display:YES];
            _playerLayer.frame = _window.contentView.bounds;
            break;
        }
    }
}

// ---- player ---------------------------------------------------------------

- (void)createPlayer {
    NSURL *fileURL = [NSURL fileURLWithPath:_videoPath];
    AVPlayerItem *templateItem = [AVPlayerItem playerItemWithURL:fileURL];

    _player = [AVQueuePlayer queuePlayerWithItems:@[templateItem]];
    _player.volume = _volume;
    _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;

    _looper = [AVPlayerLooper playerLooperWithPlayer:_player
                                        templateItem:templateItem];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _playerLayer.videoGravity = videoGravityForScaleMode(_scaleMode);
    _playerLayer.frame = _window.contentView.bounds;
    _playerLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;

    [_window.contentView setWantsLayer:YES];
    _window.contentView.layer.backgroundColor = [[NSColor blackColor] CGColor];
    [_window.contentView.layer addSublayer:_playerLayer];

    [_player play];
}

// ---- Darwin notifications -------------------------------------------------

- (void)registerNotifications {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        volumeChangedCallback,
        CFSTR("com.livecanvas.volumeChanged"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        scaleModeChangedCallback,
        CFSTR("com.livecanvas.scaleModeChanged"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        terminateCallback,
        CFSTR("com.livecanvas.terminate"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

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

    // Screen lock / unlock (Darwin notifications from loginwindow)
    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        screenLockedCallback,
        CFSTR("com.apple.screenIsLocked"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        screenUnlockedCallback,
        CFSTR("com.apple.screenIsUnlocked"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    CFRunLoopSourceRef powerSource = IOPSNotificationCreateRunLoopSource(
        powerSourceCallback, (__bridge void *)(self));
    if (powerSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, kCFRunLoopDefaultMode);
        CFRelease(powerSource);
    }
}

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

static void screenLockedCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFNotificationName name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    WallpaperDaemon *daemon = (__bridge WallpaperDaemon *)observer;
    [daemon handleScreenLocked];
}

static void screenUnlockedCallback(CFNotificationCenterRef center,
                                   void *observer,
                                   CFNotificationName name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    WallpaperDaemon *daemon = (__bridge WallpaperDaemon *)observer;
    [daemon handleScreenUnlocked];
}

static void powerSourceCallback(void *context) {
    WallpaperDaemon *daemon = (__bridge WallpaperDaemon *)context;
    [daemon applyPowerPolicy];
}

// ---- screen lock / unlock -------------------------------------------------

- (void)setWindowLevel:(CGWindowLevel)level {
    [_window setLevel:level];
    CGSConnection cid = _CGSDefaultConnection();
    if (cid) {
        CGSSetWindowLevel(cid, (CGSWindow)[_window windowNumber], level);
    }
    [_window orderFront:nil];
}

- (void)handleScreenLocked {
    _screenLocked = YES;

    // Raise the window above the lock screen wallpaper.
    // The lock screen wallpaper sits at kCGDesktopWindowLevel.
    // The login UI (password field) sits at kCGScreenSaverWindowLevel or above.
    // We place ourselves between them so the video plays behind the login UI.
    // kCGScreenSaverWindowLevel - 1 puts us just below the screensaver/login overlay.
    CGWindowLevel lockLevel = kCGScreenSaverWindowLevel - 1;
    [self setWindowLevel:lockLevel];

    // Make sure playback continues
    if (_player.rate == 0.0 && !_paused) {
        [_player play];
        [self applyPowerPolicy];
    }
}

- (void)handleScreenUnlocked {
    _screenLocked = NO;

    // Drop back to the normal desktop level
    _desktopLevel = findDesktopWindowLevel();
    [self setWindowLevel:_desktopLevel];
}

// ---- screen sleep / wake (display off, not lock) -------------------------

- (void)handleScreenSleep:(NSNotification *)note {
    _paused = YES;
    [_player pause];
}

- (void)handleScreenWake:(NSNotification *)note {
    _paused = NO;
    [_player play];
    [self applyPowerPolicy];

    // Re-assert the correct level after wake
    if (_screenLocked) {
        [self setWindowLevel:(kCGScreenSaverWindowLevel - 1)];
    } else {
        _desktopLevel = findDesktopWindowLevel();
        [self setWindowLevel:_desktopLevel];
    }
}

// ---- watchdog: pause when fullscreen app is active, re-level if needed -----

- (void)startWatchdog {
    _watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     target:self
                                                   selector:@selector(watchdogTick:)
                                                   userInfo:nil
                                                    repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_watchdogTimer forMode:NSRunLoopCommonModes];
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

        // Periodically re-assert our window level in case Finder restarted
        // or the desktop was recomposed (only when not locked)
        if (!_screenLocked) {
            CGWindowLevel targetLevel = findDesktopWindowLevel();
            if (_window.level != targetLevel) {
                [self setWindowLevel:targetLevel];
            }
        }
    }
}

// ---- power policy ---------------------------------------------------------

- (void)applyPowerPolicy {
    if (isOnBatteryPower()) {
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];

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
                "Usage: wallpaperdaemon <videoPath> <volume> <scaleMode> <displayID>\n"
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

        if (volume < 0.0f) volume = 0.0f;
        if (volume > 1.0f) volume = 1.0f;

        if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            fprintf(stderr, "Error: video file not found at %s\n", [videoPath UTF8String]);
            return 1;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        WallpaperDaemon *daemon = [[WallpaperDaemon alloc] initWithVideoPath:videoPath
                                                                      volume:volume
                                                                   scaleMode:mode
                                                                   displayID:displayID];
        [daemon start];
        [NSApp run];
    }
    return 0;
}
