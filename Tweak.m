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

// Parse bundle ID from a file path like /…/com.example.app_123456.adbk
static NSString *bundleFromPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSString *fname = path.lastPathComponent;
    if (![fname hasSuffix:@".adbk"]) return nil;
    NSArray *parts = [fname componentsSeparatedByString:@"_"];
    if (parts.count >= 2 && [parts[0] containsString:@"."]) return parts[0];
    return nil;
}

// Find bundle ID from all known sources
static NSString *findBundleID(id vc, id model, UITableView *tv) {
    // 1. Standard key paths
    for (NSString *k in @[@"bundleId",@"bundleID",@"appBundleId",@"bundleIdentifier",@"appId"]) {
        @try { id v=[vc valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; } @catch(...){}
        @try { id v=[model valueForKey:k]; if([v isKindOfClass:[NSString class]]&&[(NSString*)v length])return v; } @catch(...){}
    }

    // 2. Try backupInfo — might be a string (bundle ID itself) or object
    id backupInfo = nil;
    @try { backupInfo = [vc valueForKey:@"backupInfo"]; } @catch (...) {}
    if ([backupInfo isKindOfClass:[NSString class]] && [(NSString*)backupInfo containsString:@"."]) {
        return (NSString *)backupInfo; // IS the bundle ID!
    }
    if (backupInfo) {
        for (NSString *k in @[@"bundleId",@"bundleID",@"bundleIdentifier"]) {
            @try { id v=[backupInfo valueForKey:k]; if([v isKindOfClass:[NSString class]])return v; } @catch(...){}
        }
    }

    // 3. Try selectedBackup — might contain a file path
    @try {
        id sel = [vc valueForKey:@"selectedBackup"];
        NSString *p = nil;
        if ([sel isKindOfClass:[NSString class]]) p = sel;
        else { @try { p = [sel valueForKey:@"path"]; } @catch (...) {} }
        if (p) { NSString *bid = bundleFromPath(p); if (bid) return bid; }
    } @catch (...) {}

    // 4. Check ALL string ivars of vc for something that looks like a bundle ID (has dots)
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(vc), &n);
    for (unsigned i = 0; i < n; i++) {
        NSString *iname = @(ivar_getName(ivars[i]) ?: "");
        NSString *key = [iname hasPrefix:@"_"] ? [iname substringFromIndex:1] : iname;
        @try {
            id val = [vc valueForKey:key];
            if ([val isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)val;
                // Looks like a bundle ID: has 2+ dots, no spaces, reasonable length
                if (s.length > 5 && [s containsString:@"."] && ![s containsString:@" "] &&
                    [[s componentsSeparatedByString:@"."] count] >= 2) {
                    free(ivars);
                    return s;
                }
            }
        } @catch (...) {}
    }
    free(ivars);

    // 4. Try _bInfo dict count — the VC stores bInfo = {count:N, icon:…}
    //    N = number of backups → match against .adbk file count per bundle ID
    @try {
        id bInfo = [vc valueForKey:@"bInfo"];
        if ([bInfo isKindOfClass:[NSDictionary class]]) {
            id countVal = ((NSDictionary *)bInfo)[@"count"];
            NSInteger bCount = [countVal integerValue];
            if (bCount > 0) {
                NSArray *files = [[NSFileManager defaultManager]
                                  contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
                NSMutableDictionary *counts = [NSMutableDictionary dictionary];
                for (NSString *f in files) {
                    if (![f hasSuffix:@".adbk"]) continue;
                    NSString *bid = [[f componentsSeparatedByString:@"_"] firstObject];
                    if (bid) counts[bid] = @([counts[bid] integerValue] + 1);
                }
                for (NSString *bid in counts) {
                    if ([counts[bid] integerValue] == bCount) return bid;
                }
            }
        }
    } @catch (...) {}

    // 5. Fallback: check each section separately
    if (tv) {
        NSArray *files = [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath:@"/var/mobile/Library/ADManager" error:nil];
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (NSString *f in files) {
            if (![f hasSuffix:@".adbk"]) continue;
            NSString *bid = [[f componentsSeparatedByString:@"_"] firstObject];
            if (bid) counts[bid] = @([counts[bid] integerValue] + 1);
        }
        NSInteger numSections = [tv numberOfSections];
        for (NSInteger s = 0; s < numSections; s++) {
            NSInteger rows = [tv numberOfRowsInSection:s];
            if (rows <= 0) continue;
            for (NSString *bid in counts) {
                if ([counts[bid] integerValue] == rows) return bid;
            }
        }
    }

    // 6. Last resort: show full ivar dump
    NSMutableString *dump = [NSMutableString string];
    unsigned int n2 = 0;
    Ivar *ivars2 = class_copyIvarList(object_getClass(vc), &n2);
    for (unsigned i = 0; i < n2; i++) {
        NSString *iname = @(ivar_getName(ivars2[i]) ?: "");
        NSString *key = [iname hasPrefix:@"_"] ? [iname substringFromIndex:1] : iname;
        @try {
            id val = [vc valueForKey:key];
            if (val) {
                NSString *desc = [NSString stringWithFormat:@"%@", val];
                NSUInteger len = desc.length > 50 ? 50 : desc.length;
                [dump appendFormat:@"%@: [%@] %@\n", iname, NSStringFromClass([val class]),
                 [desc substringToIndex:len]];
            }
        } @catch (...) {}
    }
    free(ivars2);
    if (backupInfo) [dump appendFormat:@"\nbackupInfo: [%@] %@", NSStringFromClass([backupInfo class]), backupInfo];
    popup(@"ADM VC Ivars (debug)", dump.length ? dump : @"(empty)");
    return nil;
}

static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch (...) {}
    if (!bundleID) {
        UITableView *tv = nil;
        @try { tv = [self valueForKey:@"tableView"]; } @catch (...) {}
        bundleID = findBundleID(self, model, tv);
    }
    if (!bundleID) return;
    objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<NSString *> *backups = sortedBackups(bundleID);
    if (!backups.count) { popup(@"ADM ✗", [NSString stringWithFormat:@"0 backup cho:\n%@", bundleID]); return; }

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

    popup(@"ADM Restoring ✓", [NSString stringWithFormat:@"#%ld/%lu\n%@\n%@",
        (long)(idx+1), (unsigned long)backups.count, chosen.lastPathComponent, bundleID]);

    if (model && [model respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(model, gRestoreSel, bundleID, chosen, nil, nil);
    else if ([self respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(self, gRestoreSel, bundleID, chosen, nil, nil);
}

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

static UITableViewCell *adm_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    UITableViewCell *cell = gOrigCellForRow ? gOrigCellForRow(self, _cmd, tv, ip) : nil;
    if (!objc_getAssociatedObject(self, kBtnKey)) injectButton(self, tv);
    return cell;
}

__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        gRestoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);
        Class vcClass = NSClassFromString(@"BackupInfoTableViewController");
        if (!vcClass) {
            unsigned int c = 0; Class *cls = objc_copyClassList(&c);
            for (unsigned i = 0; i < c; i++)
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

