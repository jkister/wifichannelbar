#import <dlfcn.h>
#include <math.h>
#include <CoreFoundation/CoreFoundation.h>
#include <MobileWiFi/MobileWiFi.h>
#include <UIKit/UIKit.h>
#include "LSStatusBarItem.h"
#include "Reachability.h"

static void *wifiLibHandle;
static void *libstatusbar;

WiFiManagerRef manager;
CFArrayRef devices;
WiFiDeviceClientRef client;

BOOL error = NO;
NSString *errorString;

WiFiManagerRef (*wifiManagerClientCreate)(CFAllocatorRef, int);
CFArrayRef (*wifiManagerClientCopyDevices)(WiFiManagerRef);
WiFiNetworkRef (*wifiDeviceClientCopyCurrentNetwork)(WiFiDeviceClientRef);
WiFiNetworkRef (*wifiNetworkGetProperty)(WiFiNetworkRef, CFStringRef);

#ifndef kCFCoreFoundationVersionNumber_iOS_10_0
    #define kCFCoreFoundationVersionNumber_iOS_10_0 1348.00
#endif

#ifndef kCFNumberIntType
    #define kCFNumberIntType 9
#endif

%ctor
{
    HBLogDebug(@"Tweak loaded");
    wifiLibHandle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_NOW);
    libstatusbar = dlopen("/Library/MobileSubstrate/DynamicLibraries/libstatusbar.dylib", RTLD_NOW);
    if(!libstatusbar)
    {
        errorString = [NSString stringWithFormat:@"Error loading libstatusbar: %s", dlerror()];
        HBLogError(@"%@", errorString);
        error = YES;
    }

    *(void **) (&wifiManagerClientCreate) = dlsym(wifiLibHandle, "WiFiManagerClientCreate");
    *(void **) (&wifiManagerClientCopyDevices) = dlsym(wifiLibHandle, "WiFiManagerClientCopyDevices");
    *(void **) (&wifiDeviceClientCopyCurrentNetwork) = dlsym(wifiLibHandle, "WiFiDeviceClientCopyCurrentNetwork");
    *(void **) (&wifiNetworkGetProperty) = dlsym(wifiLibHandle, "WiFiNetworkGetProperty");

    manager = (*wifiManagerClientCreate)(kCFAllocatorDefault, 0);
    if(!manager)
    {
        HBLogError(@"Error initiating WiFiManagerClient");
        return;
    }

    devices = (*wifiManagerClientCopyDevices)(manager);
    if(!devices)
    {
        HBLogError(@"Error getting WiFiManagerClient devices");
        return;
    }

    client = (WiFiDeviceClientRef)CFArrayGetValueAtIndex(devices, 0);
    if(!client)
    {
        HBLogError(@"Error initiating WiFiDeviceClient");
        return;
    }
    HBLogDebug(@"Ctor done");
}

@interface SpringBoard

@property (nonatomic, retain) NSTimer *wifiTimer;
@property (assign) LSStatusBarItem *sbItem;
@property (assign) NSString *imagePrefix;
@property (assign) int currentChannel;
@property (assign) int wifiLock;

- (void) wifiTimerFired:(NSTimer*)timer;

@end

%hook SpringBoard

%property (nonatomic, retain) NSTimer *wifiTimer;
%property (assign) LSStatusBarItem *sbItem;
%property (assign) NSString *imagePrefix;
%property (assign) int currentChannel;
%property (assign) int wifiLock;

%new
- (void) wifiTimerFired:(NSTimer*)timer
{
    WiFiNetworkRef network = (*wifiDeviceClientCopyCurrentNetwork)(client);
    if(!network)
    {
        HBLogError(@"Error initiating WiFiNetwork");
        return;
    }

    CFNumberRef networkChannel = (CFNumberRef) (*wifiNetworkGetProperty)(network, CFSTR("CHANNEL"));
    if(!networkChannel)
    {
        HBLogError(@"Error getting WiFiNetwork property CHANNEL");
        return;
    }

    int channel;
    NSString* imageString = [NSString stringWithFormat:@"%@", self.imagePrefix];
    NSString* channelString;

    @try {
        CFNumberGetValue(networkChannel, kCFNumberIntType, &channel);
    }
    @catch (NSException* exception) {
        HBLogError(@"Couldn't find channel: %@", exception.reason);
        return;
    }
    if(channel != self.currentChannel)
    {
        @try {
            self.currentChannel = channel;

            channelString = [@(channel) stringValue];
            imageString = [imageString stringByAppendingString:channelString];

            self.sbItem.visible = YES;
            self.sbItem.imageName = imageString;
            HBLogDebug(@"Statusbar icon loaded");
        }
        @catch (NSException* exception) {
            HBLogError(@"Icon couldn't be loaded properly: %@", exception.reason);
        }
    }
}

- (void) applicationDidFinishLaunching:(id)arg1
{
    self.wifiTimer = nil;
    self.wifiLock = 0;

    if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_10_0)
    {
        self.imagePrefix = @"WCB_";
    }
    else
    {
        self.imagePrefix = @"WCB9_";
    }
    HBLogDebug(@"Image prefix: %@", self.imagePrefix);
    %orig;

    if(!error)
    {
        self.sbItem = [[objc_getClass("LSStatusBarItem") alloc] initWithIdentifier:@"cloud.janbures.wifichannelbar" alignment:StatusBarAlignmentLeft];
        Reachability* reach = [Reachability reachabilityWithHostname:@"www.google.com"];
        reach.reachableOnWWAN = NO;

        reach.reachableBlock = ^(Reachability*reach)
        {
            if(self.wifiLock == 0)
            {
                self.wifiLock = 1;

                HBLogDebug(@"Reachable, unlocked, locking");

                dispatch_async(dispatch_get_main_queue(), ^{
                    if(self.wifiTimer != nil)
                    {
                        [self.wifiTimer invalidate];
                        self.wifiTimer = nil;
                        HBLogDebug(@"Invalidated timer");
                    }
                    self.wifiTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(wifiTimerFired:) userInfo:nil repeats:YES];
                    self.wifiLock = 0;

                    HBLogDebug(@"Unlocking");
                });
            }
            else
            {
                HBLogDebug(@"Reachable, locked");
            }
        };

        reach.unreachableBlock = ^(Reachability*reach)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                if(self.wifiTimer != nil)
                {
                    [self.wifiTimer invalidate];
                    self.wifiTimer = nil;
                }
                self.currentChannel = -1;
                self.sbItem.visible = NO;
                HBLogDebug(@"Wifi disconnected");
            });
        };

        [reach startNotifier];
    }
    else
    {
        HBLogDebug(@"Error");
        UIWindow* topWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        topWindow.rootViewController = [UIViewController new];
        topWindow.windowLevel = UIWindowLevelAlert + 1;

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"WifiChannelBar9" message:errorString preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            [alert dismissViewControllerAnimated:YES completion:nil];
            topWindow.hidden = YES;
        }]];

        [topWindow makeKeyAndVisible];
        [topWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    }
    HBLogDebug(@"End of application did finish launching");
}
%end
