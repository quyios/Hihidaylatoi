// ADManagerRotation - Finds BackupInfoTableViewController via app-binary method scan
// Avoids dyld shared cache issues by hooking app classes, not UIKit.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);
typedef void (*VWA_IMP)(id, SEL, BOOL);

static id    gBackupListClass  = nil;  // Class object of BackupList
static VWA_IMP gOrigVWA        = nil;
static SEL   gRestoreSel;

static const void *kBtnKey    = &kBtnKey;
static const void *kIdxKey    = &kIdxKey;
static const void *kBundleKey = &kBundleKey;

#pragma mark - Helpers

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

static NSString *detectBundleID(id vc, id model) {
    for (NSString *k in @[@"bundleId",@"bundleID",@"appBundleId",@"bundleIdentifier"]) {
        @try { id v=[vc valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; }@catch(...){}
        @try { id v=[model valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; }@catch(...){}
        @try { id info=[vc valueForKey:@"backupInfo"]; id v=[info valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; }@catch(...){}
    }
    // Fallback: first bundleID in dir
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
    for (NSString *f in files)
        if ([f hasSuffix:@".adbk"]) { NSArray *p=[f componentsSeparatedByString:@"_"]; if(p.count>=2) return p[0]; }
    return nil;
}

#pragma mark - Button Action

static void adm_restoreNext(id self, SEL _cmd) {
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch(...) {} 

    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey) ?: detectBundleID(self, model);
    if (!bundleID) return;
    objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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

    NSLog(@"[ADMRotation] Restoring #%ld: %@", (long)(idx+1), chosen.lastPathComponent);

    if (model && [model respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(model, gRestoreSel, bundleID, chosen, nil, nil);
    else if ([self respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(self, gRestoreSel, bundleID, chosen, nil, nil);
}

#pragma mark - viewWillAppear (injected on BackupInfoTableViewController)

static void adm_vwa(id self, SEL _cmd, BOOL animated) {
    // Call super (UITableViewController → UIViewController)
    if (gOrigVWA) gOrigVWA(self, _cmd, animated);

    if (objc_getAssociatedObject(self, kBtnKey)) return;  // already injected

    // Resolve bundleID and initial index
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch(...) {}
    NSString *bundleID = detectBundleID(self, model);
    if (bundleID) {
        objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:[@"ADMIdx_" stringByAppendingString:bundleID]];
        objc_setAssociatedObject(self, kIdxKey, @(saved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSNumber *startN = objc_getAssociatedObject(self, kIdxKey) ?: @0;
    NSString *title  = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(startN.integerValue+1)];

    UIBarButtonItem *btn = [[UIBarButtonItem alloc]
        initWithTitle:title style:UIBarButtonItemStylePlain
               target:self action:@selector(adm_restoreNext)];
    objc_setAssociatedObject(self, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UINavigationItem *nav = [(UIViewController*)self navigationItem];
    NSArray *existing = nav.rightBarButtonItems ?: @[];
    nav.rightBarButtonItems = [@[btn] arrayByAddingObjectsFromArray:existing];
    NSLog(@"[ADMRotation] Button injected on %@", NSStringFromClass([self class]));
}

#pragma mark - Constructor

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        gRestoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);

        // Selectors we use to identify our target VC (app-binary methods, never UIKit)
        NSArray *vcIdentifiers = @[
            @"showRestoreAppActionSheet",
            @"showRestoreAppActionSheet:",
            @"showBackupAppActionSheet",
            @"showBackupAppActionSheet:",
        ];

        Class vcClass = nil;

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) return;

        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];

            // --- Find BackupList ---
            if (!gBackupListClass && class_getInstanceMethod(cls, gRestoreSel))
                gBackupListClass = cls;

            // --- Find BackupInfoTableViewController ---
            if (!vcClass) {
                for (NSString *selName in vcIdentifiers) {
                    SEL s = NSSelectorFromString(selName);
                    if (class_getInstanceMethod(cls, s)) {
                        vcClass = cls;
                        break;
                    }
                }
            }

            if (gBackupListClass && vcClass) break;
        }
        free(classes);

        NSLog(@"[ADMRotation] BackupList=%@  VC=%@",
              NSStringFromClass((Class)gBackupListClass),
              NSStringFromClass(vcClass));

        if (!vcClass) {
            NSLog(@"[ADMRotation] Target VC not found.");
            return;
        }

        // Add button action method to the VC class
        class_addMethod(vcClass, @selector(adm_restoreNext), (IMP)adm_restoreNext, "v@:");

        // Hook viewWillAppear: ON THE VC CLASS ITSELF (app binary, not UIKit)
        SEL vwaSel = @selector(viewWillAppear:);
        Method m = class_getInstanceMethod(vcClass, vwaSel);
        // Check if the class owns this method (vs inherited)
        unsigned int ownCount = 0;
        Method *ownMethods = class_copyMethodList(vcClass, &ownCount);
        BOOL ownsVWA = NO;
        for (unsigned j = 0; j < ownCount; j++) {
            if (method_getName(ownMethods[j]) == vwaSel) { ownsVWA = YES; break; }
        }
        free(ownMethods);

        if (ownsVWA) {
            // Swizzle the VC's own viewWillAppear:
            gOrigVWA = (VWA_IMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)adm_vwa);
            NSLog(@"[ADMRotation] Swizzled own viewWillAppear: on %@", NSStringFromClass(vcClass));
        } else {
            // VC doesn't own viewWillAppear: → add it
            gOrigVWA = (VWA_IMP)method_getImplementation(
                class_getInstanceMethod(class_getSuperclass(vcClass), vwaSel));
            class_addMethod(vcClass, vwaSel, (IMP)adm_vwa, "v@:B");
            NSLog(@"[ADMRotation] Added viewWillAppear: to %@", NSStringFromClass(vcClass));
        }
    }
}

