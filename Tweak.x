// ADManagerRotation - Runtime class scanner
// Finds the restore method by scanning ALL ObjC classes - no class name guessing

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);
static RestoreIMP original_restoreApp = NULL;

static void showAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = UIApplication.sharedApplication.windows.firstObject;
        if (!win.rootViewController) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [win.rootViewController presentViewController:a animated:YES completion:nil];
    });
}

static void swizzled_restoreApp(id self, SEL _cmd, NSString *bundleID, NSString *path, id progress, id completion) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = @"/var/mobile/Library/ADManager";
        NSError *err = nil;
        NSArray *allFiles = [fm contentsOfDirectoryAtPath:dir error:&err];

        if (err || !allFiles) {
            showAlert(@"ADM Hook", [NSString stringWithFormat:@"Dir error: %@", err.localizedDescription]);
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
            showAlert(@"ADM Hook Active ✓", [NSString stringWithFormat:@"Only %lu backup for\n%@\n\nNeed 2+ to rotate.", (unsigned long)backups.count, bundleID]);
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

        showAlert(@"ADM Rotating ✓",
                  [NSString stringWithFormat:@"Backup %ld/%lu\n%@",
                   (long)(idx + 1), (unsigned long)backups.count, chosen.lastPathComponent]);

        if (original_restoreApp) {
            original_restoreApp(self, _cmd, bundleID, chosen, progress, completion);
        }

    } @catch (NSException *e) {
        if (original_restoreApp) original_restoreApp(self, _cmd, bundleID, path, progress, completion);
    }
}

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        SEL targetSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);
        NSString *foundClassName = nil;

        // Scan ALL registered ObjC classes
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        if (!classes) return;

        for (unsigned int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            Method m = class_getInstanceMethod(cls, targetSel);
            if (m) {
                foundClassName = NSStringFromClass(cls);
                NSLog(@"[ADMRotation] Found target method on class: %@", foundClassName);

                // Swizzle it
                original_restoreApp = (RestoreIMP)method_getImplementation(m);
                method_setImplementation(m, (IMP)swizzled_restoreApp);
                NSLog(@"[ADMRotation] Swizzled successfully!");
                break;
            }
        }
        free(classes);

        if (!foundClassName) {
            NSLog(@"[ADMRotation] WARNING: Target method not found in any class!");
            // Show alert after UI is ready
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                showAlert(@"ADM: Method Not Found ✗",
                          @"restoreApp:fromPathBackup:progress:withCompletion:\n\nNot found in any class. Please report this.");
            });
        } else {
            NSLog(@"[ADMRotation] Hooked class: %@", foundClassName);
            NSString *hookedClass = foundClassName;
            // Show startup confirmation after a short delay (UI needs to be ready)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                showAlert(@"ADM Rotation Ready ✓",
                          [NSString stringWithFormat:@"Hooked:\n%@\n\nPress Restore to rotate backups.", hookedClass]);
            });
        }
    }
}

