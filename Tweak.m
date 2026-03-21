#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- Type aliases ----
typedef UITableViewCell *(*CellForRowIMP)(id, SEL, UITableView *, NSIndexPath *);
typedef void (*RealRestoreIMP)(id, SEL, id, NSString *, id, id);

static CellForRowIMP  gOrigCellForRow  = nil;
static RealRestoreIMP gOrigRestoreApp  = nil;

// Captured from the last real restore invocation
static id        gLastRestoreTarget  = nil;  // BackupList instance
static id        gLastAppArg         = nil;  // whatever arg restoreApp: takes as first param
static id        gLastProgressBlk    = nil;  // progress block (may be nil)
static id        gLastCompletionBlk  = nil;  // completion block (exact type, reuse for A-Z)
static SEL       gRestoreSel;

// For button injection
static const void *kBtnKey    = &kBtnKey;
static const void *kIdxKey    = &kIdxKey;
static const void *kBundleKey = &kBundleKey;

// ---- Popup ----
static void popup(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = UIApplication.sharedApplication.windows.firstObject;
        if (!win.rootViewController) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *top = win.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:a animated:YES completion:nil];
    });
}

// ---- Sorted backup files ----
static NSArray<NSString *> *sortedBackups(NSString *bundleID) {
    NSArray *all = [[NSFileManager defaultManager]
                    contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
    if (!all) return @[];
    NSString *pfx = [bundleID stringByAppendingString:@"_"];
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *f in all)
        if ([f hasPrefix:pfx] && [f hasSuffix:@".adbk"])
            [r addObject:[@"/var/mobile/Library/ADManager" stringByAppendingPathComponent:f]];
    [r sortUsingSelector:@selector(compare:)];
    return r;
}

// ---- Bundle ID finder ----
static NSString *findBundleID(id vc, UITableView *tv) {
    // Try _bInfo dict count vs directory count
    @try {
        id bInfo = [vc valueForKey:@"bInfo"];
        if ([bInfo isKindOfClass:[NSDictionary class]]) {
            NSInteger bCount = [((NSDictionary *)bInfo)[@"count"] integerValue];
            if (bCount > 0) {
                NSArray *files = [[NSFileManager defaultManager]
                                  contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
                NSMutableDictionary *counts = [NSMutableDictionary dictionary];
                for (NSString *f in files) {
                    if (![f hasSuffix:@".adbk"]) continue;
                    NSString *bid = [[f componentsSeparatedByString:@"_"] firstObject];
                    if (bid) counts[bid] = @([counts[bid] integerValue] + 1);
                }
                for (NSString *bid in counts)
                    if ([counts[bid] integerValue] == bCount) return bid;
            }
        }
    } @catch (...) {}
    // Per-section fallback
    if (tv) {
        NSArray *files = [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (NSString *f in files) {
            if (![f hasSuffix:@".adbk"]) continue;
            NSString *bid = [[f componentsSeparatedByString:@"_"] firstObject];
            if (bid) counts[bid] = @([counts[bid] integerValue] + 1);
        }
        for (NSInteger s = 0; s < [tv numberOfSections]; s++)
            for (NSString *bid in counts)
                if ([counts[bid] integerValue] == [tv numberOfRowsInSection:s]) return bid;
    }
    return nil;
}

// ---- Hook: intercept the REAL BackupList.restoreApp: call ----
// This captures the app proxy and progress block used in normal restore flow
static void adm_interceptRestore(id self, SEL _cmd, id appArg, NSString *path, id progress, id completion) {
    // Silently capture ALL args — no UI to avoid conflict with restore flow
    gLastRestoreTarget  = self;
    gLastAppArg         = appArg;
    gLastProgressBlk    = progress;
    gLastCompletionBlk  = completion; // ← capture exact completion block type
    // Call original normally
    if (gOrigRestoreApp) gOrigRestoreApp(self, _cmd, appArg, path, progress, completion);
}

// ---- Button tap: A-Z rotation using captured args ----
static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    if (!bundleID) { popup(@"ADM ✗", @"No bundleID cached."); return; }

    if (!gLastRestoreTarget || !gLastAppArg) {
        popup(@"ADM ✗", @"Chưa có lần restore nào!\n\nHãy TAP vào 1 backup bất kỳ → Restore 1 lần để A-Z bắt đầu hoạt động.");
        return;
    }

    NSArray<NSString *> *backups = sortedBackups(bundleID);
    if (!backups.count) { popup(@"ADM ✗", @"Không có backup!"); return; }

    NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey);
    NSInteger idx  = idxN ? idxN.integerValue : 0;
    if (idx >= (NSInteger)backups.count) idx = 0;

    NSString *chosen = backups[(NSUInteger)idx];
    NSInteger next   = (idx + 1) % (NSInteger)backups.count;
    objc_setAssociatedObject(self, kIdxKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[NSUserDefaults standardUserDefaults] setInteger:next forKey:[@"ADMIdx_" stringByAppendingString:bundleID]];
    [[NSUserDefaults standardUserDefaults] synchronize];

    UIBarButtonItem *btn = objc_getAssociatedObject(self, kBtnKey);
    if (btn) btn.title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(next+1)];

    popup(@"ADM Restoring ✓", [NSString stringWithFormat:@"#%ld/%lu\n%@",
        (long)(idx+1), (unsigned long)backups.count, chosen.lastPathComponent]);

    // Replay with EXACT original completion block type — avoids block signature mismatch crash
    gOrigRestoreApp(gLastRestoreTarget, gRestoreSel, gLastAppArg, chosen, gLastProgressBlk, gLastCompletionBlk);
}

