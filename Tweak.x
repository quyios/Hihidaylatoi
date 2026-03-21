// ADManagerRotation - Adds "Restore A-Z (N)" button to BackupInfoTableViewController
// Pure ObjC runtime - no Substrate dependency

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);

// Use associated object key for per-instance state
static const void *kCurrentIndexKey = &kCurrentIndexKey;
static const void *kBundleIDKey     = &kBundleIDKey;
static const void *kButtonKey       = &kButtonKey;

#pragma mark - Helpers

static NSArray<NSString *> *getSortedBackups(NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @"/var/mobile/Library/ADManager";
    NSError *err = nil;
    NSArray *all = [fm contentsOfDirectoryAtPath:dir error:&err];
    if (!all || err) return @[];
    NSString *pfx = [bundleID stringByAppendingString:@"_"];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *f in all) {
        if ([f hasPrefix:pfx] && [f hasSuffix:@".adbk"])
            [result addObject:[dir stringByAppendingPathComponent:f]];
    }
    [result sortUsingSelector:@selector(compare:)];
    return result;
}

static NSString *getBundleID(id vc) {
    // Try several key paths used internally by ADManager
    NSArray *keys = @[@"bundleId", @"bundleID", @"appBundleId", @"appBundleID"];
    for (NSString *k in keys) {
        @try {
            id val = [vc valueForKey:k];
            if ([val isKindOfClass:[NSString class]] && [(NSString*)val length] > 0)
                return val;
        } @catch (...) {}
    }
    // Try getting from backupList model
    @try {
        id model = [vc valueForKey:@"backupList"];
        for (NSString *k in keys) {
            @try {
                id val = [model valueForKey:k];
                if ([val isKindOfClass:[NSString class]] && [(NSString*)val length] > 0)
                    return val;
            } @catch (...) {}
        }
    } @catch (...) {}
    // Last resort: read first .adbk file from dir and parse bundle ID from filename
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
    for (NSString *f in files) {
        if ([f hasSuffix:@".adbk"]) {
            NSArray *parts = [f componentsSeparatedByString:@"_"];
            if (parts.count >= 2) return [parts firstObject];
        }
    }
    return nil;
}

static void updateButtonTitle(UIBarButtonItem *btn, NSInteger idx, NSUInteger total) {
    NSString *title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(idx + 1)];
    [btn setTitle:title];
    (void)total;
}

#pragma mark - Button Action (added as method on VC class)

static void admRestoreNext(id self, SEL _cmd) {
    @try {
        NSString *bundleID = objc_getAssociatedObject(self, kBundleIDKey);
        if (!bundleID || bundleID.length == 0) {
            bundleID = getBundleID(self);
            if (!bundleID) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Error" message:@"Could not determine Bundle ID." preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
                return;
            }
            objc_setAssociatedObject(self, kBundleIDKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSArray<NSString *> *backups = getSortedBackups(bundleID);
        if (backups.count == 0) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ADM Rotation" message:@"No backups found for this app." preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }

        NSNumber *idxNum = objc_getAssociatedObject(self, kCurrentIndexKey);
        NSInteger idx = idxNum ? idxNum.integerValue : 0;
        if (idx >= (NSInteger)backups.count) idx = 0;

        NSString *chosenPath = backups[(NSUInteger)idx];
        NSLog(@"[ADMRotation] Button: restoring idx=%ld path=%@", (long)idx, chosenPath);

        // Update button
        UIBarButtonItem *btn = objc_getAssociatedObject(self, kButtonKey);
        NSInteger nextIdx = (idx + 1) % (NSInteger)backups.count;
        objc_setAssociatedObject(self, kCurrentIndexKey, @(nextIdx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (btn) updateButtonTitle(btn, nextIdx, backups.count);

        // Call restore on BackupList model (it holds the actual restore logic)
        SEL restoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);
        id model = nil;
        @try { model = [self valueForKey:@"backupList"]; } @catch (...) {}

        if (model && [model respondsToSelector:restoreSel]) {
            ((RestoreIMP)objc_msgSend)(model, restoreSel, bundleID, chosenPath, nil, nil);
        } else if ([self respondsToSelector:restoreSel]) {
            ((RestoreIMP)objc_msgSend)(self, restoreSel, bundleID, chosenPath, nil, nil);
        }

    } @catch (NSException *e) {
        NSLog(@"[ADMRotation] Button action error: %@", e);
    }
}

#pragma mark - viewWillAppear swizzle

static IMP original_viewWillAppear = NULL;

static void swizzled_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (original_viewWillAppear)
        ((void(*)(id,SEL,BOOL))original_viewWillAppear)(self, _cmd, animated);

    @try {
        // Only add button once per VC instance
        UIBarButtonItem *existingBtn = objc_getAssociatedObject(self, kButtonKey);
        if (existingBtn) return;

        // Pre-fetch bundleID and backup count for initial button title
        NSString *bundleID = getBundleID(self);
        if (bundleID) {
            objc_setAssociatedObject(self, kBundleIDKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSArray *backups = bundleID ? getSortedBackups(bundleID) : @[];
        NSInteger startIdx = 0;
        if (bundleID) {
            // Restore saved index
            NSString *idxKey = [@"ADMIdx_" stringByAppendingString:bundleID];
            startIdx = [[NSUserDefaults standardUserDefaults] integerForKey:idxKey];
            if (startIdx >= (NSInteger)backups.count) startIdx = 0;
        }
        objc_setAssociatedObject(self, kCurrentIndexKey, @(startIdx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Create button
        NSString *title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(startIdx + 1)];
        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:title
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(adm_restoreNext)];
        objc_setAssociatedObject(self, kButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Add to navigation bar alongside existing right items
        UINavigationItem *navItem = [(UIViewController *)self navigationItem];
        NSArray *existing = navItem.rightBarButtonItems ?: @[];
        navItem.rightBarButtonItems = [@[btn] arrayByAddingObjectsFromArray:existing];

    } @catch (NSException *e) {
        NSLog(@"[ADMRotation] viewWillAppear hook error: %@", e);
    }
}

#pragma mark - Constructor

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        NSLog(@"[ADMRotation] Initializing...");

        SEL viewWillAppearSel = @selector(viewWillAppear:);
        SEL restoreSel        = @selector(restoreApp:fromPathBackup:progress:withCompletion:);
        SEL buttonActionSel   = @selector(adm_restoreNext);

        // Find BackupInfoTableViewController by scanning all classes
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) return;

        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            // Look for a class that has both a restore method and a viewWillAppear (i.e., it's a VC)
            if (!class_getInstanceMethod(cls, restoreSel)) continue;

            // Check if it's a UIViewController subclass (has viewWillAppear:)
            Method vwaMethod = class_getInstanceMethod(cls, viewWillAppearSel);
            if (!vwaMethod) continue;

            NSString *clsName = NSStringFromClass(cls);
            NSLog(@"[ADMRotation] Found target VC: %@", clsName);

            // Add the button action method
            class_addMethod(cls, buttonActionSel, (IMP)admRestoreNext, "v@:");

            // Swizzle viewWillAppear:
            original_viewWillAppear = method_getImplementation(vwaMethod);
            method_setImplementation(vwaMethod, (IMP)swizzled_viewWillAppear);

            NSLog(@"[ADMRotation] Hooked viewWillAppear on %@", clsName);
            break;
        }
        free(classes);
    }
}

