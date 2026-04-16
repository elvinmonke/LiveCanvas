/**
 * LiveCanvas Wallpaper Daemon
 *
 * Renders a looping video as the macOS desktop wallpaper.
 * Uses a borderless window with AVPlayerLayer placed between
 * Finder's wallpaper surface and desktop icons via CGS private API.
 *
 * Also sets the actual system wallpaper to a frame from the video
 * so Mission Control and space transitions look correct.
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

@property (nonatomic, copy)   NSString              *videoPath;
@property (nonatomic, copy)   NSString              *frameTempPath;
@property (nonatomic, assign) float                  volume;
@property (nonatomic, assign) LCScaleMode            scaleMode;
@property (nonatomic, assign) CGDirectDisplayID      displayID;
@property (nonatomic, assign) BOOL                   paused;
@property (nonatomic, assign) BOOL                   screenLocked;
@property (nonatomic, assign) CGWindowLevel          desktopLevel;
@property (nonatomic, copy)   NSString              *originalWallpaperPath;
@property (nonatomic, assign) BOOL                   hasSetStaticWallpaper;

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
        _hasSetStaticWallpaper = NO;

        // Temp file for the static wallpaper frame
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

    // Observe active space changes to re-assert window level
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(spaceChanged:)
               name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
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

- (void)spaceChanged:(NSNotification *)note {
    // Re-assert window level after space switch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.paused && !self.screenLocked) {
            self.desktopLevel = findDesktopWindowLevel();
            [self setWindowLevel:self.desktopLevel];
        }
    });
}

// ---- player ---------------------------------------------------------------

- (void)createPlayer {
    NSURL *fileURL = [NSURL fileURLWithPath:_videoPath];
    AVPlayerItem *templateItem = [AVPlayerItem playerItemWithURL:fileURL];

    // Add video output for extracting a static frame
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

    // Extract a frame after a short delay and set it as the actual system wallpaper.
    // This ensures Mission Control / space transitions show a matching image
    // instead of the user's old wallpaper.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self captureAndSetStaticWallpaper];
    });
}

// ---- static wallpaper (for Mission Control / space transitions) -----------

- (void)captureAndSetStaticWallpaper {
    if (!_videoOutput) return;

    CMTime currentTime = [_player currentTime];
    if (![_videoOutput hasNewPixelBufferForItemTime:currentTime]) {
        // Retry shortly
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self captureAndSetStaticWallpaper];
        });
        return;
    }

    CVPixelBufferRef pixelBuffer = [_videoOutput copyPixelBufferForItemTime:currentTime
                                                        itemTimeForDisplay:NULL];
    if (!pixelBuffer) return;

    // Convert to JPEG and write to temp file
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCIImage:ciImage];
    NSData *jpegData = [bitmap representationUsingType:NSBitmapImageFileTypeJPEG
                                            properties:@{NSImageCompressionFactor: @(0.92)}];
    [jpegData writeToFile:_frameTempPath atomically:YES];
    CVPixelBufferRelease(pixelBuffer);

    // Set as the actual system wallpaper for ALL screens
    NSURL *frameURL = [NSURL fileURLWithPath:_frameTempPath];
    NSDictionary *options = @{
        NSWorkspaceDesktopImageScalingKey: @(NSImageScaleProportionallyUpOrDown),
        NSWorkspaceDesktopImageAllowClippingKey: @(YES)
    };

    for (NSScreen *screen in [NSScreen screens]) {
        NSError *error = nil;
        [[NSWorkspace sharedWorkspace] setDesktopImageURL:frameURL
                                                forScreen:screen
                                                  options:options
                                                    error:&error];
    }

    _hasSetStaticWallpaper = YES;
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
    [_player pause];
}

- (void)handleScreenUnlocked {
    _screenLocked = NO;
    [_player play];
    [self applyPowerPolicy];

    _desktopLevel = findDesktopWindowLevel();
    [self setWindowLevel:_desktopLevel];
}

// ---- sleep / wake ---------------------------------------------------------

- (void)handleScreenSleep:(NSNotification *)note {
    _paused = YES;
    [_player pause];
}

- (void)handleScreenWake:(NSNotification *)note {
    _paused = NO;
    if (!_screenLocked) {
        [_player play];
        [self applyPowerPolicy];
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
    if (_paused || _screenLocked) return;

    if (isFullscreenAppActive()) {
        if (_player.rate != 0.0) [_player pause];
    } else {
        if (_player.rate == 0.0) {
            [_player play];
            [self applyPowerPolicy];
        }
        CGWindowLevel targetLevel = findDesktopWindowLevel();
        if (_window.level != targetLevel) {
            [self setWindowLevel:targetLevel];
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

    // Restore original wallpaper on all screens
    if (_originalWallpaperPath) {
        NSURL *origURL = [NSURL fileURLWithPath:_originalWallpaperPath];
        for (NSScreen *screen in [NSScreen screens]) {
            [[NSWorkspace sharedWorkspace] setDesktopImageURL:origURL
                                                   forScreen:screen
                                                     options:@{} error:nil];
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
