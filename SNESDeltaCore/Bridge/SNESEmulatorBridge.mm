//
//  SNESEmulatorBridge.m
//  SNESDeltaCore
//
//  Created by Riley Testut on 9/12/15.
//  Copyright © 2015 Riley Testut. All rights reserved.
//

#import "SNESEmulatorBridge.h"

// Snes9x
#include "snes9x.h"
#include "apu.h"
#include "snapshot.h"
#include "snes9x/memmap.h"
#include "controls.h"
#include "display.h"
#include "snes9x/cheats.h"
#include "fscompat.h"
#include "conffile.h"

#include <string>

// System
#include <sys/time.h>

// DeltaCore
#import <SNESDeltaCore/SNESDeltaCore.h>
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>

#if STATIC_LIBRARY
#import "SNESDeltaCore-Swift.h"
#else
#import <SNESDeltaCore/SNESDeltaCore-Swift.h>
#endif

class ConfigFile;

// snes9x owns its screen (GFX.ScreenBuffer: 512 px wide, MAX_SNES_HEIGHT rows, GFX.Pitch bytes per row) and
// writes up to SNES_HEIGHT_EXTENDED (239) rows, on overscan/PAL frames and on every save-state load.
// DeltaCore's video buffer is only 256x224, so each frame's visible rows are copied across.
// Never point GFX.Screen at the video buffer directly (Crashlytics eb6827db).
static const size_t SNESVisibleWidth = 256;  // Must match SNES.videoFormat.dimensions.
static const size_t SNESVisibleHeight = 224;

@interface SNESEmulatorBridge () <DLTAEmulatorBridging>

@property (nonatomic, copy, nullable, readwrite) NSURL *gameURL;

// YES only between a successful startWithGameURL: and stop. EmulatorCore keeps driving the bridge
// (frames, saves, save states) even when the ROM failed to load.
@property (atomic, assign, getter=isGameLoaded) BOOL gameLoaded;

@end

void SNESFinalizeSamplesCallback(void *context);

@implementation SNESEmulatorBridge
@synthesize gameURL = _gameURL;
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;

+ (instancetype)sharedBridge
{
    static SNESEmulatorBridge *_emulatorBridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _emulatorBridge = [[self alloc] init];
    });
    
    return _emulatorBridge;
}

#pragma mark - Emulation -

- (void)startWithGameURL:(NSURL *)URL
{
    [self stop];
    
    self.gameURL = URL;
    
    memset(&Settings, 0, sizeof(Settings));
    Settings.MouseMaster = YES;
    Settings.SuperScopeMaster = YES;
    Settings.JustifierMaster = YES;
    Settings.MultiPlayer5Master = YES;
    Settings.FrameTimePAL = 20000;
    Settings.FrameTimeNTSC = 16667;
    Settings.SixteenBitSound = YES;
    Settings.Stereo = YES;
    Settings.SoundPlaybackRate = 32040;
    Settings.SoundInputRate = 32040;
    Settings.Transparency = YES;
    Settings.AutoDisplayMessages = YES;
    Settings.InitialInfoStringTimeout = 120;
    Settings.HDMATimingHack = 100;
    Settings.BlockInvalidVRAMAccessMaster = YES;
    Settings.StopEmulation = YES;
    Settings.WrongMovieStateProtection = YES;
    Settings.DumpStreamsMaxFrames = -1;
    Settings.StretchScreenshots = 1;
    Settings.SnapshotScreenshots = YES;
    Settings.SkipFrames = AUTO_FRAMERATE;
    Settings.TurboSkipFrames = 4;
    Settings.CartAName[0] = 0;
    Settings.CartBName[0] = 0;
    Settings.AutoSaveDelay = 1;
    // Required by snes9x 1.56+; these are the stock values every frontend sets.
    Settings.SuperFXClockMultiplier = 100;
    Settings.InterpolationMethod = DSP_INTERPOLATION_GAUSSIAN;
    Settings.MaxSpriteTilesPerLine = 34;
    Settings.OneClockCycle = 6;
    Settings.OneSlowClockCycle = 8;
    Settings.TwoClockCycles = 12;
    Settings.DynamicRateLimit = 5;
    
    S9xSetSoundMute(YES);
    
    CPU.Flags = 0;
    
    if (!Memory.Init() || !S9xInitAPU())
    {
        fprintf(stderr, "Snes9x: Memory allocation failure - not enough RAM/virtual memory available.\nExiting...\n");
        Memory.Deinit();
        S9xDeinitAPU();
        return;
    }
    
    int milliseconds = 16;
    S9xInitSound(milliseconds);
    
    S9xUnmapAllControls();
    S9xSetController(0, CTL_JOYPAD, 0, 0, 0, 0);
    S9xSetController(1, CTL_JOYPAD, 1, 0, 0, 0);
    
    for (int player = 1; player <= 8; player++)
    {
        NSUInteger mask = player << 16;
        
        void (^mapInput)(uint32_t, NSString *) = ^(uint32_t input, NSString *inputName) {
            NSString *command = [NSString stringWithFormat:@"Joypad%d %@", player, inputName];
            S9xMapButton((uint32)(mask | input), S9xGetCommandT(command.UTF8String), NO);
        };
        
        mapInput(SNESGameInputUp, @"Up");
        mapInput(SNESGameInputDown, @"Down");
        mapInput(SNESGameInputLeft, @"Left");
        mapInput(SNESGameInputRight, @"Right");
        mapInput(SNESGameInputA, @"A");
        mapInput(SNESGameInputB, @"B");
        mapInput(SNESGameInputX, @"X");
        mapInput(SNESGameInputY, @"Y");
        mapInput(SNESGameInputL, @"L");
        mapInput(SNESGameInputR, @"R");
        mapInput(SNESGameInputStart, @"Start");
        mapInput(SNESGameInputSelect, @"Select");
    }
    
    S9xReportControllers();
    
    if (!Memory.LoadROM(URL.path.fileSystemRepresentation))
    {
        // Leave gameLoaded NO: every other bridge call then no-ops instead of running a core with no cart.
        fprintf(stderr, "Error opening the ROM file.\n");
        return;
    }
    
    Settings.StopEmulation = NO;
    
    S9xGraphicsInit();
    
    snprintf(String, 513, "\"%s\" %s: %s", Memory.ROMName, TITLE, VERSION);
    
    S9xSetSoundMute(NO);
    
    S9xSetSamplesAvailableCallback(SNESFinalizeSamplesCallback, NULL);
    
    self.gameLoaded = YES;
}

