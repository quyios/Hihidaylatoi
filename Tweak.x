#import <UIKit/UIKit.h>

// State constants
static NSString *const kRotationManualChoicePrefix = @"ManualChoice_";
static NSString *const kRotationIndexPrefix = @"RotationIndex_";

@interface BackupList : NSObject
- (void)restoreApp:(NSString *)bundleID fromPathBackup:(NSString *)path progress:(id)progress withCompletion:(id)completion;
@end

%hook BackupList

- (void)restoreApp:(NSString *)bundleID fromPathBackup:(NSString *)path progress:(id)progress withCompletion:(id)completion {
    
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
        NSLog(@"[ADManager Rotation] 0 or 1 backup found, skipping rotation.");
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
            pathToRestore = backups[nextIndex]; // Rotate immediately as per user request
            // Update nextIndex for the NEXT click
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
    
    // 4. Show a quick toast/alert if possible (Optional, but helps verification)
    NSLog(@"[ADManager Rotation] Restoring: %@", pathToRestore);
    
    // 5. Trigger original restore with the ROTATED path
    %orig(bundleID, pathToRestore, progress, completion);
}

%end

