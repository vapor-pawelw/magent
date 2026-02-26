#import <Cocoa/Cocoa.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        Class delegateClass = NSClassFromString(@"AppDelegate");
        if (delegateClass) {
            id delegate = [[delegateClass alloc] init];
            [app setDelegate:delegate];
        }

        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
