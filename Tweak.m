#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef UITableViewCell *(*CellForRowIMP)(id, SEL, UITableView *, NSIndexPath *);
static CellForRowIMP gOrigCellForRow = nil;

static const void *kBtnKey    = &kBtnKey;
static const void *kIdxKey    = &kIdxKey;
static const void *kBundleKey = &kBundleKey;

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

// ---- Auto-dismiss UIActionSheet (recursive search across all windows) ----



// ---- A-Z button tap ----
static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    if (!bundleID) return;

    NSArray<NSString *> *backups = sortedBackups(bundleID);
    if (!backups.count) return;

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

    // Get table view
    UITableView *tv = nil;
    @try { tv = [self valueForKey:@"tableView"]; } @catch (...) {}

    // Find the row for chosen backup (table: newest→oldest, our array: oldest→newest)
    NSIndexPath *targetIP = nil;
    if (tv) {
        for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
            NSInteger rows = [tv numberOfRowsInSection:s];
            if (rows == (NSInteger)backups.count) {
                NSInteger row = (NSInteger)backups.count - 1 - idx;
                if (row >= 0 && row < rows)
                    targetIP = [NSIndexPath indexPathForRow:row inSection:s];
                break;
            }
        }
    }
    if (!targetIP) return;

    // Simulate row tap → VC sets actionSheetItem with correct type + shows UIActionSheet
    typedef void (*DidSelectIMP)(id, SEL, UITableView *, NSIndexPath *);
    SEL didSelSel = @selector(tableView:didSelectRowAtIndexPath:);
    DidSelectIMP didSel = (DidSelectIMP)[[self class] instanceMethodForSelector:didSelSel];
    if (didSel) didSel(self, didSelSel, tv, targetIP);

    // Call restore after action sheet is set up
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SEL restoreSel = NSSelectorFromString(@"restore");
        if ([(id)self respondsToSelector:restoreSel])
            ((void(*)(id,SEL))objc_msgSend)((id)self, restoreSel);
        // Dismiss the action sheet silently
        dismissActionSheet();
    });
}

// ---- Inject button ----
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

