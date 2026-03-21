#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// State constants
static NSString *const kRotationManualChoicePrefix = @"ManualChoice_";
static NSString *const kRotationIndexPrefix = @"RotationIndex_";

@interface BackupList : NSObject
- (void)restoreApp:(NSString *)bundleID fromPathBackup:(NSString *)path progress:(id)progress withCompletion:(id)completion;
@end

%group RotationHook

%hook BackupList

- (void)restoreApp:(NSString *)bundleID fromPathBackup:(NSString *)path progress:(id)progress withCompletion:(id)completion {
    
    @try {
        NSLog(@"[ADManager Rotation] Intercepted restoreApp for: %@", bundleID);
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *backupDir = @"/var/mobile/Library/ADManager";
        
        // 1. Find all available .adbk files for this bundleID
        NSError *error = nil;
        NSArray *allFiles = [fileManager contentsOfDirectoryAtPath:backupDir error:&error];
        if (error) {
            NSLog(@"[ADManager Rotation] Error listing directory: %@", error);
            %orig;
            return;
        }
        
        NSMutableArray *backups = [NSMutableArray array];
        NSString *prefix = [bundleID stringByAppendingString:@"_"];
        for (NSString *file in allFiles) {
            if ([file hasPrefix:prefix] && [file hasSuffix:@".adbk"]) {
                [backups addObject:[backupDir stringByAppendingPathComponent:file]];
            }
        }
        
        // Sort backups alphabetically (chronological by timestamp)
        [backups sortUsingSelector:@selector(compare:)];
        
        if (backups.count <= 1) {
            NSLog(@"[ADManager Rotation] %lu backup found, skipping rotation.", (unsigned long)backups.count);
            %orig;
            return;
        }
        
        // 2. Logic to detect if a NEW manual selection was made or if we should continue rotating
        NSString *manualKey = [kRotationManualChoicePrefix stringByAppendingString:bundleID];
        NSString *lastManualPath = [defaults stringForKey:manualKey];
        
        NSString *indexKey = [kRotationIndexPrefix stringByAppendingString:bundleID];
        NSInteger nextIndex = [defaults integerForKey:indexKey];
        
        NSString *pathToRestore = path;
        
        if (![path isEqualToString:lastManualPath]) {
            // User manually selected a DIFFERENT backup in the UI
            NSLog(@"[ADManager Rotation] New manual selection detected: %@", path);
            [defaults setObject:path forKey:manualKey];
            
            // Find index of the manual choice and set next rotation to (index + 1)
            NSUInteger currentIndex = [backups indexOfObject:path];
            if (currentIndex != NSNotFound) {
                nextIndex = (currentIndex + 1) % backups.count;
                pathToRestore = backups[nextIndex]; // Rotate immediately
                NSLog(@"[ADManager Rotation] Rotating immediately to next: %@", pathToRestore);
                // Update index for the NEXT click
                nextIndex = (nextIndex + 1) % backups.count;
            }
        } else {
            // User clicked Restore again on the SAME selection
            if (nextIndex < backups.count) {
                pathToRestore = backups[nextIndex];
                NSLog(@"[ADManager Rotation] Continuing rotation. Selecting index %ld: %@", (long)nextIndex, pathToRestore);
                nextIndex = (nextIndex + 1) % backups.count;
            }
        }
        
        // 3. Save state
        [defaults setInteger:nextIndex forKey:indexKey];
        [defaults synchronize];
        
        // 4. Trigger original restore with the ROTATED path
        NSLog(@"[ADManager Rotation] Executing original restore with path: %@", pathToRestore);
        %orig(bundleID, pathToRestore, progress, completion);
        
    } @catch (NSException *exception) {
        NSLog(@"[ADManager Rotation] CRITICAL ERROR: %@", exception);
        %orig;
    }
}

%end // end hook BackupList

%end // end group RotationHook

%ctor {
    NSLog(@"[ADManager Rotation] Tweak dylib loaded. Initializing safe hooks...");
    
    // Lazy initialization: Check if class exists before hooking
    // This prevents crash if BackupList is loaded later or is in a different image
    Class backupListClass = NSClassFromString(@"BackupList");
    if (backupListClass) {
        NSLog(@"[ADManager Rotation] Found BackupList class, initializing group...");
        %init(RotationHook, BackupList = backupListClass);
    } else {
        NSLog(@"[ADManager Rotation] WARNING: BackupList class not found yet. Trying listener...");
        
        // Secondary strategy: wait for class if needed (usually for frameworks)
        // But for main binary classes, if it's not here now, it's not in the binary.
        // We'll just init anyway but mapping to nil will safely fail to hook.
        %init(RotationHook); 
    }
}

