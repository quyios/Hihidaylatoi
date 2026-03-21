// ADManagerRotation - UIViewController-level hook with duck typing
// No class name guessing. Works with cracked/renamed binaries.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);
typedef void (*VWA_IMP)(id, SEL, BOOL);

static VWA_IMP gOrigVWA = nil;
static SEL     gRestoreSel;

static const void *kBtnKey    = &kBtnKey;
static const void *kIdxKey    = &kIdxKey;
static const void *kBundleKey = &kBundleKey;

// ---- Helpers ----

static NSArray<NSString *> *sortedBackups(NSString *bundleID) {
    NSError *e = nil;
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:&e];
    if (!all) return @[];
    NSString *pfx = [bundleID stringByAppendingString:@"_"];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *f in all)
        if ([f hasPrefix:pfx] && [f hasSuffix:@".adbk"])
            [r addObject:[@"/var/mobile/Library/ADManager" stringByAppendingPathComponent:f]];
    [r sortUsingSelector:@selector(compare:)];
    return r;
}

static NSString *bundleIDFromDir(void) {
    // Return first bundle ID found in the directory
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
    for (NSString *f in all) {
        if ([f hasSuffix:@".adbk"]) {
            NSArray *parts = [f componentsSeparatedByString:@"_"];
            if (parts.count >= 2) return parts[0];
        }
    }
    return nil;
}

static NSString *detectBundleID(id vc, id backupListModel) {
    // Try VC key paths
    for (NSString *k in @[@"bundleId",@"bundleID",@"appBundleId",@"appBundleID",@"bundleIdentifier"]) {
        @try { id v=[vc valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; } @catch(...){}
    }
    // Try backupInfo sub-object
    @try {
        id info=[vc valueForKey:@"backupInfo"];
        for(NSString *k in @[@"bundleId",@"bundleID",@"bundleIdentifier"]){
            @try{id v=[info valueForKey:k];if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v;}@catch(...){}
        }
    } @catch(...) {}
    // Try backupList model
    for(NSString *k in @[@"bundleId",@"bundleID",@"appBundleId",@"bundleIdentifier"]){
        @try{id v=[backupListModel valueForKey:k];if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v;}@catch(...){}
    }
    return nil;
}

// ---- Button Action ----

static void adm_restoreNext(id self, SEL _cmd) {
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch(...) {}

    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    if (!bundleID) bundleID = detectBundleID(self, model);
    if (!bundleID) {
        // Fallback: just use first bundle ID in dir
        bundleID = bundleIDFromDir();
    }
    if (!bundleID) return;
    objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<NSString *> *backups = sortedBackups(bundleID);
    if (!backups.count) {
        NSLog(@"[ADMRotation] No backups found for %@", bundleID);
        return;
    }

    NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey);
    NSInteger idx = idxN ? idxN.integerValue : 0;
    if (idx >= (NSInteger)backups.count) idx = 0;

    NSString *chosen = backups[(NSUInteger)idx];
    NSInteger next = (idx + 1) % (NSInteger)backups.count;

    // Update button
    UIBarButtonItem *btn = objc_getAssociatedObject(self, kBtnKey);
    if (btn) btn.title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(next + 1)];
    objc_setAssociatedObject(self, kIdxKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Persist
    [[NSUserDefaults standardUserDefaults] setInteger:next forKey:[@"ADMIdx2_" stringByAppendingString:bundleID]];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSLog(@"[ADMRotation] Restoring %ld/%lu: %@", (long)(idx+1), (unsigned long)backups.count, chosen.lastPathComponent);

    // Call restore on model or self
    if (model && [model respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(model, gRestoreSel, bundleID, chosen, nil, nil);
    else if ([self respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(self, gRestoreSel, bundleID, chosen, nil, nil);
}

// ---- Global viewWillAppear: hook ----

static void swizzled_VWA(id self, SEL _cmd, BOOL animated) {
    if (gOrigVWA) gOrigVWA(self, _cmd, animated);

    @try {
        // Skip if button already injected
        if (objc_getAssociatedObject(self, kBtnKey)) return;

        // Duck-type: does this VC own a backupList with the restore method?
        id model = nil;
        @try { model = [self valueForKey:@"backupList"]; } @catch(...) {}
        BOOL modelHas = model && [model respondsToSelector:gRestoreSel];
        BOOL selfHas  = [self respondsToSelector:gRestoreSel];

        if (!modelHas && !selfHas) return;  // Not our target VC

        NSLog(@"[ADMRotation] Target VC detected: %@", NSStringFromClass([self class]));

        // Get bundleID for initial button counter
        NSString *bundleID = detectBundleID(self, model);
        if (!bundleID) bundleID = bundleIDFromDir();
        if (bundleID) {
            objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:[@"ADMIdx2_" stringByAppendingString:bundleID]];
            objc_setAssociatedObject(self, kIdxKey, @(saved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey) ?: @0;
        NSString *btnTitle = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(idxN.integerValue + 1)];

        // Ensure adm_restoreNext is available on this class
        SEL btnAction = @selector(adm_restoreNext);
        if (![self respondsToSelector:btnAction])
            class_addMethod([self class], btnAction, (IMP)adm_restoreNext, "v@:");

        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:btnTitle
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:btnAction];
        objc_setAssociatedObject(self, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UINavigationItem *nav = [(UIViewController*)self navigationItem];
        NSArray *existing = nav.rightBarButtonItems ?: @[];
        nav.rightBarButtonItems = [@[btn] arrayByAddingObjectsFromArray:existing];
        NSLog(@"[ADMRotation] Button injected on %@", NSStringFromClass([self class]));

    } @catch(NSException *e) {
        NSLog(@"[ADMRotation] VWA hook error: %@", e);
    }
}

// ---- Constructor ----

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        gRestoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);

        // Hook UIViewController.viewWillAppear: — always available, no class name needed
        Method m = class_getInstanceMethod([UIViewController class], @selector(viewWillAppear:));
        gOrigVWA = (VWA_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_VWA);
        NSLog(@"[ADMRotation] Hooked UIViewController.viewWillAppear:");
    }
}