// ---- Button injection ----
static void injectButton(id self, UITableView *tv) {
    if (objc_getAssociatedObject(self, kBtnKey)) return;
    NSString *bundleID = findBundleID(self, tv);
    if (bundleID) {
        objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSInteger s = [[NSUserDefaults standardUserDefaults] integerForKey:[@"ADMIdx_" stringByAppendingString:bundleID]];
        objc_setAssociatedObject(self, kIdxKey, @(s), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *n = objc_getAssociatedObject(self, kIdxKey) ?: @0;
    NSString *title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(n.integerValue+1)];
    SEL actionSel = @selector(adm_restoreNext);
    if (![self respondsToSelector:actionSel])
        class_addMethod([self class], actionSel, (IMP)adm_restoreNext, "v@:");
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStylePlain
                                                          target:self action:actionSel];
    objc_setAssociatedObject(self, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UINavigationItem *nav = [(UIViewController *)self navigationItem];
    NSMutableArray *items = [NSMutableArray arrayWithArray:nav.rightBarButtonItems ?: @[]];
    [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIBarButtonItem *b, id _) {
        return ![b.title hasPrefix:@"Restore A-Z"];
    }]];
    [items insertObject:btn atIndex:0];
    nav.rightBarButtonItems = items;
}

// ---- cellForRowAtIndexPath: hook ----
static UITableViewCell *adm_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    UITableViewCell *cell = gOrigCellForRow ? gOrigCellForRow(self, _cmd, tv, ip) : nil;
    if (!objc_getAssociatedObject(self, kBtnKey)) injectButton(self, tv);
    return cell;
}

// ---- Constructor ----
__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        gRestoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);

        // Find BackupInfoTableViewController
        Class vcClass = NSClassFromString(@"BackupInfoTableViewController");
        if (!vcClass) {
            unsigned int c = 0; Class *cls = objc_copyClassList(&c);
            for (unsigned i = 0; i < c; i++)
                if (class_getInstanceMethod(cls[i], NSSelectorFromString(@"setSelectedBackup:")) &&
                    class_getInstanceMethod(cls[i], NSSelectorFromString(@"setBackupList:")))
                    { vcClass = cls[i]; break; }
            free(cls);
        }

        // Find BackupList and hook restoreApp:
        Class blClass = NSClassFromString(@"BackupList");

        if (vcClass) {
            class_addMethod(vcClass, @selector(adm_restoreNext), (IMP)adm_restoreNext, "v@:");
            Method m = class_getInstanceMethod(vcClass, @selector(tableView:cellForRowAtIndexPath:));
            if (m) { gOrigCellForRow = (CellForRowIMP)method_getImplementation(m); method_setImplementation(m, (IMP)adm_cellForRow); }
        }

        if (blClass) {
            Method rm = class_getInstanceMethod(blClass, gRestoreSel);
            if (rm) {
                gOrigRestoreApp = (RealRestoreIMP)method_getImplementation(rm);
                method_setImplementation(rm, (IMP)adm_interceptRestore);
            }
        }
    }
}

