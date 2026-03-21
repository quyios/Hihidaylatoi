// ADManagerRotation - Adds "Restore A-Z (N)" button
// Fixed viewWillAppear injection + ivar diagnostic

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);

static const void *kIdxKey    = &kIdxKey;
static const void *kBtnKey    = &kBtnKey;
static const void *kBundleKey = &kBundleKey;

static Class gTargetClass = nil;
static IMP   gOrigVWA     = nil;  // original viewWillAppear IMP from superclass

#pragma mark - Helpers

static NSArray<NSString *> *sortedBackups(NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *e = nil;
    NSArray *all = [fm contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:&e];
    if (!all) return @[];
    NSString *pfx = [bundleID stringByAppendingString:@"_"];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *f in all)
        if ([f hasPrefix:pfx] && [f hasSuffix:@".adbk"])
            [r addObject:[@"/var/mobile/Library/ADManager" stringByAppendingPathComponent:f]];
    [r sortUsingSelector:@selector(compare:)];
    return r;
}

// Try every ivar as potential bundleID source
static NSString *detectBundleID(id vc) {
    // 1. Try direct keys
    for (NSString *k in @[@"bundleId", @"bundleID", @"appBundleId", @"appBundleID"]) {
        @try { id v = [vc valueForKey:k]; if ([v isKindOfClass:[NSString class]] && [(NSString*)v length]) return v; } @catch (...) {}
    }
    // 2. Try via backupInfo object
    @try {
        id info = [vc valueForKey:@"backupInfo"];
        for (NSString *k in @[@"bundleId", @"bundleID", @"bundleIdentifier"]) {
            @try { id v = [info valueForKey:k]; if ([v isKindOfClass:[NSString class]] && [(NSString*)v length]) return v; } @catch (...) {}
        }
    } @catch (...) {}
    // 3. Try to parse from first cell text (table data)
    @try {
        UITableView *tv = [vc valueForKey:@"tableView"];
        UITableViewCell *cell = [[tv visibleCells] firstObject];
        NSString *txt = cell.textLabel.text;
        // Check if it looks like a bundle ID (has dots, no spaces)
        if (txt && [txt containsString:@"."] && ![txt containsString:@" "]) return txt;
    } @catch (...) {}
    return nil;
}

// Build informative dump of all ivars (diagnostic)
static NSString *ivarDump(id obj) {
    if (!obj) return @"(nil)";
    NSMutableString *s = [NSMutableString string];
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(obj), &n);
    for (unsigned i = 0; i < n; i++) {
        const char *name = ivar_getName(ivars[i]);
        @try {
            id val = [obj valueForKey:@(name + (name[0]=='_' ? 1 : 0))]; // strip leading _
            [s appendFormat:@"%s = %@\n", name, val ?: @"nil"];
        } @catch (...) {
            [s appendFormat:@"%s = (err)\n", name];
        }
    }
    free(ivars);
    return s;
}

#pragma mark - Button Action

static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    if (!bundleID) { bundleID = detectBundleID(self); }
    if (!bundleID) {
        // Show diagnostic
        NSString *dump = ivarDump(self);
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ADM: Need BundleID" message:dump preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [(UIViewController*)self presentViewController:a animated:YES completion:nil];
        return;
    }
    objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<NSString *> *backups = sortedBackups(bundleID);
    if (!backups.count) return;

    NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey);
    NSInteger idx = idxN ? idxN.integerValue : 0;
    if (idx >= (NSInteger)backups.count) idx = 0;

    NSString *chosen = backups[(NSUInteger)idx];
    NSLog(@"[ADMRotation] Restoring idx=%ld: %@", (long)idx, chosen);

    // Update button title
    UIBarButtonItem *btn = objc_getAssociatedObject(self, kBtnKey);
    NSInteger next = (idx + 1) % (NSInteger)backups.count;
    objc_setAssociatedObject(self, kIdxKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Persist index
    NSString *idxKey = [@"ADMIdx2_" stringByAppendingString:bundleID];
    [[NSUserDefaults standardUserDefaults] setInteger:next forKey:idxKey];
    if (btn) btn.title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(next + 1)];

    // Call restore on BackupList model or self
    SEL restoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch (...) {}
    if (model && [model respondsToSelector:restoreSel])
        ((RestoreIMP)objc_msgSend)(model, restoreSel, bundleID, chosen, nil, nil);
    else if ([self respondsToSelector:restoreSel])
        ((RestoreIMP)objc_msgSend)(self, restoreSel, bundleID, chosen, nil, nil);
}

#pragma mark - viewWillAppear override (added to target class)

static void adm_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    // Call original (from superclass)
    if (gOrigVWA) ((void(*)(id,SEL,BOOL))gOrigVWA)(self, _cmd, animated);

    // Only add button once per instance
    if (objc_getAssociatedObject(self, kBtnKey)) return;

    // Init index from saved state (try to detect bundleID first)
    NSString *bundleID = detectBundleID(self);
    if (bundleID) {
        objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *idxKey = [@"ADMIdx2_" stringByAppendingString:bundleID];
        NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:idxKey];
        objc_setAssociatedObject(self, kIdxKey, @(saved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey) ?: @0;
    NSString *title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(idxN.integerValue + 1)];
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:title
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:@selector(adm_restoreNext)];
    objc_setAssociatedObject(self, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UINavigationItem *nav = [(UIViewController*)self navigationItem];
    NSArray *existing = nav.rightBarButtonItems ?: @[];
    nav.rightBarButtonItems = [@[btn] arrayByAddingObjectsFromArray:existing];
}

#pragma mark - Constructor

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        SEL restoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);
        SEL vwaSel     = @selector(viewWillAppear:);
        SEL btnSel     = @selector(adm_restoreNext);

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) return;

        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            // Must have the restore method...
            if (!class_getInstanceMethod(cls, restoreSel)) continue;
            // ...and be a UIViewController subclass (check if UIViewController is in the hierarchy)
            Class sup = cls;
            BOOL isVC = NO;
            while ((sup = class_getSuperclass(sup))) {
                if (sup == [UIViewController class]) { isVC = YES; break; }
            }
            if (!isVC) continue;

            NSLog(@"[ADMRotation] Target VC class: %@", NSStringFromClass(cls));
            gTargetClass = cls;

            // Add button action method
            class_addMethod(cls, btnSel, (IMP)adm_restoreNext, "v@:");

            // Add viewWillAppear: override to THIS class specifically
            // Get the inherited IMP to call as super
            gOrigVWA = method_getImplementation(class_getInstanceMethod(class_getSuperclass(cls), vwaSel));
            // Try to add; if it already exists, swizzle it
            BOOL added = class_addMethod(cls, vwaSel, (IMP)adm_viewWillAppear, "v@:B");
            if (!added) {
                // Class has its own viewWillAppear: - swizzle it
                Method m = class_getInstanceMethod(cls, vwaSel);
                // But only if it's owned by this class (not superclass)
                unsigned int ownCount = 0;
                Method *ownMethods = class_copyMethodList(cls, &ownCount);
                for (unsigned j = 0; j < ownCount; j++) {
                    if (method_getName(ownMethods[j]) == vwaSel) {
                        gOrigVWA = method_getImplementation(m);
                        method_setImplementation(m, (IMP)adm_viewWillAppear);
                        break;
                    }
                }
                free(ownMethods);
            }
            NSLog(@"[ADMRotation] viewWillAppear hooked (added=%d)", added);
            break;
        }
        free(classes);
    }
}