- (void)stop
{
    self.gameLoaded = NO;
    
    S9xGraphicsDeinit();
    Memory.Deinit();
    S9xDeinitAPU();
    
    Settings.Paused = YES;
}

- (void)pause
{
    S9xSetSoundMute(YES);
    
    Settings.Paused = YES;
}

- (void)resume
{
    S9xSetSoundMute(NO);
    
    Settings.Paused = NO;
}

#pragma mark - Game Loop -

- (void)runFrameAndProcessVideo:(BOOL)processVideo
{
    if (![self isGameLoaded])
    {
        return;
    }
    
    S9xMainLoop();
    
    if (processVideo)
    {
        uint8_t *videoBuffer = self.videoRenderer.videoBuffer;
        if (videoBuffer != NULL && GFX.Screen != NULL)
        {
            const size_t rowSize = SNESVisibleWidth * sizeof(uint16);
            const uint8_t *source = (const uint8_t *)GFX.Screen;
            
            for (size_t row = 0; row < SNESVisibleHeight; row++)
            {
                memcpy(videoBuffer + row * rowSize, source + row * GFX.Pitch, rowSize);
            }
        }
        
        [self.videoRenderer processFrame];
    }
}

- (nullable NSData *)readMemoryAtAddress:(NSInteger)address size:(NSInteger)size
{
    if (![self isGameLoaded] || Memory.RAM == NULL)
    {
        return nil;
    }
    
    if (address + size > 0x20000)
    {
        // Beyond RAM bounds, return nil.
        return nil;
    }
    
    void *bytes = (Memory.RAM + address);
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:NO];
    return data;
}

#pragma mark - Inputs -

- (void)activateInput:(NSInteger)gameInput value:(double)value playerIndex:(NSInteger)playerIndex
{
    NSUInteger mask = (playerIndex + 1) << 16;
    S9xReportButton((uint32)(mask | gameInput), YES);
}

- (void)deactivateInput:(NSInteger)gameInput playerIndex:(NSInteger)playerIndex
{
    NSUInteger mask = (playerIndex + 1) << 16;
    S9xReportButton((uint32)(mask | gameInput), NO);
}

- (void)resetInputs
{
    for (int playerIndex = 0; playerIndex < 8; playerIndex++)
    {
        [self deactivateInput:SNESGameInputUp playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputDown playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputLeft playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputRight playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputA playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputB playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputX playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputY playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputL playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputR playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputStart playerIndex:playerIndex];
        [self deactivateInput:SNESGameInputSelect playerIndex:playerIndex];
    }
}

#pragma mark - Audio -

- (void)renderAudioSamples
{
    int sampleCount = MIN((int)self.audioRenderer.audioBuffer.availableBytesForWriting / 2, S9xGetSampleCount());
    
    if (sampleCount <= 0)
    {
        return;
    }
    
    void *buffer = malloc(sampleCount * 2); // Audio is interleaved, so we multiply by two to account for both channels
    S9xMixSamples((uint8 *)buffer, sampleCount);
    
    [self.audioRenderer.audioBuffer writeBuffer:(uint8_t *)buffer size:sampleCount * 2];
    
    free(buffer);
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    if (![self isGameLoaded])
    {
        return;
    }
    
    S9xFreezeGame(URL.path.fileSystemRepresentation);
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    if (![self isGameLoaded])
    {
        return;
    }
    
    S9xUnfreezeGame(URL.path.fileSystemRepresentation);
}

