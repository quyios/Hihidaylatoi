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

// ---- Alert helper ----
static void popup(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = UIApplication.sharedApplication.windows.firstObject;
        if (!win.rootViewController) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *top = win.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:a animated:YES completion:nil];
    });
}

// ---- Backup helpers ----
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

static NSString *getBundleID(id obj) {
    if (!obj) return nil;
    for (NSString *k in @[@"bundleId", @"bundleID", @"appBundleId", @"bundleIdentifier"]) {
        @try {
            id v = [obj valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (...) {}
    }
    return nil;
}

// ---- Button tap ----
static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch (...) {}
    if (!bundleID) bundleID = getBundleID(model) ?: getBundleID(self);
    if (!bundleID) { popup(@"ADM ✗", @"Không tìm được Bundle ID!"); return; }

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
    if (btn) btn.title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(next + 1)];

    popup(@"ADM Restoring ✓", [NSString stringWithFormat:@"Backup #%ld/%lu\n%@",
        (long)(idx+1), (unsigned long)backups.count, chosen.lastPathComponent]);

    if (model && [model respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(model, gRestoreSel, bundleID, chosen, nil, nil);
    else if ([self respondsToSelector:gRestoreSel])
        ((RestoreIMP)objc_msgSend)(self, gRestoreSel, bundleID, chosen, nil, nil);
}

// ---- Inject button into nav bar ----
static void injectButton(id self) {
    if (objc_getAssociatedObject(self, kBtnKey)) return;

    // Get bundleID
    id model = nil;
    @try { model = [self valueForKey:@"backupList"]; } @catch (...) {}
    NSString *bundleID = getBundleID(model) ?: getBundleID(self);
    if (bundleID) {
        objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSInteger s = [[NSUserDefaults standardUserDefaults] integerForKey:[@"ADMIdx_" stringByAppendingString:bundleID]];
        objc_setAssociatedObject(self, kIdxKey, @(s), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSNumber *n = objc_getAssociatedObject(self, kIdxKey) ?: @0;
    NSString *title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(n.integerValue + 1)];

    SEL actionSel = @selector(adm_restoreNext);
    if (![self respondsToSelector:actionSel])
        class_addMethod([self class], actionSel, (IMP)adm_restoreNext, "v@:");

    UIBarButtonItem *btn = [[UIBarButtonItem alloc]
        initWithTitle:title style:UIBarButtonItemStylePlain target:self action:actionSel];
    objc_setAssociatedObject(self, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UINavigationItem *nav = [(UIViewController *)self navigationItem];
    NSMutableArray *items = [NSMutableArray arrayWithArray:nav.rightBarButtonItems ?: @[]];
    [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIBarButtonItem *b, id _) {
        return ![b.title hasPrefix:@"Restore A-Z"];
    }]];
    [items insertObject:btn atIndex:0];
    nav.rightBarButtonItems = items;
}

// ---- cellForRowAtIndexPath: hook — guaranteed to fire when table is visible ----
static UITableViewCell *adm_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    UITableViewCell *cell = nil;
    if (gOrigCellForRow) cell = gOrigCellForRow(self, _cmd, tv, ip);
    // Inject button only once
    if (!objc_getAssociatedObject(self, kBtnKey)) {
        injectButton(self);
        popup(@"ADM Hook Fired ✓", [NSString stringWithFormat:@"cellForRow hoạt động!\nClass: %@",
            NSStringFromClass([self class])]);
    }
    return cell;
}

// ---- Constructor ----
__attribute__((constructor))
static void ADMRotationInit(void) {
    @autoreleasepool {
        gRestoreSel = @selector(restoreApp:fromPathBackup:progress:withCompletion:);

        // Find class
        Class vcClass = NSClassFromString(@"BackupInfoTableViewController");

        // Fallback: find by having setSelectedBackup: + setBackupList:
        if (!vcClass) {
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);
            for (unsigned int i = 0; i < count; i++) {
                Class cls = classes[i];
                if (class_getInstanceMethod(cls, NSSelectorFromString(@"setSelectedBackup:")) &&
                    class_getInstanceMethod(cls, NSSelectorFromString(@"setBackupList:"))) {
                    vcClass = cls; break;
                }
            }
            free(classes);
        }

        // Popup 1: startup
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (vcClass) {
                // Dump all own methods of the class for diagnostics
                unsigned int mc = 0;
                Method *methods = class_copyMethodList(vcClass, &mc);
                NSMutableArray *names = [NSMutableArray array];
                for (unsigned i = 0; i < mc && i < 20; i++)
                    [names addObject:NSStringFromSelector(method_getName(methods[i]))];
                free(methods);
                popup(@"ADM ✓ Class Found",
                    [NSString stringWithFormat:@"%@\n\nMethods (%u):\n%@",
                     NSStringFromClass(vcClass), mc,
                     [names componentsJoinedByString:@"\n"]]);
            } else {
                popup(@"ADM ✗", @"Không tìm được class!\nCả 2 strategy đều thất bại.");
            }
        });

        if (!vcClass) return;

        // Add button action
        class_addMethod(vcClass, @selector(adm_restoreNext), (IMP)adm_restoreNext, "v@:");

        // Hook cellForRowAtIndexPath: — GUARANTEED to be called when the table shows
        SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
        Method cellM = class_getInstanceMethod(vcClass, cellSel);
        if (cellM) {
            gOrigCellForRow = (CellForRowIMP)method_getImplementation(cellM);
            method_setImplementation(cellM, (IMP)adm_cellForRow);
        }
    }
}

