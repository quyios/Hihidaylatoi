// ADManagerRotation - Final version
// Uses setBackupList: hook to inject button exactly when VC receives its model data

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);
typedef void (*SetBLIMP)(id, SEL, id);

static SEL   gRestoreSel;
static SetBLIMP gOrigSetBL = nil;

static const void *kBtnKey    = &kBtnKey;
static const void *kIdxKey    = &kIdxKey;
static const void *kBundleKey = &kBundleKey;

#pragma mark - Backup helpers

static NSArray<NSString *> *sortedBackups(NSString *bundleID) {
    NSError *e = nil;
    NSArray *all = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:&e];
    if (!all) return @[];
    NSString *pfx = [bundleID stringByAppendingString:@"_"];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *f in all)
        if ([f hasPrefix:pfx] && [f hasSuffix:@".adbk"])
            [r addObject:[@"/var/mobile/Library/ADManager" stringByAppendingPathComponent:f]];
    [r sortUsingSelector:@selector(compare:)];
    return r;
}

static NSString *bundleFromModel(id model) {
    for (NSString *k in @[@"bundleId",@"bundleID",@"appBundleId",@"bundleIdentifier"]) {
        @try {
            id v = [model valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString*)v length]) return v;
        } @catch (...) {}
    }
    return nil;
}

#pragma mark - Button action

static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch(...) {}
    if (!bundleID) bundleID = bundleFromModel(model);
    if (!bundleID) return;

    NSArray<NSString *> *backups = sortedBackups(bundleID);
    if (!backups.count) return;

    NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey);
    NSInteger idx  = idxN ? idxN.integerValue : 0;
    if (idx >= (NSInteger)backups.count) idx = 0;

    NSString *chosen = backups[(NSUInteger)idx];
    NSInteger next   = (idx + 1) % (NSInteger)backups.count;
    objc_setAssociatedObject(self, kIdxKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIBarButtonItem *btn = objc_getAssociatedObject(self, kBtnKey);
    if (btn) btn.title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(next+1)];

    NSLog(@"[ADMRotation] Button: restoring #%ld: %@", (long)(idx+1), chosen.lastPathComponent);

    if (model && [model respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(model, gRestoreSel, bundleID, chosen, nil, nil);
    else if ([self respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(self, gRestoreSel, bundleID, chosen, nil, nil);
}

#pragma mark - setBackupList: hook — fires when VC gets its model

static void adm_setBackupList(id self, SEL _cmd, id backupList) {
    // Call original setter
    if (gOrigSetBL) gOrigSetBL(self, _cmd, backupList);

    @try {
        // Skip if button already injected
        if (objc_getAssociatedObject(self, kBtnKey)) return;

        // Cache bundleID
        NSString *bundleID = bundleFromModel(backupList);
        if (bundleID) {
            objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSInteger saved = [[NSUserDefaults standardUserDefaults]
                integerForKey:[@"ADMIdx_" stringByAppendingString:bundleID]];
            objc_setAssociatedObject(self, kIdxKey, @(saved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSNumber *startN = objc_getAssociatedObject(self, kIdxKey) ?: @0;
        NSString *title  = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(startN.integerValue+1)];

        // Ensure button action method exists on this class
        if (![self respondsToSelector:@selector(adm_restoreNext)])
            class_addMethod([self class], @selector(adm_restoreNext), (IMP)adm_restoreNext, "v@:");

        UIBarButtonItem *btn = [[UIBarButtonItem alloc]
            initWithTitle:title style:UIBarButtonItemStylePlain
                   target:self action:@selector(adm_restoreNext)];
        objc_setAssociatedObject(self, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Inject into nav bar on main thread (UI must be ready)
        dispatch_async(dispatch_get_main_queue(), ^{
            UINavigationItem *nav = [(UIViewController*)self navigationItem];
            NSArray *existing = nav.rightBarButtonItems ?: @[];
            // Avoid double injection
            for (UIBarButtonItem *b in existing)
                if ([b.title hasPrefix:@"Restore A-Z"]) return;
            nav.rightBarButtonItems = [@[btn] arrayByAddingObjectsFromArray:existing];
            NSLog(@"[ADMRotation] Button injected on %@", NSStringFromClass([self class]));
        });

    } @catch (NSException *e) {
        NSLog(@"[ADMRotation] setBackupList hook error: %@", e);
    }
}

#pragma mark - Constructor

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        NSLog(@"[ADMRotation] Initializing...");
        gRestoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);

        // Identify target VC by its unique app-binary methods
        // DeleteEntry: is unique to BackupInfoTableViewController
        NSArray *vcSignatureSels = @[
            @"DeleteEntry:",
            @"backup:",
        ];

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) return;

        Class vcClass = nil;
        for (unsigned int i = 0; i < count && !vcClass; i++) {
            Class cls = classes[i];
            for (NSString *selName in vcSignatureSels) {
                if (class_getInstanceMethod(cls, NSSelectorFromString(selName))) {
                    vcClass = cls;
                    break;
                }
            }
        }
        free(classes);

        NSLog(@"[ADMRotation] Target VC: %@", NSStringFromClass(vcClass));

        if (!vcClass) {
            NSLog(@"[ADMRotation] VC not found. Exiting.");
            return;
        }

        // Hook setBackupList: on the VC class
        SEL setBLSel = NSSelectorFromString(@"setBackupList:");
        Method m = class_getInstanceMethod(vcClass, setBLSel);
        if (m) {
            gOrigSetBL = (SetBLIMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)adm_setBackupList);
            NSLog(@"[ADMRotation] Hooked setBackupList: on %@", NSStringFromClass(vcClass));
        } else {
            NSLog(@"[ADMRotation] setBackupList: NOT found. Trying alternative...");
            // Fallback: hook the restore method itself to inject button from there
            // (button will appear after first restore attempt, not ideal but functional)
            Method restoreM = class_getInstanceMethod(vcClass, gRestoreSel);
            if (restoreM) {
                // Hook tableView:didSelectRowAtIndexPath: if present as alternative trigger
                SEL didSelectSel = @selector(tableView:didSelectRowAtIndexPath:);
                Method selectM = class_getInstanceMethod(vcClass, didSelectSel);
                NSLog(@"[ADMRotation] tableView:didSelectRow on VC: %@", selectM ? @"YES" : @"NO");
            }
        }
    }
}