#pragma mark - Cheats -

- (BOOL)addCheatCode:(NSString *)cheatCode type:(NSString *)type
{
    if (![type isEqualToString:CheatTypeGameGenie] && ![type isEqualToString:CheatTypeActionReplay])
    {
        return NO;
    }
    
    // snes9x parses the code text itself (Game Genie "XXXX-XXXX", Pro Action Replay "AAAAAAVV") and
    // takes several codes joined with "+" as one group. Validate each line first so a bad line
    // doesn't leave half a cheat enabled.
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    for (NSString *line in [cheatCode componentsSeparatedByString:@"\n"])
    {
        NSString *code = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (code.length == 0)
        {
            continue;
        }
        
        if (S9xCheatValidate(code.UTF8String).empty())
        {
            return NO;
        }
        
        [codes addObject:code];
    }
    
    if (codes.count == 0)
    {
        return NO;
    }
    
    int index = S9xAddCheatGroup("", [codes componentsJoinedByString:@"+"].UTF8String);
    if (index < 0)
    {
        return NO;
    }
    
    S9xEnableCheatGroup((uint32_t)index);
    
    return YES;
}

- (void)resetCheats
{
    S9xDeleteCheats();
}

- (void)updateCheats
{
    Settings.ApplyCheats = true;
    S9xCheatsEnable();
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)URL
{
    if (![self isGameLoaded])
    {
        return;
    }
    
    Memory.SaveSRAM(URL.path.fileSystemRepresentation);
    sync();
}

- (void)loadGameSaveFromURL:(NSURL *)URL
{
    if (![self isGameLoaded])
    {
        return;
    }
    
    Memory.LoadSRAM(URL.path.fileSystemRepresentation);
}

#pragma mark - Getters/Setters -

- (NSTimeInterval)frameDuration
{
    NSTimeInterval frameDuration = Settings.PAL ? (1.0 / 50.0) : (1.0 / 60.0);
    return frameDuration;
}

@end

#pragma mark - SNESEmulatorBridge Callbacks -

void SNESFinalizeSamplesCallback(void *context)
{
    [[SNESEmulatorBridge sharedBridge] renderAudioSamples];
}

#pragma mark - Snes9x Callbacks -

void S9xSyncSpeed()
{
}

bool8 S9xOpenSnapshotFile(const char *fname, bool8 read_only, STREAM *file)
{
    if (read_only)
    {
        if (0 != (*file = OPEN_STREAM(fname, "rb")))
        {
            return YES;
        }
        
    }
    else
    {
        if (0 != (*file = OPEN_STREAM(fname, "wb")))
        {
            return YES;
        }
    }
    
    return NO;
}

void S9xCloseSnapshotFile(STREAM file)
{
    CLOSE_STREAM(file);
}

void S9xToggleSoundChannel(int c)
{
    static int sound_switch = 255;
    
    if (c == 8)
    {
        sound_switch = 255;
    }
    else
    {
        sound_switch ^= 1 << c;
    }
    
    S9xSetSoundControl (sound_switch);
}

bool S9xPollPointer(uint32 identifier, int16 *x, int16 *y)
{
    *x = 0;
    *y = 0;
    
    return YES;
}

void S9xMessage(int type, int number, const char *message)
{
    printf("%s\n", message);
}

std::string S9xGetDirectory(enum s9x_getdirtype dirtype)
{
    NSURL *directoryURL = [[[SNESEmulatorBridge sharedBridge] gameURL] URLByDeletingLastPathComponent];
    const char *path = directoryURL.path.fileSystemRepresentation;
    return path ? std::string(path) : std::string();
}

void S9xAutoSaveSRAM()
{
    void (^saveUpdateHandler)(void) = [SNESEmulatorBridge sharedBridge].saveUpdateHandler;
    if (saveUpdateHandler != nil)
    {
        saveUpdateHandler();
    }
}

bool8 S9xDeinitUpdate(int width, int height)
{    
    return YES;
}

std::string S9xGetFilenameInc(std::string extension, enum s9x_getdirtype dirtype)
{
    return std::string();
}

const char *S9xStringInput(const char* s)
{
    return NULL;
}

bool8 S9xOpenSoundDevice()
{
    return YES;
}

bool8 S9xInitUpdate()
{
    return YES;
}

bool8 S9xContinueUpdate(int width, int height)
{
    return YES;
}

bool S9xPollButton(uint32 identifier, bool *pressed)
{
    return YES;
}

bool S9xPollAxis(uint32 id, int16* value)
{
    return NO;
}

void S9xHandlePortCommand(s9xcommand_t cmd, int16 data1, int16 data2)
{

}

void S9xParsePortConfig(ConfigFile &a, int pass)
{
    
}

void S9xParseArg(char** a, int &b, int c)
{
    
}

void S9xExtraUsage()
{
    
}

void S9xExit()
{
    
}
