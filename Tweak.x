// ADManagerRotation - Pure Objective-C runtime swizzle
// No Substrate, No Logos, No external dependencies.
// Works with TrollStore out of the box.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- Rotation logic ----
typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);
static RestoreIMP original_restoreApp = NULL;

static void swizzled_restoreApp(id self, SEL _cmd, NSString *bundleID, NSString *path, id progress, id completion) {
    @try {
        NSLog(@"[ADMRotation] Intercepted restoreApp for: %@", bundleID);

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = @"/var/mobile/Library/ADManager";

        NSError *err = nil;
        NSArray *allFiles = [fm contentsOfDirectoryAtPath:dir error:&err];
        if (err || !allFiles) {
            NSLog(@"[ADMRotation] Cannot read dir, falling back. Error: %@", err);
            if (original_restoreApp) original_restoreApp(self, _cmd, bundleID, path, progress, completion);
            return;
        }

        NSString *pfx = [bundleID stringByAppendingString:@"_"];
        NSMutableArray<NSString *> *backups = [NSMutableArray array];
        for (NSString *f in allFiles) {
            if ([f hasPrefix:pfx] && [f hasSuffix:@".adbk"]) {
                [backups addObject:[dir stringByAppendingPathComponent:f]];
            }
        }
        [backups sortUsingSelector:@selector(compare:)];
        NSLog(@"[ADMRotation] %lu backups found for %@", (unsigned long)backups.count, bundleID);

        if (backups.count <= 1) {
            if (original_restoreApp) original_restoreApp(self, _cmd, bundleID, path, progress, completion);
            return;
        }

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *idxKey      = [@"ADMIdx_" stringByAppendingString:bundleID];
        NSString *lastPathKey = [@"ADMLast_" stringByAppendingString:bundleID];
        NSString *lastPath    = [ud stringForKey:lastPathKey];

        NSInteger idx = [ud integerForKey:idxKey];

        if (lastPath && ![path isEqualToString:lastPath]) {
            // User picked a different backup manually - reset rotation from there
            NSUInteger found = [backups indexOfObject:path];
            idx = (found != NSNotFound) ? (NSInteger)((found + 1) % backups.count) : 0;
            NSLog(@"[ADMRotation] Manual change detected. Resetting idx to %ld", (long)idx);
        }

        if (idx >= (NSInteger)backups.count) idx = 0;

        NSString *chosen = backups[(NSUInteger)idx];
        NSLog(@"[ADMRotation] Rotating to idx=%ld: %@", (long)idx, chosen);

        [ud setObject:chosen forKey:lastPathKey];
        [ud setInteger:(idx + 1) % (NSInteger)backups.count forKey:idxKey];
        [ud synchronize];

        if (original_restoreApp) {
            original_restoreApp(self, _cmd, bundleID, chosen, progress, completion);
        }

    } @catch (NSException *e) {
        NSLog(@"[ADMRotation] Exception: %@. Falling back to original.", e);
        if (original_restoreApp) original_restoreApp(self, _cmd, bundleID, path, progress, completion);
    }
}

// ---- Swizzle helper ----
static BOOL swizzleClass(NSString *className, SEL originalSel) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        NSLog(@"[ADMRotation] Class '%@' not found.", className);
        return NO;
    }

    Method origMethod = class_getInstanceMethod(cls, originalSel);
    if (!origMethod) {
        NSLog(@"[ADMRotation] Method not found in '%@'.", className);
        return NO;
    }

    // Save original IMP
    original_restoreApp = (RestoreIMP)method_getImplementation(origMethod);

    // Replace with our swizzled version
    method_setImplementation(origMethod, (IMP)swizzled_restoreApp);

    NSLog(@"[ADMRotation] Successfully swizzled %@ on %@", NSStringFromSelector(originalSel), className);
    return YES;
}

// ---- Constructor ----
__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        NSLog(@"[ADMRotation] Dylib loaded into: %@", NSProcessInfo.processInfo.processName);

        SEL restoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);

        // Try primary class first
        if (!swizzleClass(@"BackupList", restoreSel)) {
            // Fallback to view controller
            swizzleClass(@"BackupInfoTableViewController", restoreSel);
        }
    }
}

