/**
 * LiveCanvas Wallpaper Daemon
 *
 * Renders a looping video as the macOS desktop wallpaper using two strategies:
 *
 *   Desktop (unlocked): Window-level approach — GPU-accelerated AVPlayerLayer
 *     placed between Finder's wallpaper surface and desktop icons.
 *
 *   Lock screen: Frame-extraction approach — pulls frames from AVPlayer via
 *     AVPlayerItemVideoOutput, writes to temp file, and sets the actual system
 *     wallpaper via NSWorkspace. The lock screen mirrors the desktop wallpaper.
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
    if (!sources) { CFRelease(info); return NO; }

    BOOL onBattery = NO;
    CFIndex count = CFArrayGetCount(sources);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(info,
                                   CFArrayGetValueAtIndex(sources, i));
        if (!desc) continue;
        CFStringRef type = CFDictionaryGetValue(desc, CFSTR(kIOPSTransportTypeKey));
        CFStringRef state = CFDictionaryGetValue(desc, CFSTR(kIOPSPowerSourceStateKey));
        if (type && CFStringCompare(type, CFSTR(kIOPSInternalType), 0) == kCFCompareEqualTo &&
            state && CFStringCompare(state, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo) {
            onBattery = YES;
        }
    }
    CFRelease(sources);
    CFRelease(info);
    return onBattery;
}

// ---------------------------------------------------------------------------
#pragma mark - Find Finder desktop window level
// ---------------------------------------------------------------------------

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
            if (level <= kCGDesktopWindowLevel) {
                desktopLevel = (CGWindowLevel)level;
            }
            if (level > desktopLevel && level <= kCGDesktopIconWindowLevel) {
                iconLevel = (CGWindowLevel)level;
            }
        }
    }
    CFRelease(windowList);

    if (iconLevel > desktopLevel) return desktopLevel + 1;
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
                if (CGRectEqualToRect(bounds, screenFrame)) { found = YES; break; }
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

@property (nonatomic, strong) NSWindow              *window;
@property (nonatomic, strong) AVQueuePlayer         *player;
@property (nonatomic, strong) AVPlayerLooper        *looper;
@property (nonatomic, strong) AVPlayerLayer         *playerLayer;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) NSTimer               *watchdogTimer;
@property (nonatomic, strong) NSTimer               *frameTimer;

@property (nonatomic, copy)   NSString              *videoPath;
@property (nonatomic, copy)   NSString              *frameTempPath;
@property (nonatomic, assign) float                  volume;
@property (nonatomic, assign) LCScaleMode            scaleMode;
@property (nonatomic, assign) CGDirectDisplayID      displayID;
@property (nonatomic, assign) BOOL                   paused;
@property (nonatomic, assign) BOOL                   screenLocked;
@property (nonatomic, assign) CGWindowLevel          desktopLevel;
@property (nonatomic, copy)   NSString              *originalWallpaperPath;

- (instancetype)initWithVideoPath:(NSString *)path
                           volume:(float)volume
                        scaleMode:(LCScaleMode)mode
                        displayID:(CGDirectDisplayID)displayID;
- (void)start;

@end

@implementation WallpaperDaemon

- (instancetype)initWithVideoPath:(NSString *)path
                           volume:(float)vol
                        scaleMode:(LCScaleMode)mode
                        displayID:(CGDirectDisplayID)dID {
    self = [super init];
    if (self) {
        _videoPath      = [path copy];
        _volume         = vol;
        _scaleMode      = mode;
        _displayID      = dID;
        _paused         = NO;
        _screenLocked   = NO;
        _desktopLevel   = kCGDesktopWindowLevel;

        // Temp file for frame extraction (in RAM-backed tmp)
        NSString *tmpDir = NSTemporaryDirectory();
        _frameTempPath = [tmpDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"livecanvas_frame_%u.jpg", dID]];

        // Save original wallpaper so we can restore on exit
        [self saveOriginalWallpaper];
    }
    return self;
}

- (void)saveOriginalWallpaper {
    for (NSScreen *screen in [NSScreen screens]) {
        NSDictionary *desc = [screen deviceDescription];
        NSNumber *screenNumber = desc[@"NSScreenNumber"];
        if (screenNumber && (CGDirectDisplayID)[screenNumber unsignedIntValue] == _displayID) {
            NSURL *url = [[NSWorkspace sharedWorkspace] desktopImageURLForScreen:screen];
            if (url) {
                _originalWallpaperPath = [url path];
            }
            break;
        }
    }
}

- (void)start {
    [self createWindow];
    [self createPlayer];
    [self registerNotifications];
    [self startWatchdog];
    [self applyPowerPolicy];
}

// ---- window ---------------------------------------------------------------

- (void)setWindowLevel:(CGWindowLevel)level {
    [_window setLevel:level];
    CGSConnection cid = _CGSDefaultConnection();
    if (cid) {
        CGSSetWindowLevel(cid, (CGSWindow)[_window windowNumber], level);
    }
    [_window orderFront:nil];
}

- (void)createWindow {
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

    _window = [[NSWindow alloc] initWithContentRect:displayFrame
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO];

    _desktopLevel = findDesktopWindowLevel();
    [self setWindowLevel:_desktopLevel];

    [_window setOpaque:YES];
    [_window setBackgroundColor:[NSColor blackColor]];
    [_window setHasShadow:NO];
    [_window setIgnoresMouseEvents:YES];
    [_window setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary      |
                                    NSWindowCollectionBehaviorIgnoresCycle    |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorTransient)];
    [_window setFrame:displayFrame display:YES];
    [_window orderFront:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(displayConfigChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
}

- (void)displayConfigChanged:(NSNotification *)note {
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

    // Add video output for frame extraction (used during lock screen)
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
    [templateItem addOutput:_videoOutput];

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

// ---- frame extraction (for lock screen wallpaper) -------------------------

- (void)startFrameExtraction {
    if (_frameTimer) return;

    // Extract frames at ~15fps and set as actual system wallpaper
    _frameTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 15.0)
                                                   target:self
                                                 selector:@selector(extractAndSetFrame:)
                                                 userInfo:nil
                                                  repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_frameTimer forMode:NSRunLoopCommonModes];
}

- (void)stopFrameExtraction {
    [_frameTimer invalidate];
    _frameTimer = nil;
}

- (void)extractAndSetFrame:(NSTimer *)timer {
    if (!_videoOutput || _paused) return;

    CMTime currentTime = [_player currentTime];
    if (![_videoOutput hasNewPixelBufferForItemTime:currentTime]) return;

    CVPixelBufferRef pixelBuffer = [_videoOutput copyPixelBufferForItemTime:currentTime
                                                        itemTimeForDisplay:NULL];
    if (!pixelBuffer) return;

    // Convert pixel buffer to NSImage
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:ciImage];
    NSImage *image = [[NSImage alloc] initWithSize:rep.size];
    [image addRepresentation:rep];

    // Write to temp file as JPEG (fast, small)
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithCIImage:ciImage];
    NSData *jpegData = [bitmap representationUsingType:NSBitmapImageFileTypeJPEG
                                            properties:@{NSImageCompressionFactor: @(0.85)}];
    [jpegData writeToFile:_frameTempPath atomically:YES];

    CVPixelBufferRelease(pixelBuffer);

    // Set as actual system wallpaper
    NSURL *frameURL = [NSURL fileURLWithPath:_frameTempPath];
    for (NSScreen *screen in [NSScreen screens]) {
        NSDictionary *desc = [screen deviceDescription];
        NSNumber *screenNumber = desc[@"NSScreenNumber"];
        if (screenNumber && (CGDirectDisplayID)[screenNumber unsignedIntValue] == _displayID) {
            NSError *error = nil;
            [[NSWorkspace sharedWorkspace] setDesktopImageURL:frameURL
                                                   forScreen:screen
                                                     options:@{
                                                         NSWorkspaceDesktopImageScalingKey: @(NSImageScaleProportionallyUpOrDown),
                                                         NSWorkspaceDesktopImageAllowClippingKey: @(YES)
                                                     }
                                                       error:&error];
            break;
        }
    }
}

// ---- Darwin notifications -------------------------------------------------

- (void)registerNotifications {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        volumeChangedCallback, CFSTR("com.livecanvas.volumeChanged"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        scaleModeChangedCallback, CFSTR("com.livecanvas.scaleModeChanged"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        terminateCallback, CFSTR("com.livecanvas.terminate"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    // Screen lock / unlock
    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        screenLockedCallback, CFSTR("com.apple.screenIsLocked"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(
        center, (__bridge const void *)(self),
        screenUnlockedCallback, CFSTR("com.apple.screenIsUnlocked"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    // Display sleep / wake
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(handleScreenSleep:)
               name:NSWorkspaceScreensDidSleepNotification object:nil];

    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(handleScreenWake:)
               name:NSWorkspaceScreensDidWakeNotification object:nil];

    CFRunLoopSourceRef powerSource = IOPSNotificationCreateRunLoopSource(
        powerSourceCallback, (__bridge void *)(self));
    if (powerSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, kCFRunLoopDefaultMode);
        CFRelease(powerSource);
    }
}

// ---- C callbacks ----------------------------------------------------------

static void volumeChangedCallback(CFNotificationCenterRef c, void *obs,
    CFNotificationName n, const void *o, CFDictionaryRef ui) {
    WallpaperDaemon *d = (__bridge WallpaperDaemon *)obs;
    NSUserDefaults *def = [[NSUserDefaults alloc] initWithSuiteName:@"com.elvin.livecanvas"];
    d.volume = [def floatForKey:@"lc_volume"];
    d.player.volume = d.volume;
}

static void scaleModeChangedCallback(CFNotificationCenterRef c, void *obs,
    CFNotificationName n, const void *o, CFDictionaryRef ui) {
    WallpaperDaemon *d = (__bridge WallpaperDaemon *)obs;
    NSUserDefaults *def = [[NSUserDefaults alloc] initWithSuiteName:@"com.elvin.livecanvas"];
    d.scaleMode = (LCScaleMode)[def integerForKey:@"lc_scaleMode"];
    d.playerLayer.videoGravity = videoGravityForScaleMode(d.scaleMode);
}

static void terminateCallback(CFNotificationCenterRef c, void *obs,
    CFNotificationName n, const void *o, CFDictionaryRef ui) {
    [(__bridge WallpaperDaemon *)obs shutdown];
}

static void screenLockedCallback(CFNotificationCenterRef c, void *obs,
    CFNotificationName n, const void *o, CFDictionaryRef ui) {
    [(__bridge WallpaperDaemon *)obs handleScreenLocked];
}

static void screenUnlockedCallback(CFNotificationCenterRef c, void *obs,
    CFNotificationName n, const void *o, CFDictionaryRef ui) {
    [(__bridge WallpaperDaemon *)obs handleScreenUnlocked];
}

static void powerSourceCallback(void *ctx) {
    [(__bridge WallpaperDaemon *)ctx applyPowerPolicy];
}

// ---- lock / unlock --------------------------------------------------------

- (void)handleScreenLocked {
    _screenLocked = YES;

    // Switch to frame-extraction mode: pull frames from the video and set them
    // as the actual system wallpaper. The lock screen mirrors the desktop
    // wallpaper, so this makes the video animate on the lock screen.
    [self startFrameExtraction];
}

- (void)handleScreenUnlocked {
    _screenLocked = NO;

    // Stop frame extraction — go back to the GPU-accelerated window approach
    [self stopFrameExtraction];

    // Re-assert the desktop window level
    _desktopLevel = findDesktopWindowLevel();
    [self setWindowLevel:_desktopLevel];
}

// ---- sleep / wake ---------------------------------------------------------

- (void)handleScreenSleep:(NSNotification *)note {
    _paused = YES;
    [_player pause];
    [self stopFrameExtraction];
}

- (void)handleScreenWake:(NSNotification *)note {
    _paused = NO;
    [_player play];
    [self applyPowerPolicy];

    if (_screenLocked) {
        [self startFrameExtraction];
    } else {
        _desktopLevel = findDesktopWindowLevel();
        [self setWindowLevel:_desktopLevel];
    }
}

// ---- watchdog -------------------------------------------------------------

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
        if (_player.rate != 0.0) [_player pause];
    } else {
        if (_player.rate == 0.0) {
            [_player play];
            [self applyPowerPolicy];
        }
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
    _player.rate = isOnBatteryPower() ? 0.5 : 1.0;
}

// ---- shutdown -------------------------------------------------------------

- (void)shutdown {
    [_watchdogTimer invalidate]; _watchdogTimer = nil;
    [self stopFrameExtraction];

    // Restore original wallpaper
    if (_originalWallpaperPath) {
        NSURL *origURL = [NSURL fileURLWithPath:_originalWallpaperPath];
        for (NSScreen *screen in [NSScreen screens]) {
            NSDictionary *desc = [screen deviceDescription];
            NSNumber *sn = desc[@"NSScreenNumber"];
            if (sn && (CGDirectDisplayID)[sn unsignedIntValue] == _displayID) {
                [[NSWorkspace sharedWorkspace] setDesktopImageURL:origURL
                                                       forScreen:screen
                                                         options:@{} error:nil];
                break;
            }
        }
    }

    // Clean up temp frame file
    [[NSFileManager defaultManager] removeItemAtPath:_frameTempPath error:nil];

    CFNotificationCenterRemoveEveryObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self));
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_player pause]; _player = nil; _looper = nil;
    [_playerLayer removeFromSuperlayer]; _playerLayer = nil;
    [_window orderOut:nil]; _window = nil;

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
                "Usage: wallpaperdaemon <videoPath> <volume> <scaleMode> <displayID>\n");
            return 1;
        }

        NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
        float volume = fminf(fmaxf((float)atof(argv[2]), 0.0f), 1.0f);
        LCScaleMode mode = (LCScaleMode)atoi(argv[3]);
        CGDirectDisplayID displayID = (CGDirectDisplayID)atoi(argv[4]);

        if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            fprintf(stderr, "Error: video file not found at %s\n", [videoPath UTF8String]);
            return 1;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        WallpaperDaemon *daemon = [[WallpaperDaemon alloc]
            initWithVideoPath:videoPath volume:volume scaleMode:mode displayID:displayID];
        [daemon start];
        [NSApp run];
    }
    return 0;
}
