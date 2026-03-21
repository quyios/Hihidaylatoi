#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef UITableViewCell *(*CellForRowIMP)(id, SEL, UITableView *, NSIndexPath *);
static CellForRowIMP gOrigCellForRow = nil;

static const void *kBtnKey    = &kBtnKey;
static const void *kIdxKey    = &kIdxKey;
static const void *kBundleKey = &kBundleKey;

#pragma mark - BundleID

static NSString *findBundleID(id vc) {
    @try {
        id bInfo = [vc valueForKey:@"bInfo"];
        if ([bInfo isKindOfClass:[NSDictionary class]]) {
            return bInfo[@"bundleID"];
        }
    } @catch (...) {}
    return nil;
}

#pragma mark - Restore (OPTIMIZED)

static void adm_restoreNext(id self, SEL _cmd) {
    NSString *bundleID = objc_getAssociatedObject(self, kBundleKey);
    if (!bundleID) return;

    // ✅ Lấy model trực tiếp (KHÔNG đụng UI)
    NSArray *list = nil;
    @try {
        list = [self valueForKey:@"backupList"];
    } @catch (...) {}

    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return;

    NSNumber *idxN = objc_getAssociatedObject(self, kIdxKey);
    NSInteger idx = idxN ? idxN.integerValue : 0;
    if (idx >= list.count) idx = 0;

    // ⚠️ đảo index (UI là newest → oldest)
    NSInteger realIndex = list.count - 1 - idx;

    id chosenObj = list[realIndex];
    if (!chosenObj) return;

    NSInteger next = (idx + 1) % list.count;
    objc_setAssociatedObject(self, kIdxKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [[NSUserDefaults standardUserDefaults] setInteger:next
                                               forKey:[@"ADMIdx_" stringByAppendingString:bundleID]];

    // Update button title
    UIBarButtonItem *btn = objc_getAssociatedObject(self, kBtnKey);
    if (btn) {
        btn.title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(next + 1)];
    }

    // ✅ setSelectedBackup (internal API)
    SEL setSel = NSSelectorFromString(@"setSelectedBackup:");
    if ([self respondsToSelector:setSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(self, setSel, chosenObj);
    } else {
        @try {
            [self setValue:chosenObj forKey:@"selectedBackup"];
        } @catch (...) {}
    }

    // ✅ restore trực tiếp (KHÔNG delay, KHÔNG UI)
    SEL restoreSel = NSSelectorFromString(@"restore");
    if ([self respondsToSelector:restoreSel]) {
        ((void(*)(id,SEL))objc_msgSend)(self, restoreSel);
    }
}

#pragma mark - Inject Button

static void injectButton(id self) {
    if (objc_getAssociatedObject(self, kBtnKey)) return;

    NSString *bundleID = findBundleID(self);
    if (bundleID) {
        objc_setAssociatedObject(self, kBundleKey, bundleID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSInteger saved = [[NSUserDefaults standardUserDefaults]
                           integerForKey:[@"ADMIdx_" stringByAppendingString:bundleID]];
        objc_setAssociatedObject(self, kIdxKey, @(saved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSNumber *n = objc_getAssociatedObject(self, kIdxKey) ?: @0;
    NSString *title = [NSString stringWithFormat:@"Restore A-Z (%ld)", (long)(n.integerValue + 1)];

    SEL actionSel = @selector(adm_restoreNext);
    if (![self respondsToSelector:actionSel]) {
        class_addMethod([self class], actionSel, (IMP)adm_restoreNext, "v@:");
    }

    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:title
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:actionSel];

    objc_setAssociatedObject(self, kBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UINavigationItem *nav = [(UIViewController *)self navigationItem];
    NSMutableArray *items = [NSMutableArray arrayWithArray:nav.rightBarButtonItems ?: @[]];

    [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIBarButtonItem *b, id _) {
        return ![b.title hasPrefix:@"Restore A-Z"];
    }]];

    [items insertObject:btn atIndex:0];
    nav.rightBarButtonItems = items;
}

#pragma mark - Hook cellForRow

static UITableViewCell *adm_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    UITableViewCell *cell = gOrigCellForRow ? gOrigCellForRow(self, _cmd, tv, ip) : nil;

    if (!objc_getAssociatedObject(self, kBtnKey)) {
        injectButton(self);
    }

    return cell;
}

#pragma mark - Init

__attribute__((constructor))
static void ADMInit(void) {
    @autoreleasepool {

        Class vcClass = NSClassFromString(@"BackupInfoTableViewController");

        if (!vcClass) {
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);

            for (unsigned int i = 0; i < count; i++) {
                if (class_getInstanceMethod(classes[i], NSSelectorFromString(@"setSelectedBackup:")) &&
                    class_getInstanceMethod(classes[i], NSSelectorFromString(@"setBackupList:"))) {
                    vcClass = classes[i];
                    break;
                }
            }

            free(classes);
        }

        if (!vcClass) return;

        class_addMethod(vcClass, @selector(adm_restoreNext), (IMP)adm_restoreNext, "v@:");

        Method m = class_getInstanceMethod(vcClass, @selector(tableView:cellForRowAtIndexPath:));
        if (m) {
            gOrigCellForRow = (CellForRowIMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)adm_cellForRow);
        }
    }
}
