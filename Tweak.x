// ADManagerRotation - Pure Objective-C runtime swizzle
// Diagnostic version: shows UIAlert to confirm hook is firing

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);
static RestoreIMP original_restoreApp = NULL;

static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"[ADM Rotation]" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIWindow *win = UIApplication.sharedApplication.windows.firstObject;
        [win.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

static void swizzled_restoreApp(id self, SEL _cmd, NSString *bundleID, NSString *path, id progress, id completion) {
    @try {
        NSLog(@"[ADMRotation] HOOK FIRED for: %@, path: %@", bundleID, path);

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = @"/var/mobile/Library/ADManager";
        NSError *err = nil;
        NSArray *allFiles = [fm contentsOfDirectoryAtPath:dir error:&err];

        if (err || !allFiles) {
            showToast([NSString stringWithFormat:@"Hook active! But cannot read backup dir: %@", err.localizedDescription]);
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

        if (backups.count <= 1) {
            showToast([NSString stringWithFormat:@"Hook active!\nOnly %lu backup found for %@.\nNeed 2+ for rotation.", (unsigned long)backups.count, bundleID]);
            if (original_restoreApp) original_restoreApp(self, _cmd, bundleID, path, progress, completion);
            return;
        }

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *idxKey      = [@"ADMIdx_" stringByAppendingString:bundleID];
        NSString *lastPathKey = [@"ADMLast_" stringByAppendingString:bundleID];
        NSString *lastPath    = [ud stringForKey:lastPathKey];

        NSInteger idx = [ud integerForKey:idxKey];
        if (lastPath && ![path isEqualToString:lastPath]) {
            NSUInteger found = [backups indexOfObject:path];
            idx = (found != NSNotFound) ? (NSInteger)((found + 1) % backups.count) : 0;
        }
        if (idx >= (NSInteger)backups.count) idx = 0;

        NSString *chosen = backups[(NSUInteger)idx];
        [ud setObject:chosen forKey:lastPathKey];
        [ud setInteger:(idx + 1) % (NSInteger)backups.count forKey:idxKey];
        [ud synchronize];

        NSString *chosenName = chosen.lastPathComponent;
        showToast([NSString stringWithFormat:@"Rotating! %ld/%lu\n%@", (long)(idx + 1), (unsigned long)backups.count, chosenName]);

        if (original_restoreApp) {
            original_restoreApp(self, _cmd, bundleID, chosen, progress, completion);
        }

    } @catch (NSException *e) {
        NSLog(@"[ADMRotation] Exception: %@", e);
        if (original_restoreApp) original_restoreApp(self, _cmd, bundleID, path, progress, completion);
    }
}

static BOOL swizzleClass(NSString *className, SEL sel) {
    Class cls = NSClassFromString(className);
    if (!cls) { NSLog(@"[ADMRotation] Class not found: %@", className); return NO; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[ADMRotation] Method not found on %@", className); return NO; }
    original_restoreApp = (RestoreIMP)method_getImplementation(m);
    method_setImplementation(m, (IMP)swizzled_restoreApp);
    NSLog(@"[ADMRotation] Swizzled %@ on %@", NSStringFromSelector(sel), className);
    return YES;
}

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        NSLog(@"[ADMRotation] Dylib loaded into: %@", NSProcessInfo.processInfo.processName);
        SEL sel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);
        if (!swizzleClass(@"BackupList", sel)) {
            swizzleClass(@"BackupInfoTableViewController", sel);
        }
    }
}

