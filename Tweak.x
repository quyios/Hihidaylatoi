#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// State key prefixes
static NSString * const kRotationIndexKey = @"ADMRotationIndex_";
static NSString * const kLastPathKey     = @"ADMLastPath_";

// Core rotation logic - shared by both hook implementations
static void performRotationWithOriginal(id self_obj, SEL _cmd, NSString *bundleID, NSString *originalPath, id progress, id completion, void (^callOriginal)(NSString *)) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = @"/var/mobile/Library/ADManager";

        NSError *err = nil;
        NSArray *all = [fm contentsOfDirectoryAtPath:dir error:&err];
        if (err || !all) {
            NSLog(@"[ADMRotation] Cannot read dir: %@", err);
            callOriginal(originalPath);
            return;
        }

        NSString *prefix = [bundleID stringByAppendingString:@"_"];
        NSMutableArray<NSString *> *backups = [NSMutableArray array];
        for (NSString *f in all) {
            if ([f hasPrefix:prefix] && [f hasSuffix:@".adbk"]) {
                [backups addObject:[dir stringByAppendingPathComponent:f]];
            }
        }

        [backups sortUsingSelector:@selector(compare:)];
        NSLog(@"[ADMRotation] Found %lu backups for %@", (unsigned long)backups.count, bundleID);

        if (backups.count <= 1) {
            callOriginal(originalPath);
            return;
        }

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *lastPathKey  = [kLastPathKey stringByAppendingString:bundleID];
        NSString *indexKey     = [kRotationIndexKey stringByAppendingString:bundleID];
        NSString *lastPath     = [ud stringForKey:lastPathKey];

        NSInteger idx = [ud integerForKey:indexKey];

        // Reset if user selected a different backup manually
        if (lastPath && ![originalPath isEqualToString:lastPath]) {
            NSUInteger found = [backups indexOfObject:originalPath];
            idx = (found != NSNotFound) ? (NSInteger)((found + 1) % backups.count) : 0;
            NSLog(@"[ADMRotation] Manual change detected, resetting rotation to idx %ld", (long)idx);
        }

        // Clamp index just in case array shrank
        if (idx >= (NSInteger)backups.count) idx = 0;

        NSString *chosenPath = backups[idx];
        NSLog(@"[ADMRotation] Rotating to idx=%ld path=%@", (long)idx, chosenPath);

        // Save state
        [ud setObject:chosenPath forKey:lastPathKey];
        [ud setInteger:(idx + 1) % backups.count forKey:indexKey];
        [ud synchronize];

        callOriginal(chosenPath);

    } @catch (NSException *e) {
        NSLog(@"[ADMRotation] Exception: %@", e);
        callOriginal(originalPath);
    }
}

// --- Hook group for BackupList (model class, preferred) ---
%group HookBackupList

%hook BackupList

- (void)restoreApp:(NSString *)bundleID fromPathBackup:(NSString *)path progress:(id)progress withCompletion:(id)completion {
    NSLog(@"[ADMRotation] BackupList hook triggered");
    performRotationWithOriginal(self, _cmd, bundleID, path, progress, completion, ^(NSString *resolved) {
        %orig(bundleID, resolved, progress, completion);
    });
}

%end

%end // HookBackupList


// --- Fallback: Hook the UI view controller if BackupList hook doesn't fire ---
%group HookBackupInfoVC

%hook BackupInfoTableViewController

- (void)restoreApp:(NSString *)bundleID fromPathBackup:(NSString *)path progress:(id)progress withCompletion:(id)completion {
    NSLog(@"[ADMRotation] BackupInfoTableViewController hook triggered");
    performRotationWithOriginal(self, _cmd, bundleID, path, progress, completion, ^(NSString *resolved) {
        %orig(bundleID, resolved, progress, completion);
    });
}

%end

%end // HookBackupInfoVC


// --- Constructor: safe, lazy initialization ---
%ctor {
    @autoreleasepool {
        NSLog(@"[ADMRotation] Dylib loaded into process: %@", NSProcessInfo.processInfo.processName);

        BOOL hooked = NO;

        Class cls = NSClassFromString(@"BackupList");
        if (cls) {
            NSLog(@"[ADMRotation] Found BackupList - activating primary hook");
            %init(HookBackupList, BackupList = cls);
            hooked = YES;
        }

        Class cls2 = NSClassFromString(@"BackupInfoTableViewController");
        if (cls2) {
            NSLog(@"[ADMRotation] Found BackupInfoTableViewController - activating fallback hook");
            %init(HookBackupInfoVC, BackupInfoTableViewController = cls2);
            hooked = YES;
        }

        if (!hooked) {
            NSLog(@"[ADMRotation] WARNING: Neither target class found. No hooks applied.");
        }
    }
}

