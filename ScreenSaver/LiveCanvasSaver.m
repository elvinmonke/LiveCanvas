/**
 * LiveCanvas Screen Saver
 *
 * A .saver bundle that plays the user's chosen video wallpaper.
 * On macOS Sonoma+, the lock screen displays the active screen saver,
 * so this gives us animated wallpaper on the lock screen.
 *
 * Reads the video path from the shared UserDefaults suite
 * "com.elvin.livecanvas" (key: "lc_activeVideoPath").
 */

#import <ScreenSaver/ScreenSaver.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

@interface LiveCanvasView : ScreenSaverView

@property (nonatomic, strong) AVQueuePlayer    *player;
@property (nonatomic, strong) AVPlayerLooper   *looper;
@property (nonatomic, strong) AVPlayerLayer    *playerLayer;
@property (nonatomic, copy)   NSString         *videoPath;

@end

@implementation LiveCanvasView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1.0 / 30.0];
        [self setWantsLayer:YES];
        self.layer.backgroundColor = [[NSColor blackColor] CGColor];

        [self loadVideoPath];
        if (_videoPath) {
            [self setupPlayer];
        }
    }
    return self;
}

- (void)loadVideoPath {
    // Try shared defaults suite first (written by the daemon/app)
    NSUserDefaults *shared = [[NSUserDefaults alloc]
        initWithSuiteName:@"com.elvin.livecanvas"];
    NSString *path = [shared stringForKey:@"lc_activeVideoPath"];

    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // Fallback: check standard defaults
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        path = [std stringForKey:@"lc_activeVideoPath"];
    }

    if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        _videoPath = path;
    }
}

- (void)setupPlayer {
    NSURL *fileURL = [NSURL fileURLWithPath:_videoPath];
    AVPlayerItem *templateItem = [AVPlayerItem playerItemWithURL:fileURL];

    _player = [AVQueuePlayer queuePlayerWithItems:@[templateItem]];
    _player.volume = 0.0;  // Screen savers should be silent
    _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;

    _looper = [AVPlayerLooper playerLooperWithPlayer:_player
                                        templateItem:templateItem];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _playerLayer.frame = self.bounds;
    _playerLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;

    [self.layer addSublayer:_playerLayer];
}

+ (BOOL)performGammaFade {
    return NO;  // Instant transition, no fade
}

- (void)startAnimation {
    [super startAnimation];
    _playerLayer.frame = self.bounds;
    [_player play];
}

- (void)stopAnimation {
    [_player pause];
    [super stopAnimation];
}

- (void)animateOneFrame {
    // AVPlayer handles animation; nothing needed here
}

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize {
    [super resizeWithOldSuperviewSize:oldSize];
    _playerLayer.frame = self.bounds;
}

- (BOOL)hasConfigureSheet {
    return NO;
}

- (NSWindow *)configureSheet {
    return nil;
}

- (void)dealloc {
    [_player pause];
    [_playerLayer removeFromSuperlayer];
}

@end
