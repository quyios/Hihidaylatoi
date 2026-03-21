#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef void (*RestoreIMP)(id, SEL, NSString *, NSString *, id, id);
typedef UITableViewCell *(*CellForRowIMP)(id, SEL, UITableView *, NSIndexPath *);

static CellForRowIMP gOrigCellForRow = nil;
static SEL gRestoreSel;

static const void *kBtnKey    = &kBtnKey;
static const void *kIdxKey    = &kIdxKey;
static const void *kBundleKey = &kBundleKey;

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

// ---- Sorted backups ----
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

// ---- Dump all ivar string values of an object ----
static NSDictionary *ivarDump(id obj) {
    if (!obj) return @{};
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(obj), &n);
    for (unsigned i = 0; i < n; i++) {
        NSString *name = @(ivar_getName(ivars[i]) ?: "?");
        NSString *stripped = [name hasPrefix:@"_"] ? [name substringFromIndex:1] : name;
        @try {
            id val = [obj valueForKey:stripped];
            if (val) d[name] = [NSString stringWithFormat:@"%@", val];
        } @catch (...) {}
    }
    free(ivars);
    return d;
}

// ---- Find bundle ID ----
static NSString *findBundleID(id vc, id model, UITableView *tv) {
    // 1. Try key paths on vc
    for (NSString *k in @[@"bundleId",@"bundleID",@"appBundleId",@"bundleIdentifier",@"appId",@"appID"]) {
        @try { id v=[vc valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; } @catch(...){}
    }
    // 2. Try via backupInfo sub-object
    @try {
        id info = [vc valueForKey:@"backupInfo"];
        if (info) {
            for (NSString *k in @[@"bundleId",@"bundleID",@"bundleIdentifier"]) {
                @try { id v=[info valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; } @catch(...){}
            }
        }
    } @catch (...) {}
    // 3. Try key paths on model
    if (model) {
        for (NSString *k in @[@"bundleId",@"bundleID",@"appBundleId",@"bundleIdentifier"]) {
            @try { id v=[model valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; } @catch(...){}
        }
    }
    // 4. Fallback: match table row count against .adbk file count per bundle ID
    if (tv) {
        NSInteger rows = [tv numberOfRowsInSection:0];
        if (rows > 0) {
            NSArray *files = [[NSFileManager defaultManager]
                              contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
            NSMutableDictionary *counts = [NSMutableDictionary dictionary];
            for (NSString *f in files) {
                if (![f hasSuffix:@".adbk"]) continue;
                NSString *bid = [[f componentsSeparatedByString:@"_"] firstObject];
                if (bid) counts[bid] = @([counts[bid] integerValue] + 1);
            }
            for (NSString *bid in counts) {
                if ([counts[bid] integerValue] == rows) return bid;
            }
            // If no exact match, return the one with closest count
            // but also show all in popup for debug
            NSMutableString *dbg = [NSMutableString stringWithFormat:@"Table rows: %ld\n", (long)rows];
            for (NSString *bid in counts)
                [dbg appendFormat:@"%@ → %@\n", bid, counts[bid]];
            popup(@"ADM Bundle Candidates", dbg);
        }
    }
    // 5. Last resort: dump VC ivars and show popup
    NSDictionary *dump = ivarDump(vc);
    NSMutableString *str = [NSMutableString string];
    for (NSString *k in dump) [str appendFormat:@"%@=%@\n", k, dump[k]];
    popup(@"ADM VC Ivars (debug)", str.length ? str : @"(empty)");
    return nil;
}

// ---- Button tap ----
static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch (...) {}

    if (!bundleID) {
        UITableView *tv = nil;
        @try { tv = [self valueForKey:@"tableView"]; } @catch (...) {}
        bundleID = findBundleID(self, model, tv);
    }
    if (!bundleID) { popup(@"ADM ✗", @"Không tìm được Bundle ID!\nXem popup VC Ivars để debug."); return; }
    objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<NSString *> *backups = sortedBackups(bundleID);
    if (!backups.count) { popup(@"ADM ✗", [NSString stringWithFormat:@"Không có backup cho:\n%@", bundleID]); return; }

    NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey);
    NSInteger idx = idxN ? idxN.integerValue : 0;
    if (idx >= (NSInteger)backups.count) idx = 0;

    NSString *chosen = backups[(NSUInteger)idx];
    NSInteger next = (idx + 1) % (NSInteger)backups.count;
    objc_setAssociatedObject(self, kIdxKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[NSUserDefaults standardUserDefaults] setInteger:next forKey:[@"ADMIdx_" stringByAppendingString:bundleID]];
    [[NSUserDefaults standardUserDefaults] synchronize];

    UIBarButtonItem *btn = objc_getAssociatedObject(self, kBtnKey);
    if (btn) btn.title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(next+1)];

    popup(@"ADM Restoring ✓", [NSString stringWithFormat:@"#%ld/%lu\n%@\nBundle: %@",
        (long)(idx+1), (unsigned long)backups.count, chosen.lastPathComponent, bundleID]);

    if (model && [model respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(model, gRestoreSel, bundleID, chosen, nil, nil);
    else if ([self respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(self, gRestoreSel, bundleID, chosen, nil, nil);
}

// ---- Inject button ----
static void injectButton(id self, UITableView *tv) {
    if (objc_getAssociatedObject(self, kBtnKey)) return;

    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch (...) {}
    NSString *bundleID = findBundleID(self, model, tv);
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

    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:title
                                                           style:UIBarButtonItemStylePlain
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
        Class vcClass = NSClassFromString(@"BackupInfoTableViewController");
        if (!vcClass) {
            unsigned int count = 0; Class *cls = objc_copyClassList(&count);
            for (unsigned i = 0; i < count; i++)
                if (class_getInstanceMethod(cls[i], NSSelectorFromString(@"setSelectedBackup:")) &&
                    class_getInstanceMethod(cls[i], NSSelectorFromString(@"setBackupList:")))
                    { vcClass = cls[i]; break; }
            free(cls);
        }
        if (!vcClass) return;
        class_addMethod(vcClass, @selector(adm_restoreNext), (IMP)adm_restoreNext, "v@:");
        Method m = class_getInstanceMethod(vcClass, @selector(tableView:cellForRowAtIndexPath:));
        if (m) { gOrigCellForRow = (CellForRowIMP)method_getImplementation(m); method_setImplementation(m, (IMP)adm_cellForRow); }
    }
}

