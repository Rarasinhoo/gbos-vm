#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <ImageIO/ImageIO.h>
#import <notify.h>
#import "CocoaSpice.h"
#import "CSDisplay+Protected.h"
#import "CSMetalRenderer.h"
#import "webcam.h"
#import "microphone.h"
#import "bluetooth.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <CommonCrypto/CommonHMAC.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// The downloadable app carries the VM engine in Resources/runtime, its own Python included (a Mac
// without Xcode's tools has no usable python3); a build from source uses the system's.
static NSString *bundledPython(void) {
 NSString *p=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"runtime/python/bin/python3"];
 return [[NSFileManager defaultManager] isExecutableFileAtPath:p]?p:@"/usr/bin/python3";
}
static BOOL isDownloadedApp(void) {return [[NSFileManager defaultManager] fileExistsAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"runtime/manifest.json"]];}
// Where the VM lives: GOOGLEBOOK_WORK; a build from source sits in its work folder
// (WORK/host/Googlebook VM.app) or recorded it; the downloadable app keeps it in Application Support.
static NSString *workFolder(void) {
 const char *e=getenv("GOOGLEBOOK_WORK");if(e&&*e)return @(e);
 NSBundle *b=NSBundle.mainBundle;
 NSString *beside=[[b.bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
 if([[NSFileManager defaultManager] fileExistsAtPath:[beside stringByAppendingPathComponent:@"image/googlebook.raw"]])return beside;
 NSString *recorded=[b objectForInfoDictionaryKey:@"GBOSWork"];if(recorded.length)return recorded;
 return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Googlebook VM"];
}
// The SPICE libraries come from UTM, which setup downloads (nothing of UTM's is redistributed):
// the app links them weakly, so it starts without them, and loaded only when they're there.
static BOOL spiceLoaded(void) {return dlsym(RTLD_DEFAULT,"spice_session_new")!=NULL;}
#include <errno.h>
#include <fcntl.h>
#include <sys/sysctl.h>
#include <net/route.h>
#include <net/if_dl.h>

static unsigned short scan[128] = {
 [0]=0x1e,[1]=0x1f,[2]=0x20,[3]=0x21,[4]=0x23,[5]=0x22,[6]=0x2c,[7]=0x2d,[8]=0x2e,[9]=0x2f,[10]=0x56,[11]=0x30,
 [12]=0x10,[13]=0x11,[14]=0x12,[15]=0x13,[16]=0x15,[17]=0x14,[18]=2,[19]=3,[20]=4,[21]=5,[22]=7,[23]=6,
 [24]=0x0d,[25]=0x0a,[26]=8,[27]=0x0c,[28]=9,[29]=0x0b,[30]=0x1b,[31]=0x18,[32]=0x16,[33]=0x1a,[34]=0x17,[35]=0x19,
 [36]=0x1c,[37]=0x26,[38]=0x24,[39]=0x28,[40]=0x25,[41]=0x27,[42]=0x2b,[43]=0x33,[44]=0x35,[45]=0x31,[46]=0x32,[47]=0x34,
 [48]=0x0f,[49]=0x39,[50]=0x29,[51]=0x0e,[53]=1,[55]=0x15b,[54]=0x15c,[56]=0x2a,[60]=0x36,[58]=0x38,[61]=0x138,[59]=0x1d,[62]=0x11d,
 [65]=0x53,[67]=0x37,[69]=0x4e,[75]=0x135,[76]=0x11c,[78]=0x4a,[82]=0x52,[83]=0x4f,[84]=0x50,[85]=0x51,[86]=0x4b,[87]=0x4c,[88]=0x4d,[89]=0x47,[91]=0x48,[92]=0x49,
 [72]=0x130,[73]=0x12e,[74]=0x120,[114]=0x152,
 [96]=0x3f,[97]=0x40,[98]=0x41,[99]=0x3d,[100]=0x42,[101]=0x43,[103]=0x57,[109]=0x44,[111]=0x58,[115]=0x147,[116]=0x149,[117]=0x153,[118]=0x3e,[119]=0x14f,[120]=0x3c,[121]=0x151,[122]=0x3b,[123]=0x14b,[124]=0x14d,[125]=0x150,[126]=0x148
};
@interface VMView : MTKView
- (void)setHostCursorHidden:(BOOL)hidden;
- (void)refreshHostCursor;
- (void)moveBy:(CGPoint)points;
- (void)sendPadContacts:(NSArray<NSArray<NSNumber *> *> *)contacts;
- (BOOL)padActive;
- (void)resetTouchpad;
@property(nonatomic) BOOL touchpadReady;   // the guest has a virtual touchpad for the Mac trackpad
@property(nonatomic) BOOL touchpadAsked;
@property(nonatomic) NSUInteger fingers;   // contacts now on the Mac trackpad
@property(nonatomic) BOOL wheelReady;      // the guest has a high-resolution scroll wheel
@property(nonatomic) CGPoint wheelCarry;   // scrolling not sent yet, under 1/120 of a notch
@property(nonatomic,strong) CSInput *input;
@property(nonatomic) BOOL captured;
@property(nonatomic) BOOL inside;
@property(nonatomic) BOOL cursorHidden, cursorWanted;
@property(nonatomic) CSInputButton buttons;
@property(nonatomic) CGSize guestSize;
@property(nonatomic) CGPoint carry;     // captured mouse: motion not sent yet, under one guest pixel
@property(nonatomic,strong) NSMutableDictionary *touchIds;  // NSTouch identity -> small id for the guest
@property(nonatomic) int nextTouchId, padButton;
@property(nonatomic,strong) NSArray *padContacts;
@property(nonatomic,strong) NSDictionary *twoFingerStart;   // where two fingers came down, to tell a tap from a gesture           // the last contacts sent, for button changes
@property(nonatomic,strong) NSTrackingArea *tracking;
// Absolute mode: the helper inside Android puts Android's own pointer exactly where the Mac
// cursor is (hidden over the window), so it moves in and out of the window freely.
@property(nonatomic) BOOL absolute;
// An Android app holds pointer capture (wantsLock) and the Mac mouse is locked for it (locked):
// motion goes to the helper's relative mouse instead.
@property(nonatomic) BOOL wantsLock, locked;
// NO while waiting for the helper: moving the emulated USB mouse at all leaves a second,
// frozen Android cursor on screen once the helper takes over.
@property(nonatomic) BOOL relativeAllowed;
@property(nonatomic,copy) void (^sendLine)(NSString *);
- (void)releaseCapture;
@end
@implementation VMView
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)acceptsFirstMouse:(NSEvent *)event{return YES;}
- (void)updateTrackingAreas {
 [super updateTrackingAreas];
 if(self.tracking)[self removeTrackingArea:self.tracking];
 self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
 [self addTrackingArea:self.tracking];
}
// Hiding the Mac cursor holds for the whole screen while this app is active, so it stays hidden
// only while this window has the focus: a macOS prompt, a password dialog or a sheet in front
// gets the cursor back (the window stops hearing about the mouse once it isn't key).
- (void)setHostCursorHidden:(BOOL)hidden {self.cursorWanted=hidden;[self refreshHostCursor];}
- (void)refreshHostCursor {
 BOOL hidden=self.cursorWanted&&self.window.isKeyWindow&&NSApp.isActive;
 if(hidden==self.cursorHidden)return;
 self.cursorHidden=hidden;if(hidden)[NSCursor hide];else [NSCursor unhide];
}
// Where a Mac pointer event falls on the guest screen, in guest pixels.
- (CGPoint)guestPoint:(NSEvent *)e {
 CGPoint p=[self convertPoint:e.locationInWindow fromView:nil];CGSize b=self.bounds.size,g=self.guestSize;
 CGFloat s=MIN(b.width/g.width,b.height/g.height);if(s<=0)s=1;
 CGFloat x=(p.x-(b.width-g.width*s)/2)/s,y=(b.height-p.y-(b.height-g.height*s)/2)/s;
 return CGPointMake(MAX(0,MIN(g.width-1,x)),MAX(0,MIN(g.height-1,y)));
}
// Over the window, Android's own pointer is the one to see (it has the shapes apps ask for).
- (void)mouseEntered:(NSEvent *)e {if(self.absolute){self.inside=YES;[self setHostCursorHidden:YES];}}
- (void)mouseExited:(NSEvent *)e {if(self.absolute&&!self.locked){self.inside=NO;[self setHostCursorHidden:NO];self.sendLine(@"X");}}
// Lock the Mac mouse for the Android app that asked for pointer capture: only while this window
// is in front with the pointer over it, so an app in the background can't take the mouse away.
- (void)lockForApp {
 if(self.locked||!self.wantsLock||!self.absolute||!self.window.isKeyWindow)return;
 if(!NSPointInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil],self.bounds))return;
 self.locked=YES;self.carry=CGPointZero;[self.window makeFirstResponder:self];
 CGAssociateMouseAndMouseCursorPosition(false);[self setHostCursorHidden:YES];self.sendLine(@"Q 1");
 [NSApp.delegate performSelector:@selector(updateSubtitle)];
}
- (void)unlock {
 if(!self.locked)return;
 self.locked=NO;self.sendLine(@"Q 0");CGAssociateMouseAndMouseCursorPosition(true);[self setHostCursorHidden:self.inside];
 [NSApp.delegate performSelector:@selector(updateSubtitle)];
}
- (void)capture {
 if(!self.relativeAllowed)return;
 if(!self.captured && self.input){self.captured=YES;[self.window makeFirstResponder:self];[self.input requestMouseMode:YES];CGAssociateMouseAndMouseCursorPosition(false);[NSCursor hide];self.window.subtitle=@"Mouse captured • ⌃⌥ releases";}
}
- (void)releaseCapture {
 [self unlock];
 if(self.touchpadReady&&(self.padContacts.count||self.padButton)){self.padButton=0;[self sendPadContacts:@[]];}
 [self.input releaseKeys];
 for(NSNumber *b in @[@(kCSInputButtonLeft),@(kCSInputButtonRight),@(kCSInputButtonMiddle)]) [self.input sendMouseButton:b.unsignedIntegerValue mask:0 pressed:NO];
 self.buttons=0;
 if(self.captured){self.captured=NO;CGAssociateMouseAndMouseCursorPosition(true);[NSCursor unhide];[NSApp.delegate performSelector:@selector(updateSubtitle)];}
}
- (BOOL)live {return self.absolute||self.captured;}
- (void)button:(CSInputButton)b down:(BOOL)down event:(NSEvent *)e {
 int code=b==kCSInputButtonLeft?1:(b==kCSInputButtonRight?2:4);
 if(self.locked){self.sendLine([NSString stringWithFormat:@"%c %d",down?'D':'U',code]);return;}
 // Released with ⌃⌥ while the app still holds capture: a click back in locks again.
 if(self.absolute&&self.wantsLock&&down){[self lockForApp];if(self.locked)return;}
 if(self.absolute){
  [self.window makeFirstResponder:self];CGPoint g=[self guestPoint:e];
  self.sendLine([NSString stringWithFormat:@"M %.1f %.1f",g.x,g.y]);self.sendLine([NSString stringWithFormat:@"%c %d",down?'D':'U',code]);return;
 }
 if(!self.captured){if(down)[self capture];return;}
 // A left click made on the trackpad is the touchpad's own button, so press-and-drag stays one
 // gesture there; right and middle clicks keep going through the USB mouse.
 if(b==kCSInputButtonLeft&&self.captured&&[self padActive]&&(self.fingers||self.padButton)){
  self.padButton=down;[self sendPadContacts:self.padContacts?:@[]];return;}
 if(down)self.buttons|=b;else self.buttons&=~b;
 [self.input sendMouseButton:b mask:self.buttons pressed:down];
}
- (void)mouseDown:(NSEvent *)e {[self button:kCSInputButtonLeft down:YES event:e];}
- (void)mouseUp:(NSEvent *)e {if([self live])[self button:kCSInputButtonLeft down:NO event:e];}
- (void)rightMouseDown:(NSEvent *)e {[self button:kCSInputButtonRight down:YES event:e];}
- (void)rightMouseUp:(NSEvent *)e {if([self live])[self button:kCSInputButtonRight down:NO event:e];}
- (void)otherMouseDown:(NSEvent *)e {[self button:kCSInputButtonMiddle down:YES event:e];}
- (void)otherMouseUp:(NSEvent *)e {if([self live])[self button:kCSInputButtonMiddle down:NO event:e];}
- (void)mouseMoved:(NSEvent *)e {
 if(self.locked){
  CGFloat scale=MIN(self.bounds.size.width/self.guestSize.width,self.bounds.size.height/self.guestSize.height);if(scale<=0)scale=1;
  if(e.deltaX||e.deltaY)self.sendLine([NSString stringWithFormat:@"R %.2f %.2f",e.deltaX/scale,e.deltaY/scale]);return;}
 if(self.absolute){
  // Mouse-moved events also arrive over the title bar; only own the cursor inside the view.
  if(!NSPointInRect([self convertPoint:e.locationInWindow fromView:nil],self.bounds)){if(self.inside){self.inside=NO;[self setHostCursorHidden:NO];self.sendLine(@"X");}return;}
  self.inside=YES;[self setHostCursorHidden:YES];CGPoint g=[self guestPoint:e];self.sendLine([NSString stringWithFormat:@"M %.1f %.1f",g.x,g.y]);return;}
 if(!self.captured)return;
 // Fingers on the trackpad already move the guest pointer through its touchpad.
 if([self padActive]&&self.fingers)return;
 [self moveBy:CGPointMake(e.deltaX,e.deltaY)];
}
// Captured trackpad: Android gets the raw contacts on a virtual touchpad and does pointer motion,
// scrolling and gestures itself, as on a real one, instead of a mouse with macOS's curve applied.
- (void)touchesBeganWithEvent:(NSEvent *)e {[self trackpad:e];}
- (void)touchesMovedWithEvent:(NSEvent *)e {[self trackpad:e];}
- (void)touchesEndedWithEvent:(NSEvent *)e {[self trackpad:e];}
- (void)touchesCancelledWithEvent:(NSEvent *)e {[self trackpad:e];}
- (void)trackpad:(NSEvent *)e {
 NSSet<NSTouch *> *touches=[e touchesMatchingPhase:NSTouchPhaseTouching inView:self];
 self.fingers=touches.count;
 // Gestures are Android's own (scrolling with its momentum, pinch, three-finger swipes and
 // taps); one finger stays the Mac cursor, which Android's pointer follows. Two fingers go to
 // Android only once they move: a two-finger tap is the Mac's right click, and Android, which
 // takes taps too, would click a second time.
 BOOL gesture=NO;
 if(self.absolute&&!self.locked){
  if(touches.count<2)self.twoFingerStart=nil;
  else if(touches.count>=3||self.padContacts.count)gesture=YES;
  else {
   if(!self.twoFingerStart){NSMutableDictionary *d=[NSMutableDictionary dictionary];for(NSTouch *t in touches)d[t.identity]=[NSValue valueWithPoint:t.normalizedPosition];self.twoFingerStart=d;}
   for(NSTouch *t in touches){NSValue *v=self.twoFingerStart[t.identity];if(!v){gesture=YES;break;}
    NSPoint a=v.pointValue,b=t.normalizedPosition;CGFloat mm=hypot((b.x-a.x)*t.deviceSize.width,(b.y-a.y)*t.deviceSize.height)*25.4/72;
    if(mm>1.5){gesture=YES;break;}}
  }
 }
 if(!gesture){if(self.padContacts.count)[self sendPadContacts:@[]];return;}
 if(!self.touchpadReady){
  // First touch: ask the guest for a touchpad the size of this one (deviceSize is in 1/72 inch).
  NSTouch *t=touches.anyObject;
  if(t&&!self.touchpadAsked){self.touchpadAsked=YES;NSNumber *nat=[[NSUserDefaults standardUserDefaults] objectForKey:@"com.apple.swipescrolldirection"];
   self.sendLine([NSString stringWithFormat:@"P %.1f %.1f %d",t.deviceSize.width*25.4/72,t.deviceSize.height*25.4/72,nat?nat.boolValue:1]);}
  return;}
 if(!self.touchIds)self.touchIds=[NSMutableDictionary dictionary];
 NSMutableArray *contacts=[NSMutableArray array];NSMutableDictionary *seen=[NSMutableDictionary dictionary];
 for(NSTouch *t in touches){NSNumber *n=self.touchIds[t.identity]?:@(self.nextTouchId++ & 0xffff);seen[t.identity]=n;
  [contacts addObject:@[n,@(t.normalizedPosition.x),@(1-t.normalizedPosition.y)]];}
 self.touchIds=seen;
 // Two fingers that just started moving: put them down where they landed first, so Android
 // scrolls the whole way they went, not from where they were told apart from a tap.
 if(!self.padContacts.count&&touches.count==2&&self.twoFingerStart.count==2){
  NSMutableArray *start=[NSMutableArray array];
  for(NSTouch *t in touches){NSValue *v=self.twoFingerStart[t.identity];if(!v){start=nil;break;}
   [start addObject:@[seen[t.identity],@(v.pointValue.x),@(1-v.pointValue.y)]];}
  if(start)[self sendPadContacts:start];}
 [self sendPadContacts:contacts];
}
// The trackpad goes to the guest's touchpad only once it exists and while Settings allow it.
- (BOOL)padActive {return self.touchpadReady;}
- (void)sendPadContacts:(NSArray<NSArray<NSNumber *> *> *)contacts {
 self.padContacts=contacts;
 NSMutableString *l=[NSMutableString stringWithFormat:@"F %d %lu",self.padButton,(unsigned long)contacts.count];
 for(NSArray<NSNumber *> *c in contacts)[l appendFormat:@" %d %.4f %.4f",c[0].intValue,c[1].doubleValue,c[2].doubleValue];
 self.sendLine(l);
}
- (void)resetTouchpad {self.wheelReady=NO;self.wheelCarry=CGPointZero;self.touchpadReady=NO;self.touchpadAsked=NO;self.padButton=0;self.padContacts=nil;self.touchIds=nil;}
// Captured mouse: move the guest's relative mouse by a distance in this view's points.
- (void)moveBy:(CGPoint)points {
 CGFloat scale=MIN(self.bounds.size.width/self.guestSize.width,self.bounds.size.height/self.guestSize.height);if(scale<=0)scale=1;
 // SPICE moves the mouse in whole pixels and drops the fraction; macOS deltas are fractional, so carry
 // what is left to the next event instead of losing it (slow moves would stall, fast ones fall short).
 CGPoint d=CGPointMake(points.x/scale+self.carry.x,points.y/scale+self.carry.y),w=CGPointMake(trunc(d.x),trunc(d.y));self.carry=CGPointMake(d.x-w.x,d.y-w.y);
 if(w.x||w.y)[self.input sendMouseMotion:self.buttons relativePoint:w];
}
- (void)mouseDragged:(NSEvent *)e {[self mouseMoved:e];}
- (void)rightMouseDragged:(NSEvent *)e {[self mouseMoved:e];}
- (void)otherMouseDragged:(NSEvent *)e {[self mouseMoved:e];}
- (void)scrollWheel:(NSEvent *)e {
 // A trackpad's two-finger scroll, and the momentum after it, are Android's touchpad gestures.
 if(self.absolute&&!self.locked&&[self padActive]&&e.hasPreciseScrollingDeltas&&(self.fingers>=2||e.momentumPhase!=NSEventPhaseNone))return;
 if(self.absolute&&!self.locked&&!self.wheelReady){CGFloat k=e.hasPreciseScrollingDeltas?1.0/16:1.0;if(e.scrollingDeltaX||e.scrollingDeltaY)self.sendLine([NSString stringWithFormat:@"S %.3f %.3f",-e.scrollingDeltaX*k,e.scrollingDeltaY*k]);return;}
 // A trackpad's two-finger scroll (and its momentum) already reaches the guest's touchpad.
 if(self.captured&&[self padActive]&&e.hasPreciseScrollingDeltas)return;
 if(![self live])return;
 // The USB mouse only scrolls in whole notches (a fixed jump each). The guest's high-resolution
 // wheel takes 1/120 notch; Android scrolls 64 dp a notch, and a dp is a macOS point at the density
 // the VM sets, so a trackpad's points map 1:1 (momentum included). A mouse wheel's lines are notches.
 if(self.wheelReady){double k=e.hasPreciseScrollingDeltas?120.0/64.0:120.0;
  double v=self.wheelCarry.y+e.scrollingDeltaY*k,h=self.wheelCarry.x-e.scrollingDeltaX*k;long iv=(long)v,ih=(long)h;
  self.wheelCarry=CGPointMake(h-ih,v-iv);if(iv||ih)self.sendLine([NSString stringWithFormat:@"W %ld %ld",iv,ih]);return;}
 [self.input sendMouseScroll:kCSInputScrollSmooth buttonMask:self.buttons dy:-e.scrollingDeltaY/10.0];}
- (void)keyDown:(NSEvent *)e {if([self live] && e.keyCode<128 && scan[e.keyCode])[self.input sendKey:kCSInputKeyPress code:scan[e.keyCode]];}
- (void)keyUp:(NSEvent *)e {if([self live] && e.keyCode<128 && scan[e.keyCode])[self.input sendKey:kCSInputKeyRelease code:scan[e.keyCode]];}
- (void)flagsChanged:(NSEvent *)e {
 // Control+Option releases a captured mouse (the same chord UTM uses), so Esc reaches the guest.
 if((self.captured||self.locked)&&(e.modifierFlags&NSEventModifierFlagControl)&&(e.modifierFlags&NSEventModifierFlagOption)){[self releaseCapture];return;}
 if(![self live])return;NSUInteger flag=0;switch(e.keyCode){case 56:case 60:flag=NSEventModifierFlagShift;break;case 59:case 62:flag=NSEventModifierFlagControl;break;case 58:case 61:flag=NSEventModifierFlagOption;break;case 54:case 55:flag=NSEventModifierFlagCommand;break;}if(flag)[self.input sendKey:(e.modifierFlags&flag)?kCSInputKeyPress:kCSInputKeyRelease code:scan[e.keyCode]];}
@end

@interface App : NSObject<NSApplicationDelegate,NSWindowDelegate,CSConnectionDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) VMView *view;
@property(nonatomic,strong) CSMetalRenderer *renderer;
@property(nonatomic,strong) CSConnection *connection;
@property(nonatomic,strong) CSDisplay *display;
@property(nonatomic,strong) NSString *socketPath;
@property(nonatomic) BOOL startFullscreen;
@property(nonatomic,strong) NSWindow *settingsWindow;
@property(nonatomic,strong) NSTask *vmTask;
@property(nonatomic,strong) dispatch_source_t glide, touchTest, wheelTest;
@property(nonatomic,strong) id<NSObject> activity;
@property(nonatomic) CFMachPortRef swipeTap;
@property(nonatomic,strong) NSString *runDir;
@property(nonatomic,strong) NSString *workDir;
@property(nonatomic,strong) NSWindow *setupWindow;
@property(nonatomic,strong) NSTextField *setupTitle, *setupStep, *setupDetail;
@property(nonatomic,strong) NSProgressIndicator *setupBar;
@property(nonatomic,strong) NSButton *setupButton, *setupSecond;
@property(nonatomic,strong) NSTask *setupTask;
@property(nonatomic,strong) NSMutableString *setupOut;
@property(nonatomic,strong) id<NSObject> setupActivity;
@property(nonatomic) BOOL backupDropped, storageWarned;
@property(nonatomic) BOOL quitting;
@property(nonatomic) BOOL restarting;
@property(nonatomic) BOOL densitySent;
@property(nonatomic) NSInteger guestDensity;
@property(nonatomic,strong) GBWebcam *webcam;
@property(nonatomic,strong) GBMicrophone *microphone;
@property(nonatomic,strong) GBBluetoothRelay *bluetooth;
@property(nonatomic,strong) dispatch_source_t selftest2;
@property(nonatomic,strong) NSMutableData *ctlOut;          // queued for the guest helper
@property(nonatomic,strong) dispatch_source_t writeSource;  // waits for room in the socket
@property(nonatomic,strong) NSMutableArray<dispatch_source_t> *acceptSources;
@property(nonatomic,strong) NSMutableSet<NSString *> *lanListening;   // the Mac's addresses listened on
@property(nonatomic,strong) dispatch_source_t readSource;
@property(nonatomic) int ctlFd;
@property(nonatomic,strong) NSMutableArray *ctlPending; // read sources of connections still proving the token, oldest first
@end
// Whether an address on the Mac's network belongs to the VM: its network card's MAC address
// (run_vm.py gives it 52:54:00:12:34:56) in the Mac's ARP table.
static BOOL isVMAddress(struct in_addr ip) {
 int mib[6]={CTL_NET,PF_ROUTE,0,AF_INET,NET_RT_FLAGS,RTF_LLINFO};size_t len=0;
 if(sysctl(mib,6,NULL,&len,NULL,0)<0||!len)return NO;
 NSMutableData *buf=[NSMutableData dataWithLength:len];
 if(sysctl(mib,6,buf.mutableBytes,&len,NULL,0)<0)return NO;
 static const uint8_t vm[6]={0x52,0x54,0x00,0x12,0x34,0x56};
 for(char *p=buf.mutableBytes,*end=p+len;p<end;){
  struct rt_msghdr *rtm=(struct rt_msghdr *)p;if(!rtm->rtm_msglen)break;
  struct sockaddr_in *sin=(struct sockaddr_in *)(rtm+1);
  struct sockaddr_dl *sdl=(struct sockaddr_dl *)((char *)sin+(sin->sin_len?((sin->sin_len+3)&~3):4));
  if(sin->sin_addr.s_addr==ip.s_addr&&sdl->sdl_family==AF_LINK&&sdl->sdl_alen==6&&!memcmp(LLADDR(sdl),vm,6))return YES;
  p+=rtm->rtm_msglen;
 }
 return NO;
}
// A screen's refresh rate in Hz, as precisely as macOS reports it (59.94 rather than 60).
static double screenRefresh(NSScreen *screen) {
 CGDirectDisplayID did=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];CGDisplayModeRef mode=CGDisplayCopyDisplayMode(did);
 double hz=mode?CGDisplayModeGetRefreshRate(mode):0;if(mode)CGDisplayModeRelease(mode);
 return hz>0?hz:(double)screen.maximumFramesPerSecond;
}
// The Mac's battery as the guest helper's B line: level, on AC power, charging. Macs without one
// report AC power at 100%, which is what Android should show for them too.
static NSString *batteryLine(void) {
 int level=100,plugged=1,charging=0;
 CFTypeRef info=IOPSCopyPowerSourcesInfo();CFArrayRef list=info?IOPSCopyPowerSourcesList(info):NULL;
 for(CFIndex i=0;list&&i<CFArrayGetCount(list);i++){
  NSDictionary *d=(__bridge NSDictionary *)IOPSGetPowerSourceDescription(info,CFArrayGetValueAtIndex(list,i));
  if(![d[@kIOPSTypeKey] isEqualToString:@kIOPSInternalBatteryType])continue;
  int cur=[d[@kIOPSCurrentCapacityKey] intValue],max=[d[@kIOPSMaxCapacityKey] intValue];
  level=max>0?(int)lround(100.0*cur/max):cur;plugged=[d[@kIOPSPowerSourceStateKey] isEqualToString:@kIOPSACPowerValue];charging=[d[@kIOPSIsChargingKey] boolValue];break;}
 if(list)CFRelease(list);if(info)CFRelease(info);
 return [NSString stringWithFormat:@"B %d %d %d",level,plugged,charging];
}
// The Android density that makes a guest `width` pixels wide look like macOS on `screen`.
static NSInteger guestDensity(NSInteger width,NSScreen *screen) {
 double points=screen.frame.size.width>0?screen.frame.size.width:width/2.0;
 return (NSInteger)MAX(120,MIN(640,round(160.0*width/points)));
}
@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
 // A VM runs on while its window is in the background, and the guest waits on this app for every
 // frame: keep App Nap from throttling us to a few timer wakeups a second (sleep stays allowed).
 self.activity=[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep|NSActivityLatencyCritical reason:@"Running the Googlebook VM"];
 // Android 16 with Google's services swaps hard in 4 GB (laggy screens, CPU spent compressing
 // memory); give it 8 GB on Macs that have the room.
 NSNumber *memory=NSProcessInfo.processInfo.physicalMemory>=24ULL<<30?@8192:@4096;
 {NSUserDefaults *u=[NSUserDefaults standardUserDefaults];  // the network checkboxes became one choice
  if(![u objectForKey:@"Network"]&&([u objectForKey:@"Networking"]||[u objectForKey:@"IsolateNetwork"]))
   [u setObject:([u objectForKey:@"Networking"]&&![u boolForKey:@"Networking"])?@"off":[u boolForKey:@"IsolateNetwork"]?@"isolated":@"full" forKey:@"Network"];
  for(NSString *k in @[@"Networking",@"IsolateNetwork",@"RefreshCap",@"Graphics",@"PointerMode",@"AndroidTouchpad",@"TrackpadGestures",
                       @"GuestClipboardToMac",@"Audio",@"Camera",@"Microphone",@"Bluetooth",@"BluetoothPhones"])[u removeObjectForKey:k];
  // Settings offers two networks now; the isolated and offline ones remain run_vm.py options
  if(![@[@"full",@"lan"] containsObject:[u stringForKey:@"Network"]?:@"full"])[u removeObjectForKey:@"Network"];}
 [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"Resolution":@"native",@"StartFullscreen":@NO,@"MemoryMiB":memory,@"CPUs":@6,@"Network":@"full",@"GuestClipboardToMac":@YES,@"Audio":@YES,@"Camera":@YES,@"Microphone":@YES}];
 // The downloadable app sets itself up first (and after an update), before anything uses SPICE
 if(!self.socketPath&&isDownloadedApp()&&(!spiceLoaded()||![self setupReady])){[self showSetup];return;}
 self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1280,800) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"Googlebook VM";self.window.subtitle=@"Connecting…";self.window.delegate=self;self.window.acceptsMouseMovedEvents=YES;self.window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
 self.view=[[VMView alloc] initWithFrame:self.window.contentView.bounds device:MTLCreateSystemDefaultDevice()];self.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;self.view.allowedTouchTypes=NSTouchTypeMaskIndirect;self.view.preferredFramesPerSecond=120;self.view.clearColor=MTLClearColorMake(0,0,0,1);
 // Started from the Dock or Finder (no socket argument): this app runs the VM itself.
 if(!self.socketPath)self.startFullscreen=[[NSUserDefaults standardUserDefaults] boolForKey:@"StartFullscreen"];
 // Until the guest helper links up, wait rather than move the emulated USB mouse: moving it first
 // would leave a second, frozen Android cursor once the helper takes over.
 self.view.relativeAllowed=NO;
 if(!self.view.relativeAllowed)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(150*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(!self.view.absolute){self.view.relativeAllowed=YES;[self updateSubtitle];}});
 self.renderer=[[CSMetalRenderer alloc] initWithMetalKitView:self.view];self.view.delegate=self.renderer;
 self.window.contentView=self.view;[self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 if(self.startFullscreen)[self.window toggleFullScreen:nil];
 __weak App *weakSelf=self;self.view.sendLine=^(NSString *l){[weakSelf ctlSend:l];};[self startControlServer];[self watchBattery];[self watchOtherWindows];[self watchKeyboardLayout];[self watchScreenshotRequests];
 [CSMain.sharedInstance spiceSetDebug:NO];
 if(![CSMain.sharedInstance spiceStart]){fprintf(stderr,"SPICE worker failed\n");[NSApp terminate:nil];return;}
 if(self.socketPath)[self connectSpice];else [self startVM];
 [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[self fit];}];
 // Self-test hooks for tests/perf.py (VM_SELFTEST_GLIDE=1, VM_SELFTEST_TOUCH=1): each SIGUSR2 runs the next step.
 signal(SIGUSR2,SIG_IGN);dispatch_source_t usr2=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGUSR2,0,dispatch_get_main_queue());
 dispatch_source_set_event_handler(usr2,^{
  // With VM_SELFTEST_GLIDE=1 (tests/perf.py): instead, a slow, perfectly even glide through the
  // captured-mouse path, 0.2 x 0.1 points every 2 ms for 5 s, so the guest can time what arrives.
  // With VM_SELFTEST_TOUCH=1 as well, the second signal exercises the guest touchpad instead: one
  // finger glides across it, then two fingers scroll up three times (perf image: Settings is open).
  // The third signal scrolls with the guest's high-resolution wheel: 1.5 s down in 1/4-notch
  // steps every 8 ms, then 1.5 s back up.
  if(getenv("VM_SELFTEST_GLIDE")&&self.touchTest){self.touchTest=nil;fprintf(stderr,"SELFTEST wheel\n");
   __block int n=0;dispatch_source_t t=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
   dispatch_source_set_timer(t,DISPATCH_TIME_NOW,8*NSEC_PER_MSEC,0);
   dispatch_source_set_event_handler(t,^{int k=n++;if(k<375)[self ctlSend:(k<188)?@"W -30 0":@"W 30 0"];
    else{dispatch_source_cancel(self.wheelTest);fprintf(stderr,"SELFTEST wheel done\n");}});
   dispatch_resume(t);self.wheelTest=t;return;}
  if(getenv("VM_SELFTEST_TOUCH")&&self.glide){self.glide=nil;[self ctlSend:@"P 160 100 1"];fprintf(stderr,"SELFTEST touchpad\n");
   __block int n=0;dispatch_source_t t=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
   dispatch_source_set_timer(t,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),8*NSEC_PER_MSEC,0);
   __block CFTimeInterval t0=0;
   dispatch_source_set_event_handler(t,^{VMView *v=self.view;if(!v.touchpadReady)return;  // as real touches do
    int k=n++;if(!k)t0=CACurrentMediaTime();if(k&&k%100==0)fprintf(stderr,"SELFTEST touchpad sent %d frames in %.0f ms\n",k,1000*(CACurrentMediaTime()-t0));
    if(k<190)[v sendPadContacts:@[@[@1,@(0.3+0.3*k/190.0),@0.5]]];                       // one finger, 1.5 s
    else if(k<250)[v sendPadContacts:@[]];
    else if(k<250+3*110){int r=(k-250)%110;if(r<75)[v sendPadContacts:@[@[@(10+(k-250)/110*2),@0.45,@(0.75-0.45*r/75.0)],@[@(11+(k-250)/110*2),@0.55,@(0.75-0.45*r/75.0)]]];else [v sendPadContacts:@[]];}
    else{[v sendPadContacts:@[]];dispatch_source_cancel(self.touchTest);fprintf(stderr,"SELFTEST touchpad done\n");}});
   dispatch_resume(t);self.touchTest=t;return;}
  if(getenv("VM_SELFTEST_GLIDE")){__block int n=0;dispatch_source_t t=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
   dispatch_source_set_timer(t,DISPATCH_TIME_NOW,2*NSEC_PER_MSEC,0);
   dispatch_source_set_event_handler(t,^{[self.view moveBy:CGPointMake(n%2000<1000?.2:-.2,n%2000<1000?.1:-.1)];if(++n>=2500)dispatch_source_cancel(t);});
   dispatch_resume(t);self.glide=t;fprintf(stderr,"SELFTEST glide\n");return;} });
 dispatch_resume(usr2);self.selftest2=usr2;
 fprintf(stderr,"WINDOW %ld\n",(long)self.window.windowNumber);
 fprintf(stderr,"NATIVE_VIEWER device=%s socket=%s\n",self.view.device.name.UTF8String,self.socketPath.UTF8String);
}
- (void)fit {
 CGSize size=self.display.displaySize;if(!size.width||!size.height)return;
 if(!CGSizeEqualToSize(size,self.view.guestSize)){
  self.view.guestSize=size;self.window.title=[NSString stringWithFormat:@"Googlebook • %.0f×%.0f",size.width,size.height];}
 self.renderer.viewportScale=MIN(self.view.drawableSize.width/size.width,self.view.drawableSize.height/size.height);self.renderer.viewportOrigin=CGPointZero;
}
- (void)windowDidResize:(NSNotification *)n{[self fit];}
- (void)toggleFull:(id)sender{[self.window toggleFullScreen:nil];}
- (void)connectSpice {
 NSString *hz=[NSString stringWithContentsOfFile:[[self.socketPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"refresh"] encoding:NSUTF8StringEncoding error:nil];
 self.renderer.guestRefresh=hz.doubleValue;fprintf(stderr,"GUEST_REFRESH %.2f Hz screen %ld Hz\n",hz.doubleValue,(long)self.window.screen.maximumFramesPerSecond);
 self.connection=[[CSConnection alloc] initWithUnixSocketFile:[NSURL fileURLWithPath:self.socketPath]];self.connection.audioEnabled=NO;self.connection.delegate=self;
 [self.connection connect];
}
- (void)fail:(NSString *)message {
 NSAlert *a=[NSAlert new];a.messageText=@"Googlebook VM couldn't start";a.informativeText=message;[a runModal];self.vmTask=nil;[NSApp terminate:nil];
}
// Self-starting mode: run the VM with the bundled runner script, wait for its display socket,
// then connect. Quitting asks the runner to stop, which powers Android off cleanly first.
- (void)startVM {
 NSBundle *b=NSBundle.mainBundle;NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
 if([[d stringForKey:@"Network"] isEqualToString:@"lan"]&&![self setUpNetworkBridge])[d setObject:@"full" forKey:@"Network"];
 NSString *work=workFolder();
 NSString *runner=[b pathForResource:@"run_vm" ofType:@"py"];
 if(!work||!runner||![[NSFileManager defaultManager] fileExistsAtPath:[work stringByAppendingPathComponent:@"image/googlebook.raw"]]){
  [self fail:[NSString stringWithFormat:@"No VM image at %@/image. Run install.sh first, or rebuild the app if you moved the folder.",work?:@"(unknown)"]];return;}
 self.workDir=work;
 // A storage size chosen in Settings: done here, between Android shutting down and starting again
 NSInteger gib=[d integerForKey:@"PendingStorageGiB"];
 if(gib>0){[d removeObjectForKey:@"PendingStorageGiB"];NSString *out=[self storage:@[@(gib).stringValue]];
  if(!out){NSAlert *a=[NSAlert new];a.messageText=@"Couldn't change Android's storage";a.informativeText=@"Android keeps its storage as it was.";[a runModal];}}
 NSString *res=[[d objectForKey:@"Resolution"] description];
 if(![res containsString:@"x"]){
  // "Match this Mac's display": the panel's native pixels, not the (possibly larger) scaled
  // backing size macOS renders at. 16:10 height, which is the area below a MacBook notch.
  NSScreen *sc=NSScreen.mainScreen;CGFloat w=sc.frame.size.width*sc.backingScaleFactor,h=sc.frame.size.height*sc.backingScaleFactor;
  CGDirectDisplayID did=[sc.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
  NSArray *modes=CFBridgingRelease(CGDisplayCopyAllDisplayModes(did,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES}));
  for(id m in modes){CGDisplayModeRef mode=(__bridge CGDisplayModeRef)m;
   if(CGDisplayModeGetIOFlags(mode)&0x02000000 /* kDisplayModeNativeFlag */){w=CGDisplayModeGetPixelWidth(mode);h=CGDisplayModeGetPixelHeight(mode);break;}}
  res=[NSString stringWithFormat:@"%.0fx%.0f",w,MIN(h,round(w/1.6))];}
 // Size Android's UI the way macOS sizes its own: 160 dpi per guest pixel per screen point, so
 // at the panel's native pixels on a Retina screen that is 320, macOS's own 2x.
 self.guestDensity=guestDensity([res integerValue],self.window.screen?:NSScreen.mainScreen);
 NSDateFormatter *f=[NSDateFormatter new];f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];f.dateFormat=@"yyyyMMdd-HHmmss";NSString *name=[@"desktop-" stringByAppendingString:[f stringFromDate:[NSDate date]]];
 self.runDir=[[work stringByAppendingPathComponent:@"logs"] stringByAppendingPathComponent:name];
 NSMutableArray *args=[@[runner,work,name,@"--display",res,@"--memory",[[d objectForKey:@"MemoryMiB"] description],@"--cpus",[[d objectForKey:@"CPUs"] description]] mutableCopy];
 NSString *network=[d stringForKey:@"Network"];
 if([network isEqualToString:@"off"])[args addObject:@"--offline"];
 else if([network isEqualToString:@"isolated"])[args addObject:@"--isolated"];
 else if([network isEqualToString:@"lan"])[args addObject:@"--lan"];
 if(![d boolForKey:@"Audio"])[args addObject:@"--no-audio"];
 if([d boolForKey:@"Camera"]){
  // The guest gets a USB webcam backed by this Mac's camera (host/webcam.m). It connects to the
  // VM's usb-redir socket as soon as QEMU creates it; the camera only runs while Android streams.
  [args addObject:@"--webcam"];
  self.webcam=[[GBWebcam alloc] initWithSocketPath:[self.runDir stringByAppendingPathComponent:@"webcam.sock"]];[self.webcam start];
 }
 if([d boolForKey:@"Microphone"]){
  // Likewise a USB microphone backed by this Mac's microphone (host/microphone.m); QEMU itself
  // can't capture sound on macOS. The Mac microphone only runs while Android records.
  [args addObject:@"--microphone"];
  self.microphone=[[GBMicrophone alloc] initWithSocketPath:[self.runDir stringByAppendingPathComponent:@"mic.sock"]];[self.microphone start];
 }
 // Android gets a virtual Bluetooth radio, and the BLE devices near this Mac appear on it
 // (host/bluetooth.m) once run_vm.py reports the radio's port.
 if([d boolForKey:@"Bluetooth"])[args addObject:@"--bluetooth"];
 // Pace the guest to the screen the window opens on (see guest_refresh in run_vm.py).
 [args addObjectsFromArray:@[@"--host-refresh",[NSString stringWithFormat:@"%g",screenRefresh(self.window.screen?:NSScreen.mainScreen)]]];
 NSTask *t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:bundledPython()];[args insertObject:@"-I" atIndex:0];t.arguments=args;
 t.standardOutput=[NSFileHandle fileHandleWithNullDevice];t.standardError=[NSFileHandle fileHandleWithNullDevice];
 __weak App *weak=self;
 t.terminationHandler=^(NSTask *x){dispatch_async(dispatch_get_main_queue(),^{
  App *me=weak;if(!me||me.vmTask!=x)return;me.vmTask=nil;[me.bluetooth stop];me.bluetooth=nil;
  if(me.quitting){
   // Restart: once Android is down and the runner has exited, open a fresh copy of the app.
   // A new instance also picks up any Settings that only apply at start.
   if(me.restarting){NSTask *o=[NSTask new];o.executableURL=[NSURL fileURLWithPath:@"/bin/sh"];o.arguments=@[@"-c",@"sleep 1; exec /usr/bin/open -n \"$0\"",NSBundle.mainBundle.bundlePath];[o launchAndReturnError:nil];}
   [NSApp replyToApplicationShouldTerminate:YES];
  }
  else if(me.connection)[NSApp terminate:nil];   // Android shut itself down
  else [me fail:@"The VM exited before its display came up. Another Googlebook VM may already be running; otherwise check the newest folder under logs/."];
 });};
 NSError *err=nil;if(![t launchAndReturnError:&err]){[self fail:err.localizedDescription];return;}
 // On the Mac's own network, the pointer link comes to the Mac's address there, which run_vm.py
 // reports (again when it changes, after Wi-Fi reconnects say)
 if([[d stringForKey:@"Network"] isEqualToString:@"lan"]){
  self.lanListening=[NSMutableSet set];
  [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){
   if(!self.vmTask){[timer invalidate];return;}
   NSString *lan=[[NSString stringWithContentsOfFile:[self.runDir stringByAppendingPathComponent:@"host-address"] encoding:NSUTF8StringEncoding error:nil]
                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
   struct in_addr ia;
   if(lan.length&&![self.lanListening containsObject:lan]&&inet_pton(AF_INET,lan.UTF8String,&ia)==1&&[self listenControlAt:ia.s_addr onlyVM:YES])[self.lanListening addObject:lan];
  }];
 }
 self.vmTask=t;self.window.subtitle=@"Starting the VM…";
 [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer){
  if(!self.vmTask){[timer invalidate];return;}
  NSFileManager *fm=[NSFileManager defaultManager];
  if(!self.connection){
   if(![fm fileExistsAtPath:[self.runDir stringByAppendingPathComponent:@"spice.sock"]])return;
   NSString *tk=[NSString stringWithContentsOfFile:[self.runDir stringByAppendingPathComponent:@"token"] encoding:NSUTF8StringEncoding error:nil];
   if(tk.length)setenv("VM_INPUT_TOKEN",tk.UTF8String,1);
   self.socketPath=[self.runDir stringByAppendingPathComponent:@"spice.sock"];[self connectSpice];return;
  }
  if(!self.bluetooth&&[d boolForKey:@"Bluetooth"]){
   NSString *port=[NSString stringWithContentsOfFile:[self.runDir stringByAppendingPathComponent:@"bluetooth-port"] encoding:NSUTF8StringEncoding error:nil];
   if(port.intValue>0){self.bluetooth=[[GBBluetoothRelay alloc] initWithHCIPort:port.intValue log:[self.runDir stringByAppendingPathComponent:@"bluetooth.log"] phones:[d boolForKey:@"BluetoothPhones"]];[self.bluetooth start];}
  }
  if(self.densitySent&&(self.bluetooth||![d boolForKey:@"Bluetooth"]||[fm fileExistsAtPath:[self.runDir stringByAppendingPathComponent:@"bluetooth-none"]])){[timer invalidate];return;}
  if(self.densitySent)return;
  // Once Android is up, match the display density to the resolution (the setting persists).
  NSData *log=[NSData dataWithContentsOfFile:[self.runDir stringByAppendingPathComponent:@"serial.log"]];
  if(log&&[[[NSString alloc] initWithData:log encoding:NSISOLatin1StringEncoding] rangeOfString:@"(^|\n)VM_BOOT_COMPLETED" options:NSRegularExpressionSearch].location!=NSNotFound){
   self.densitySent=YES;
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    NSTask *c=[NSTask new];c.executableURL=[NSURL fileURLWithPath:bundledPython()];
    c.arguments=@[@"-I",[NSBundle.mainBundle pathForResource:@"vm_control" ofType:@"py"],self.runDir,[NSString stringWithFormat:@"VM_DENSITY %ld",(long)self.guestDensity]];
    [c launchAndReturnError:nil];});
  }
 }];
}
// --- Screenshots ---------------------------------------------------------------------------------
// Android's screen as it is, at its full resolution, without the window around it: ⌃⌘S saves it to
// the Desktop. The frame is a GPU texture (frames never pass through the CPU), so it is copied
// out once for the file.
- (BOOL)saveScreenshotTo:(NSString *)path {
 id<MTLTexture> tex=self.display.texture;if(!tex||tex.width==0)return NO;
 NSUInteger w=tex.width,h=tex.height,row=w*4;
 id<MTLBuffer> buf=[tex.device newBufferWithLength:row*h options:MTLResourceStorageModeShared];
 id<MTLCommandQueue> q=[tex.device newCommandQueue];id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
 [bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*h];
 [bl endEncoding];[cb commit];[cb waitUntilCompleted];
 BOOL rgba=tex.pixelFormat==MTLPixelFormatRGBA8Unorm||tex.pixelFormat==MTLPixelFormatRGBA8Unorm_sRGB;
 CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
 CGContextRef ctx=CGBitmapContextCreate(NULL,w,h,8,row,cs,(rgba?kCGBitmapByteOrder32Big:kCGBitmapByteOrder32Little)|kCGImageAlphaNoneSkipLast*rgba|kCGImageAlphaNoneSkipFirst*!rgba);
 if(!ctx){CGColorSpaceRelease(cs);return NO;}
 // Rows top first, as the file wants them (flipped when the source is drawn upside down)
 uint8_t *dst=CGBitmapContextGetData(ctx);const uint8_t *src=buf.contents;size_t drow=CGBitmapContextGetBytesPerRow(ctx);
 for(NSUInteger y=0;y<h;y++)memcpy(dst+y*drow,src+(self.display.isInverted?h-1-y:y)*row,row);
 CGImageRef img=CGBitmapContextCreateImage(ctx);CGContextRelease(ctx);CGColorSpaceRelease(cs);
 CGImageDestinationRef d=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],CFSTR("public.png"),1,NULL);
 BOOL ok=NO;if(d){CGImageDestinationAddImage(d,img,NULL);ok=CGImageDestinationFinalize(d);CFRelease(d);}
 CGImageRelease(img);return ok;
}
- (void)takeScreenshot:(id)sender {
 NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"yyyy-MM-dd 'at' HH.mm.ss";
 NSString *desk=NSSearchPathForDirectoriesInDomains(NSDesktopDirectory,NSUserDomainMask,YES).firstObject;
 NSString *path=[desk stringByAppendingPathComponent:[NSString stringWithFormat:@"Googlebook Screenshot %@.png",[f stringFromDate:[NSDate date]]]];
 if(![self saveScreenshotTo:path]){NSBeep();return;}
 [[NSSound soundNamed:@"Pop"] play];
 NSString *was=self.window.subtitle;self.window.subtitle=@"Screenshot saved to the Desktop";
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if([self.window.subtitle isEqualToString:@"Screenshot saved to the Desktop"])self.window.subtitle=was;});
}
// For scripted captures (the README's pictures): `notifyutil -p local.googlebook.screenshot` saves
// one into this run's log folder, which only this user can read.
- (void)watchScreenshotRequests {
 int token;__weak App *weak=self;
 notify_register_dispatch("local.googlebook.screenshot",&token,dispatch_get_main_queue(),^(int t){
  App *me=weak;if(!me.runDir)return;
  NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"HHmmss";
  [me saveScreenshotTo:[me.runDir stringByAppendingPathComponent:[NSString stringWithFormat:@"screenshot-%@.png",[f stringFromDate:[NSDate date]]]]];});
}
// --- Setup (the downloadable app) ---------------------------------------------------------------
// One window for people who have never used a terminal: what will happen, then a progress bar
// through run/setup.py's steps, and plain words if something goes wrong (Try Again resumes).
- (BOOL)setupReady {
 NSTask *t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:bundledPython()];
 t.arguments=@[@"-I",[NSBundle.mainBundle pathForResource:@"setup" ofType:@"py"],workFolder(),@"--check"];
 t.standardOutput=t.standardError=[NSFileHandle fileHandleWithNullDevice];
 if(![t launchAndReturnError:nil])return NO;[t waitUntilExit];return t.terminationStatus==0;
}
- (NSTextField *)setupLabel:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
 NSTextField *l=[NSTextField wrappingLabelWithString:text];l.font=bold?[NSFont boldSystemFontOfSize:size]:[NSFont systemFontOfSize:size];
 l.selectable=NO;l.translatesAutoresizingMaskIntoConstraints=NO;return l;
}
- (void)showSetup {
 BOOL fresh=![[NSFileManager defaultManager] fileExistsAtPath:[workFolder() stringByAppendingPathComponent:@"image/googlebook.raw"]];
 NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,330) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
 w.title=@"Googlebook VM";w.delegate=self;w.releasedWhenClosed=NO;
 NSImageView *icon=[NSImageView imageViewWithImage:NSApp.applicationIconImage];icon.translatesAutoresizingMaskIntoConstraints=NO;
 self.setupTitle=[self setupLabel:fresh?@"Welcome to Googlebook VM":@"Googlebook VM was updated" size:20 bold:YES];
 self.setupStep=[self setupLabel:fresh?@"Googlebook OS is Google's Android for laptops. To run it on this Mac, Googlebook VM downloads it from Google (about 9 GB) and prepares it for your Mac.\n\nIt takes 15 to 45 minutes, depending on your internet connection, and needs about 45 GB of free disk space. You can keep using your Mac in the meantime.":@"It needs a few minutes to update Android's system. Your apps and files stay as they are." size:13 bold:NO];
 self.setupDetail=[self setupLabel:@"" size:11 bold:NO];self.setupDetail.textColor=NSColor.secondaryLabelColor;
 self.setupBar=[NSProgressIndicator new];self.setupBar.indeterminate=NO;self.setupBar.minValue=0;self.setupBar.maxValue=1;self.setupBar.hidden=YES;self.setupBar.translatesAutoresizingMaskIntoConstraints=NO;
 self.setupButton=[NSButton buttonWithTitle:fresh?@"Set Up":@"Update" target:self action:@selector(setupPressed:)];self.setupButton.keyEquivalent=@"\r";
 self.setupSecond=[NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];
 for(NSButton *b in @[self.setupButton,self.setupSecond])b.translatesAutoresizingMaskIntoConstraints=NO;
 NSView *c=w.contentView;for(NSView *v in @[icon,self.setupTitle,self.setupStep,self.setupBar,self.setupDetail,self.setupButton,self.setupSecond])[c addSubview:v];
 [NSLayoutConstraint activateConstraints:@[
  [icon.topAnchor constraintEqualToAnchor:c.topAnchor constant:24],[icon.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:24],
  [icon.widthAnchor constraintEqualToConstant:64],[icon.heightAnchor constraintEqualToConstant:64],
  [self.setupTitle.topAnchor constraintEqualToAnchor:c.topAnchor constant:28],[self.setupTitle.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:16],
  [self.setupTitle.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-24],
  [self.setupStep.topAnchor constraintEqualToAnchor:self.setupTitle.bottomAnchor constant:10],[self.setupStep.leadingAnchor constraintEqualToAnchor:self.setupTitle.leadingAnchor],
  [self.setupStep.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-24],
  [self.setupBar.topAnchor constraintEqualToAnchor:self.setupStep.bottomAnchor constant:16],[self.setupBar.leadingAnchor constraintEqualToAnchor:self.setupTitle.leadingAnchor],
  [self.setupBar.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-24],
  [self.setupDetail.topAnchor constraintEqualToAnchor:self.setupBar.bottomAnchor constant:6],[self.setupDetail.leadingAnchor constraintEqualToAnchor:self.setupTitle.leadingAnchor],
  [self.setupDetail.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-24],
  [self.setupButton.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-20],[self.setupButton.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-24],
  [self.setupSecond.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-20],[self.setupSecond.trailingAnchor constraintEqualToAnchor:self.setupButton.leadingAnchor constant:-12]]];
 self.setupWindow=w;[w center];[w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 if(!fresh)[self setupPressed:nil];   // an update needs no decision
}
- (void)setupPressed:(id)sender {
 if(self.setupTask)return;
 self.setupButton.enabled=NO;self.setupSecond.title=@"Stop";self.setupSecond.action=@selector(stopSetup:);self.setupSecond.target=self;
 self.setupBar.hidden=NO;self.setupBar.doubleValue=0;self.setupDetail.stringValue=@"Starting…";
 // Keep the Mac awake for the downloads (the display may still sleep)
 self.setupActivity=[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated reason:@"Setting up Googlebook VM"];
 NSTask *t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:bundledPython()];
 t.arguments=@[@"-I",@"-u",[NSBundle.mainBundle pathForResource:@"setup" ofType:@"py"],workFolder()];
 NSPipe *p=[NSPipe pipe];t.standardOutput=p;t.standardError=[NSFileHandle fileHandleWithNullDevice];self.setupOut=[NSMutableString string];
 __weak App *weak=self;
 p.fileHandleForReading.readabilityHandler=^(NSFileHandle *h){NSData *d=h.availableData;if(!d.length){h.readabilityHandler=nil;return;}
  NSString *s=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]?:@"";
  dispatch_async(dispatch_get_main_queue(),^{[weak setupText:s];});};
 t.terminationHandler=^(NSTask *x){dispatch_async(dispatch_get_main_queue(),^{[weak setupEnded:x.terminationStatus];});};
 self.setupTask=t;
 if(![t launchAndReturnError:nil]){self.setupTask=nil;[self setupFailed:@"Googlebook VM couldn't start its setup. Try downloading the app again."];}
}
- (void)setupText:(NSString *)s {
 [self.setupOut appendString:s];NSRange nl;
 while((nl=[self.setupOut rangeOfString:@"\n"]).location!=NSNotFound){
  NSString *line=[self.setupOut substringToIndex:nl.location];[self.setupOut deleteCharactersInRange:NSMakeRange(0,nl.location+1)];
  NSArray<NSString *> *w=[line componentsSeparatedByString:@" "];
  if([line hasPrefix:@"@step "]&&w.count>3){self.setupTitle.stringValue=[[w subarrayWithRange:NSMakeRange(3,w.count-3)] componentsJoinedByString:@" "];
   self.setupStep.stringValue=[NSString stringWithFormat:@"Step %@ of %@",w[1],w[2]];self.setupBar.doubleValue=0;self.setupDetail.stringValue=@"";}
  else if([line hasPrefix:@"@progress "]&&w.count>1){self.setupBar.doubleValue=w[1].doubleValue;
   if(w.count>2)self.setupDetail.stringValue=[[w subarrayWithRange:NSMakeRange(2,w.count-2)] componentsJoinedByString:@" "];}
  else if([line hasPrefix:@"@error "])[self setupFailed:[[line substringFromIndex:7] stringByReplacingOccurrencesOfString:@" ⏎ " withString:@"\n"]];
  else if([line isEqualToString:@"@done"]){self.setupTitle.stringValue=@"Googlebook OS is ready";self.setupStep.stringValue=@"Starting it now…";self.setupBar.doubleValue=1;self.setupDetail.stringValue=@"";}
 }
}
- (void)setupFailed:(NSString *)message {
 self.setupTitle.stringValue=@"Setup didn't finish";self.setupStep.stringValue=message;self.setupBar.hidden=YES;self.setupDetail.stringValue=@"Nothing is lost: Try Again picks up where it stopped.";
 self.setupButton.title=@"Try Again";self.setupButton.enabled=YES;self.setupSecond.title=@"Quit";self.setupSecond.target=NSApp;self.setupSecond.action=@selector(terminate:);
}
- (void)stopSetup:(id)sender {[self.setupTask terminate];}
- (void)setupEnded:(int)status {
 BOOL ok=status==0&&[self.setupTitle.stringValue isEqualToString:@"Googlebook OS is ready"];self.setupTask=nil;
 [[NSProcessInfo processInfo] endActivity:self.setupActivity];self.setupActivity=nil;
 if(!ok){if(self.setupButton.enabled)return;   // the error is showing already
  [self setupFailed:status==15?@"You stopped the setup.":@"The setup stopped unexpectedly."];return;}
 // A fresh start loads the graphics libraries setup just fetched, and boots Android
 NSTask *o=[NSTask new];o.executableURL=[NSURL fileURLWithPath:@"/bin/sh"];
 o.arguments=@[@"-c",@"sleep 1; exec /usr/bin/open -n \"$0\"",NSBundle.mainBundle.bundlePath];[o launchAndReturnError:nil];
 [NSApp terminate:nil];
}
// run/storage.py: Android's storage size, or a fresh one of a new size. Its output, or nil if it failed.
- (NSString *)storage:(NSArray<NSString *> *)args {
 NSString *script=[NSBundle.mainBundle pathForResource:@"storage" ofType:@"py"];if(!script||!self.workDir)return nil;
 NSTask *t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:bundledPython()];t.arguments=[@[@"-I",script,self.workDir] arrayByAddingObjectsFromArray:args];
 NSPipe *p=[NSPipe pipe];t.standardOutput=p;t.standardError=[NSFileHandle fileHandleWithNullDevice];
 if(![t launchAndReturnError:nil])return nil;
 NSData *o=[p.fileHandleForReading readDataToEndOfFile];[t waitUntilExit];
 return t.terminationStatus==0?[[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding]:nil;
}
- (void)changeStorage:(id)sender {
 NSInteger now=[[self storage:@[]] integerValue];
 NSAlert *a=[NSAlert new];a.messageText=@"Erase Android and change its storage?";
 a.informativeText=[NSString stringWithFormat:@"Android's storage is %ld GB. Android can't grow it in place, so it starts over with an empty one of the new size, as after a factory reset: its apps, accounts and files are erased. The Mac only uses the space Android fills. The VM restarts now.\n\nNew size in GB (16 to 1024):",(long)now];
 NSTextField *field=[NSTextField textFieldWithString:@(MAX(64,now*2)).stringValue];field.frame=NSMakeRect(0,0,120,24);a.accessoryView=field;
 [a addButtonWithTitle:@"Erase and Restart"];[a addButtonWithTitle:@"Cancel"];a.alertStyle=NSAlertStyleCritical;
 [a.window setInitialFirstResponder:field];
 if([a runModal]!=NSAlertFirstButtonReturn)return;
 NSInteger gib=field.integerValue;
 if(gib<16||gib>1024){NSAlert *b=[NSAlert new];b.messageText=@"Choose a size from 16 to 1024 GB.";[b runModal];return;}
 [[NSUserDefaults standardUserDefaults] setInteger:gib forKey:@"PendingStorageGiB"];
 [self.settingsWindow close];[self restartVM:nil];
}
- (void)restartVM:(id)sender {if(self.vmTask){self.restarting=YES;[NSApp terminate:nil];}}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
 [self.setupTask terminate];   // setup resumes where it stopped, next time
 if(!self.vmTask||!self.vmTask.running)return NSTerminateNow;
 self.quitting=YES;self.window.subtitle=self.restarting?@"Restarting: shutting Android down…":@"Shutting Android down…";[self.view releaseCapture];[self.vmTask terminate];
 return NSTerminateLater;
}
// Control link to the helper in Android (guest/input). Any guest app can reach this port, so
// both ends prove the token with an HMAC exchange (see Input.java) first.
// Sends never block the main thread (it also delivers the mouse): what the socket won't take now
// waits in ctlOut and goes when it drains. A helper that stops reading altogether is dropped.
- (void)ctlSend:(NSString *)line {
 if(self.ctlFd<0)return;
 [self.ctlOut appendData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
 if(self.ctlOut.length>(8u<<20)){fprintf(stderr,"CONTROL dropped peer: not reading\n");[self ctlClose];return;}
 if(!self.writeSource)[self ctlFlush];
}
- (void)ctlFlush {
 while(self.ctlFd>=0&&self.ctlOut.length){
  ssize_t n=write(self.ctlFd,self.ctlOut.bytes,self.ctlOut.length);
  if(n>0){[self.ctlOut replaceBytesInRange:NSMakeRange(0,n) withBytes:NULL length:0];continue;}
  if(n<0&&errno==EAGAIN){
   if(!self.writeSource){dispatch_source_t ws=dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE,self.ctlFd,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(ws,^{[self ctlFlush];});self.writeSource=ws;dispatch_resume(ws);}
   return;}
  [self ctlClose];return;
 }
 if(self.writeSource){dispatch_source_cancel(self.writeSource);self.writeSource=nil;}
}
// The Mac's battery changed (or a minute passed): tell the guest, which shows it as its own.
- (void)sendBattery {if(self.ctlFd>=0)[self ctlSend:batteryLine()];}
static void batteryChanged(void *context) {[(__bridge App *)context sendBattery];}
- (void)watchBattery {
 CFRunLoopSourceRef src=IOPSNotificationCreateRunLoopSource(batteryChanged,(__bridge void *)self);
 if(src){CFRunLoopAddSource(CFRunLoopGetMain(),src,kCFRunLoopDefaultMode);CFRelease(src);}
 [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *t){[self sendBattery];}];
}
- (void)ctlClose {
 if(self.writeSource){dispatch_source_cancel(self.writeSource);self.writeSource=nil;}
 [self.ctlOut setLength:0];
 if(self.readSource){dispatch_source_cancel(self.readSource);self.readSource=nil;} // the cancel handler closes the fd
 self.ctlFd=-1;
 [self.view releaseCapture];self.view.absolute=NO;self.view.wantsLock=NO;[self.view resetTouchpad];[self.view setHostCursorHidden:NO];fprintf(stderr,"CONTROL disconnected\n");[self updateSubtitle];
}
- (void)updateSubtitle {
 if(self.view.locked)self.window.subtitle=@"Mouse locked by an Android app • ⌃⌥ releases";
 else if(self.view.captured)self.window.subtitle=@"Mouse captured • ⌃⌥ releases";
 else if(self.view.absolute)self.window.subtitle=self.view.wantsLock?@"Click to give the mouse back to the Android app":@"⌃⌘F full screen • ⌘, settings";
 else if(self.view.relativeAllowed)self.window.subtitle=@"Click to capture • ⌃⌥ releases";
 else self.window.subtitle=@"Waiting for Android to link the pointer…";
}
// The pointer is automatic: the Mac cursor drives Android's pointer through the helper, and the
// mouse locks only while an Android app holds pointer capture; trackpad gestures (two fingers or
// more) go to Android's touchpad. Without the helper link, it is the emulated USB mouse instead:
// click to capture, Control+Option releases.
- (void)applyPointerMode {
 [self.view releaseCapture];
 self.view.absolute=self.ctlFd>=0;
 [self updateSubtitle];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item{if(item.action==@selector(restartVM:))return self.vmTask!=nil;if(item.action==@selector(takeScreenshot:))return self.display.texture!=nil;return YES;}

// Settings window. Pointer mode applies immediately; the rest are read by the launcher the
// next time the VM starts (they are QEMU options), which the window says.
- (NSPopUpButton *)popup:(NSString *)key titles:(NSArray<NSString *> *)titles values:(NSArray *)values {
 NSPopUpButton *b=[NSPopUpButton new];b.identifier=key;b.target=self;b.action=@selector(settingChanged:);
 id current=[[NSUserDefaults standardUserDefaults] objectForKey:key];
 for(NSUInteger i=0;i<titles.count;i++){[b addItemWithTitle:titles[i]];b.lastItem.representedObject=values[i];if([values[i] isEqual:current])[b selectItemAtIndex:i];}
 return b;
}
- (NSTextField *)hint:(NSString *)text {
 NSTextField *h=[NSTextField wrappingLabelWithString:text];h.textColor=NSColor.secondaryLabelColor;h.font=[NSFont systemFontOfSize:NSFont.smallSystemFontSize];return h;
}
- (NSButton *)checkbox:(NSString *)key title:(NSString *)title {
 NSButton *b=[NSButton checkboxWithTitle:title target:self action:@selector(checkChanged:)];b.identifier=key;
 b.state=[[NSUserDefaults standardUserDefaults] boolForKey:key]?NSControlStateValueOn:NSControlStateValueOff;return b;
}
- (void)settingChanged:(NSPopUpButton *)sender {
 // The VM on the Mac's own network needs the bridge service first: set it up right here
 if([sender.identifier isEqualToString:@"Network"]&&[sender.selectedItem.representedObject isEqualToString:@"lan"]&&![self setUpNetworkBridge]){
  [sender selectItemAtIndex:[sender indexOfItemWithRepresentedObject:[[NSUserDefaults standardUserDefaults] stringForKey:@"Network"]]];return;}
 [[NSUserDefaults standardUserDefaults] setObject:sender.selectedItem.representedObject forKey:sender.identifier];
}
// "Same network as this Mac" needs a small root service (socket_vmnet, see run/lan-setup.sh):
// macOS lets only root attach a VM to a network interface. Installed once, with the usual macOS
// password prompt. YES when it's there.
static NSString *const kBridgeSocket=@"/var/run/googlebook-lan.sock";
static int bridgeVersion(NSString *path) {
 NSString *t=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
 NSTextCheckingResult *m=[[NSRegularExpression regularExpressionWithPattern:@"(?:VERSION=|version )([0-9]+)" options:0 error:nil] firstMatchInString:t?:@"" options:0 range:NSMakeRange(0,t.length)];
 return m?[t substringWithRange:[m rangeAtIndex:1]].intValue:0;
}
- (BOOL)setUpNetworkBridge {
 NSString *script=[NSBundle.mainBundle pathForResource:@"lan-setup" ofType:@"sh"];
 int installed=bridgeVersion(@"/Library/Application Support/Googlebook VM/lan-bridge.sh");
 BOOL present=[[NSFileManager defaultManager] fileExistsAtPath:kBridgeSocket]||[[NSFileManager defaultManager] fileExistsAtPath:@"/opt/homebrew/var/run/googlebook-lan.sock"];
 if(present&&installed>=bridgeVersion(script))return YES;
 NSAlert *a=[NSAlert new];
 a.messageText=present?@"Update the network service?":@"Put Android on this Mac's network?";
 a.informativeText=present?@"This version keeps Android on your network when the Mac's Wi-Fi reconnects or changes. macOS will ask for your password.":
                           @"Android then joins your Wi-Fi as one more device, so your phone can find it. Googlebook VM installs a small network service for this, once; macOS will ask for your password.";
 [a addButtonWithTitle:@"Install"];[a addButtonWithTitle:@"Cancel"];
 if([a runModal]!=NSAlertFirstButtonReturn)return NO;
 // The downloadable app brings its own socket_vmnet; a build from source uses Homebrew's
 NSString *vmnet=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"runtime/tools/socket_vmnet"];
 NSString *extra=[[NSFileManager defaultManager] isExecutableFileAtPath:vmnet]?[NSString stringWithFormat:@" & \" --vmnet \" & quoted form of \"%@\"",vmnet]:@"";
 NSString *src=[NSString stringWithFormat:@"do shell script \"/bin/bash \" & quoted form of \"%@\"%@ with administrator privileges",script,extra];
 NSDictionary *err=nil;NSAppleEventDescriptor *r=[[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
 if(r&&[[NSFileManager defaultManager] fileExistsAtPath:kBridgeSocket])return YES;
 if([err[NSAppleScriptErrorNumber] intValue]==-128)return present;   // cancelled: an old service still works
 NSAlert *f=[NSAlert new];f.messageText=@"Couldn't set up the network service";
 f.informativeText=err[NSAppleScriptErrorMessage]?:@"See /var/log/googlebook-lan.log.";[f runModal];
 return NO;
}
- (void)checkChanged:(NSButton *)sender {
 [[NSUserDefaults standardUserDefaults] setBool:sender.state==NSControlStateValueOn forKey:sender.identifier];
 if([sender.identifier isEqualToString:@"MacSwipes"]){
  // The first time, macOS asks for the Accessibility permission; the swipes follow once it's given.
  if(sender.state==NSControlStateValueOn&&!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES})){
   __block int tries=0;dispatch_source_t t=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
   dispatch_source_set_timer(t,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),2*NSEC_PER_SEC,NSEC_PER_SEC/4);
   dispatch_source_set_event_handler(t,^{if(AXIsProcessTrusted()||++tries>150){dispatch_source_cancel(t);[self updateSwipeTap];}});
   dispatch_resume(t);}
  [self updateSwipeTap];}
}
// Mac trackpad swipes with three or four fingers (Mission Control, Spaces, App Exposé) reach the Dock
// as their own events (type 30), apart from the touches this window gets. While the app is in
// front and the pointer is over Android, an event tap holds them back, so the swipe is Android's
// alone. Only those events: everything else passes untouched.
static CGEventRef swipeTapped(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *info){
 App *app=(__bridge App *)info;
 if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){if(app.swipeTap)CGEventTapEnable(app.swipeTap,true);return event;}
 VMView *v=app.view;
 if(type==30&&v.inside&&v.absolute&&!v.locked&&[v padActive])return NULL;
 return event;
}
- (void)updateSwipeTap {
 BOOL want=[[NSUserDefaults standardUserDefaults] boolForKey:@"MacSwipes"]&&NSApp.isActive&&AXIsProcessTrusted();
 if(want&&!self.swipeTap){
  self.swipeTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,CGEventMaskBit(30),swipeTapped,(__bridge void *)self);
  if(!self.swipeTap)return;
  CFRunLoopSourceRef src=CFMachPortCreateRunLoopSource(NULL,self.swipeTap,0);CFRunLoopAddSource(CFRunLoopGetMain(),src,kCFRunLoopCommonModes);CFRelease(src);
 }else if(!want&&self.swipeTap){CGEventTapEnable(self.swipeTap,false);CFMachPortInvalidate(self.swipeTap);CFRelease(self.swipeTap);self.swipeTap=NULL;}
}
- (void)applicationDidBecomeActive:(NSNotification *)n {[self updateSwipeTap];[self.view refreshHostCursor];}
- (void)applicationDidResignActive:(NSNotification *)n {[self updateSwipeTap];[self.view refreshHostCursor];}
- (void)showSettings:(id)sender {
 if(!self.settingsWindow){
  NSTextField *(^label)(NSString *)=^NSTextField *(NSString *t){NSTextField *l=[NSTextField labelWithString:t];l.alignment=NSTextAlignmentRight;return l;};
  NSTextField *note=[self hint:@"Display, memory, processor and network changes apply when the VM restarts."];
  // Memory up to what leaves macOS 8 GB, cores up to all of this Mac's
  NSMutableArray *memTitles=[NSMutableArray array],*memValues=[NSMutableArray array],*cpuTitles=[NSMutableArray array],*cpuValues=[NSMutableArray array];
  unsigned long long mac=NSProcessInfo.processInfo.physicalMemory>>30;
  for(NSNumber *g in @[@4,@6,@8,@12,@16,@24,@32,@48,@64])if(g.intValue==4||g.unsignedLongLongValue+8<=mac){[memTitles addObject:[NSString stringWithFormat:@"%@ GB",g]];[memValues addObject:@(g.intValue*1024)];}
  for(NSNumber *n in @[@2,@4,@6,@8,@10,@12,@16,@20,@24])if(n.unsignedIntegerValue<=NSProcessInfo.processInfo.processorCount){[cpuTitles addObject:n.stringValue];[cpuValues addObject:n];}
  NSBox *(^line)(void)=^NSBox *{NSBox *b=[NSBox new];b.boxType=NSBoxSeparator;return b;};
  NSGridView *grid=[NSGridView gridViewWithViews:@[
   @[label(@"Resolution:"),[self popup:@"Resolution" titles:@[@"Match this Mac's display",@"1920 × 1080 (16:9)",@"2560 × 1440 (16:9)",@"3840 × 2160 (16:9, 4K)",@"3440 × 1440 (21:9 ultrawide)",@"1920 × 1200 (16:10)",@"2560 × 1600 (16:10)",@"3024 × 1890 (16:10)",@"3456 × 2160 (16:10)"] values:@[@"native",@"1920x1080",@"2560x1440",@"3840x2160",@"3440x1440",@"1920x1200",@"2560x1600",@"3024x1890",@"3456x2160"]]],
   @[[NSGridCell emptyContentView],[self checkbox:@"StartFullscreen" title:@"Start in full screen"]],
   @[label(@"Memory:"),[self popup:@"MemoryMiB" titles:memTitles values:memValues]],
   @[label(@"Processor cores:"),[self popup:@"CPUs" titles:cpuTitles values:cpuValues]],
   @[label(@"Android storage:"),[NSStackView stackViewWithViews:@[[NSTextField labelWithString:[NSString stringWithFormat:@"%ld GB",(long)[[self storage:@[]] integerValue]]],[NSButton buttonWithTitle:@"Change…" target:self action:@selector(changeStorage:)]]]],
   @[label(@"Network:"),[self popup:@"Network" titles:@[@"Through this Mac",@"On this Mac's network (phones nearby can find it)"] values:@[@"full",@"lan"]]],
   @[[NSGridCell emptyContentView],note],
   @[[NSGridCell emptyContentView],[NSButton buttonWithTitle:@"Restart VM Now" target:self action:@selector(restartVM:)]],
   @[line(),line()],
   @[label(@"Trackpad:"),[self checkbox:@"MacSwipes" title:@"Three- and four-finger swipes go to Android, not Mission Control or Spaces,\nwhile the pointer is over Android (needs Accessibility permission)"]]]];
  grid.rowSpacing=8;grid.columnSpacing=10;grid.translatesAutoresizingMaskIntoConstraints=NO;
  [grid columnAtIndex:0].xPlacement=NSGridCellPlacementTrailing;
  NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,400) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  w.title=@"Googlebook Settings";w.releasedWhenClosed=NO;[w.contentView addSubview:grid];
  [NSLayoutConstraint activateConstraints:@[[grid.topAnchor constraintEqualToAnchor:w.contentView.topAnchor constant:20],[grid.leadingAnchor constraintEqualToAnchor:w.contentView.leadingAnchor constant:20],[grid.trailingAnchor constraintLessThanOrEqualToAnchor:w.contentView.trailingAnchor constant:-20],[grid.bottomAnchor constraintLessThanOrEqualToAnchor:w.contentView.bottomAnchor constant:-20]]];
  [w center];self.settingsWindow=w;
 }
 [self.view releaseCapture];[self.settingsWindow makeKeyAndOrderFront:nil];
}
- (BOOL)pushClipboard {
 if(self.ctlFd<0)return NO;
 NSString *t=[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];if(!t.length||t.length>100000)return NO;
 [self ctlSend:[@"C " stringByAppendingString:[[t dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]]];return self.ctlFd>=0;
}
- (void)ctlLine:(NSString *)line {
 if([line hasPrefix:@"w "]){self.view.wheelReady=[line isEqualToString:@"w wheel"];fprintf(stderr,"CONTROL wheel %s\n",line.UTF8String+2);return;}
 if([line hasPrefix:@"p "]){self.view.touchpadReady=[line isEqualToString:@"p touchpad"];fprintf(stderr,"CONTROL touchpad %s\n",line.UTF8String+2);return;}
 if([line hasPrefix:@"k "]){self.view.wantsLock=[line isEqualToString:@"k 1"];fprintf(stderr,"CONTROL pointer capture %s\n",self.view.wantsLock?"requested":"released");
  if(self.view.wantsLock)[self.view lockForApp];else [self.view unlock];[self updateSubtitle];return;}
 if([line hasPrefix:@"d "]){[self storageFree:[line componentsSeparatedByString:@" "]];return;}
 // Text copied in Android goes to the Mac clipboard
 if([line hasPrefix:@"c "]&&[[NSUserDefaults standardUserDefaults] boolForKey:@"GuestClipboardToMac"]){
  NSData *d=[[NSData alloc] initWithBase64EncodedString:[line substringFromIndex:2] options:0];NSString *t=d?[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]:nil;
  if(t.length){NSPasteboard *pb=[NSPasteboard generalPasteboard];[pb clearContents];[pb setString:t forType:NSPasteboardTypeString];}
 }
}
// The Mac's keyboard layout, so Android types the same characters (the helper picks its closest
// layout): on each link, and whenever the input source changes.
- (void)sendKeyboardLayout {
 TISInputSourceRef src=TISCopyCurrentKeyboardLayoutInputSource();if(!src)return;
 NSString *sid=(__bridge NSString *)TISGetInputSourceProperty(src,kTISPropertyInputSourceID);
 if(sid.length&&[sid rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location==NSNotFound)[self ctlSend:[@"L " stringByAppendingString:sid]];
 CFRelease(src);
}
- (void)watchKeyboardLayout {
 [[NSDistributedNotificationCenter defaultCenter] addObserverForName:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){[self sendKeyboardLayout];}];
}
// Android's storage, as the helper reports it. The first report of a run means Android is up and
// the disk works, so a backup of the previous disk (from an update or a storage change) can go;
// and when less than a tenth is left, offer more, once a run.
- (void)storageFree:(NSArray<NSString *> *)f {
 if(f.count<3)return;long long avail=f[1].longLongValue,total=f[2].longLongValue;if(total<=0)return;
 if(!self.backupDropped&&self.workDir){self.backupDropped=YES;
  NSString *b=[self.workDir stringByAppendingPathComponent:@"image/googlebook.raw.before-update"];
  if([[NSFileManager defaultManager] removeItemAtPath:b error:nil])fprintf(stderr,"STORAGE dropped the previous disk's backup\n");}
 if(self.storageWarned||avail*10>=total)return;
 self.storageWarned=YES;
 NSAlert *a=[NSAlert new];a.messageText=@"Android is running out of storage";
 a.informativeText=[NSString stringWithFormat:@"%.1f GB of %.0f GB left. Android can get a bigger storage, but it starts over empty, as after a factory reset.",avail/1024.0,total/1024.0];
 [a addButtonWithTitle:@"Not Now"];[a addButtonWithTitle:@"Change Storage…"];
 [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSAlertSecondButtonReturn)[self changeStorage:nil];}];
}
- (NSString *)ctlHmac:(NSString *)msg {
 const char *tk=getenv("VM_INPUT_TOKEN");NSData *m=[msg dataUsingEncoding:NSUTF8StringEncoding];unsigned char mac[CC_SHA256_DIGEST_LENGTH];
 CCHmac(kCCHmacAlgSHA256,tk,strlen(tk),m.bytes,m.length,mac);
 NSMutableString *h=[NSMutableString stringWithCapacity:2*sizeof mac];for(size_t i=0;i<sizeof mac;i++)[h appendFormat:@"%02x",mac[i]];return h;
}
- (void)ctlDrop:(dispatch_source_t)rs {
 if(rs==self.readSource){[self ctlClose];return;}
 [self.ctlPending removeObject:rs];dispatch_source_cancel(rs);
}
- (void)startControlServer {
 self.ctlFd=-1;self.ctlPending=[NSMutableArray array];self.acceptSources=[NSMutableArray array];signal(SIGPIPE,SIG_IGN);
 [self listenControlAt:htonl(INADDR_LOOPBACK) onlyVM:NO];
}
// The pointer link listens on loopback, which QEMU's user networking reaches. A VM on the Mac's
// own network (--lan) comes from that network instead: there, only the VM's network card may
// connect (by its MAC address, from the Mac's ARP table), and it still has to prove the token.
- (BOOL)listenControlAt:(in_addr_t)addr onlyVM:(BOOL)onlyVM {
 const char *pe=getenv("VM_INPUT_PORT");int port=pe?atoi(pe):27183;if(port<=0)return NO;
 int ls=socket(AF_INET,SOCK_STREAM,0),one=1;setsockopt(ls,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one);
 struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons(port),.sin_addr.s_addr=addr};
 if(bind(ls,(struct sockaddr *)&a,sizeof a)||listen(ls,1)){fprintf(stderr,"CONTROL listen failed on %d\n",port);close(ls);
  if(onlyVM)return NO;   // the Mac's network address may not be up yet: tried again shortly
  self.window.subtitle=[NSString stringWithFormat:@"Pointer link unavailable: port %d is in use by another program",port];return NO;}
 dispatch_source_t acceptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,ls,0,dispatch_get_main_queue());
 [self.acceptSources addObject:acceptSource];
 dispatch_source_set_event_handler(acceptSource,^{
  struct sockaddr_in peer;socklen_t pl=sizeof peer;
  int fd=accept(ls,(struct sockaddr *)&peer,&pl);if(fd<0)return;
  if(onlyVM&&!isVMAddress(peer.sin_addr)){char ip[INET_ADDRSTRLEN];fprintf(stderr,"CONTROL refused %s: not the VM\n",inet_ntop(AF_INET,&peer.sin_addr,ip,sizeof ip));close(fd);return;}
  // No token, no link. Drop the oldest waiting peer so held open sockets can't lock the helper out.
  const char *tk=getenv("VM_INPUT_TOKEN");if(!tk||!*tk){close(fd);return;}
  while(self.ctlPending.count>=8)[self ctlDrop:self.ctlPending.firstObject];
  int yes=1;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof yes);
  unsigned char nb[16];arc4random_buf(nb,sizeof nb);
  NSMutableString *hostNonce=[NSMutableString string];for(size_t i=0;i<sizeof nb;i++)[hostNonce appendFormat:@"%02x",nb[i]];
  NSData *hello=[[NSString stringWithFormat:@"N %@\n",hostNonce] dataUsingEncoding:NSUTF8StringEncoding];
  if(write(fd,hello.bytes,hello.length)!=(ssize_t)hello.length){close(fd);return;}
  dispatch_source_t rs=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_main_queue());
  dispatch_source_set_cancel_handler(rs,^{close(fd);});
  [self.ctlPending addObject:rs];
  NSMutableData *buffer=[NSMutableData data];__block BOOL authed=NO;
  dispatch_source_set_event_handler(rs,^{
   char buf[65536];ssize_t n=read(fd,buf,sizeof buf);if(n<0&&errno==EAGAIN)return;if(n<=0){[self ctlDrop:rs];return;}
   [buffer appendBytes:buf length:n];
   while(1){const char *b=buffer.bytes;const char *nl=memchr(b,'\n',buffer.length);if(!nl)break;
    NSString *line=[[NSString alloc] initWithBytes:b length:nl-b encoding:NSUTF8StringEncoding];
    [buffer replaceBytesInRange:NSMakeRange(0,nl-b+1) withBytes:NULL length:0];
    if(authed){if(line)[self ctlLine:line];continue;}
    // Expect "a <guest-nonce> <HMAC(token, gbos-guest:<host-nonce>:<guest-nonce>)>".
    NSArray<NSString *> *p=[line componentsSeparatedByString:@" "];
    NSData *got=p.count==3&&[p[0] isEqualToString:@"a"]&&p[1].length==32&&[p[1] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound?[p[2] dataUsingEncoding:NSUTF8StringEncoding]:nil;
    NSData *want=got?[[self ctlHmac:[NSString stringWithFormat:@"gbos-guest:%@:%@",hostNonce,p[1]]] dataUsingEncoding:NSUTF8StringEncoding]:nil;
    if(!got||got.length!=want.length||timingsafe_bcmp(got.bytes,want.bytes,want.length)){fprintf(stderr,"CONTROL rejected peer: bad token\n");[self ctlDrop:rs];return;}
    authed=YES;[self.ctlPending removeObject:rs];
    if(self.ctlFd>=0)[self ctlClose];
    self.ctlFd=fd;self.readSource=rs;self.ctlOut=[NSMutableData data];fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);
    [self ctlSend:[@"A " stringByAppendingString:[self ctlHmac:[NSString stringWithFormat:@"gbos-host:%@:%@",p[1],hostNonce]]]];
    [self.view resetTouchpad];[self applyPointerMode];
    fprintf(stderr,"CONTROL connected\n");[self updateSubtitle];
    [self ctlSend:batteryLine()];[self sendKeyboardLayout];[self ctlSend:@"W 0 0"];  // creates the guest's high-resolution wheel
   }
   // Cap the line length, much lower before the token is proven.
   if(buffer.length>(authed?(2u<<20):512u)){fprintf(stderr,"CONTROL dropped peer: line too long\n");[self ctlDrop:rs];}
  });
  dispatch_resume(rs);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
   if([self.ctlPending containsObject:rs]){fprintf(stderr,"CONTROL dropped peer: no token\n");[self ctlDrop:rs];}
  });
 });
 dispatch_resume(acceptSource);char ip[INET_ADDRSTRLEN];fprintf(stderr,"CONTROL listening on %s:%d\n",inet_ntop(AF_INET,&a.sin_addr,ip,sizeof ip),port);
 return YES;
}
// Command V is the only time Mac clipboard text goes to the guest.
- (void)pasteIntoGuest:(id)sender{
 if(![self pushClipboard]){NSBeep();return;}  // no helper link yet, or nothing to paste
 [self ctlSend:@"K 279"];
}
- (void)windowDidResignKey:(NSNotification *)n{[self.view releaseCapture];
 // Until the pointer comes back over Android, the Mac cursor is the one to see
 if(n.object==self.window&&!self.view.locked){self.view.inside=NO;[self.view setHostCursorHidden:NO];}}
- (void)windowDidBecomeKey:(NSNotification *)n{[self.view refreshHostCursor];}
// The mouse over another app's window that sits on top of this one (a notification, a prompt
// that didn't take the focus): that window gets the events, so this view never hears the pointer
// leave. A global monitor sees exactly those events; the Mac cursor comes back for them.
- (void)watchOtherWindows {
 __weak App *weak=self;
 [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved|NSEventMaskLeftMouseDragged|NSEventMaskRightMouseDragged handler:^(NSEvent *e){
  VMView *v=weak.view;if(v.inside&&!v.locked){v.inside=NO;[v setHostCursorHidden:NO];v.sendLine(@"X");}}];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return NO;}
- (void)windowWillClose:(NSNotification *)n{if(n.object==self.window||(n.object==self.setupWindow&&!self.window))[NSApp terminate:nil];}
- (void)applicationWillTerminate:(NSNotification *)n{[self.bluetooth stop];[self.view releaseCapture];[self.connection disconnect];}
- (void)spiceConnected:(CSConnection *)c{fprintf(stderr,"SPICE connected\n");}
- (void)spiceDisconnected:(CSConnection *)c{dispatch_async(dispatch_get_main_queue(),^{[self.view releaseCapture];self.window.subtitle=@"VM disconnected";});}
- (void)spiceInputAvailable:(CSConnection *)c input:(CSInput *)i{dispatch_async(dispatch_get_main_queue(),^{self.view.input=i;[i requestMouseMode:YES];});}
- (void)spiceInputUnavailable:(CSConnection *)c input:(CSInput *)i{dispatch_async(dispatch_get_main_queue(),^{[self.view releaseCapture];self.view.input=nil;});}
- (void)spiceError:(CSConnection *)c code:(CSConnectionError)code message:(NSString *)message{fprintf(stderr,"SPICE error %s\n",message.UTF8String);dispatch_async(dispatch_get_main_queue(),^{self.window.subtitle=message;});}
- (void)spiceDisplayCreated:(CSConnection *)c display:(CSDisplay *)d{dispatch_async(dispatch_get_main_queue(),^{self.display=d;[d addRenderer:self.renderer];[self fit];[self updateSubtitle];fprintf(stderr,"DISPLAY created %.0fx%.0f GL=%d\n",d.displaySize.width,d.displaySize.height,d.isGLEnabled);});}
- (void)spiceDisplayUpdated:(CSConnection *)c display:(CSDisplay *)d{dispatch_async(dispatch_get_main_queue(),^{[self fit];});}
- (void)spiceDisplayDestroyed:(CSConnection *)c display:(CSDisplay *)d{dispatch_async(dispatch_get_main_queue(),^{[d removeRenderer:self.renderer];self.display=nil;});}
- (void)spiceAgentConnected:(CSConnection *)c supportingFeatures:(CSConnectionAgentFeature)f{}
- (void)spiceAgentDisconnected:(CSConnection *)c{}
- (void)spiceForwardedPortOpened:(CSConnection *)c port:(CSPort *)p{}
- (void)spiceForwardedPortClosed:(CSConnection *)c port:(CSPort *)p{}
@end
int main(int argc,char **argv){@autoreleasepool {
 // The downloadable app finds UTM's libraries in its work folder: start over with them in reach
 if(!spiceLoaded()&&!getenv("GBOS_REEXEC")){
  NSString *fw=[workFolder() stringByAppendingPathComponent:@"UTM-beta/UTM.app/Contents/Frameworks"];
  char exe[PATH_MAX];uint32_t size=sizeof exe;
  if([[NSFileManager defaultManager] fileExistsAtPath:fw]&&!_NSGetExecutablePath(exe,&size)){
   setenv("DYLD_FRAMEWORK_PATH",fw.fileSystemRepresentation,1);setenv("GBOS_REEXEC","1",1);execv(exe,argv);}
 }
 unsetenv("GBOS_REEXEC");
 if(argc>3){fprintf(stderr,"Usage: GooglebookViewer [/absolute/path/to/spice.sock [--fullscreen]]\n");return 2;}
 NSApplication *app=[NSApplication sharedApplication];[app setActivationPolicy:NSApplicationActivationPolicyRegular];
 // Menu bar. Actions have no target, so they reach the app delegate through the responder chain.
 NSMenu *bar=[NSMenu new];
 NSMenu *(^add)(NSString *)=^NSMenu *(NSString *title){NSMenuItem *it=[bar addItemWithTitle:title action:nil keyEquivalent:@""];NSMenu *m=[[NSMenu alloc] initWithTitle:title];it.submenu=m;return m;};
 NSMenu *appMenu=add(@"Googlebook");
 [appMenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
 [appMenu addItem:[NSMenuItem separatorItem]];
 NSMenuItem *rs=[appMenu addItemWithTitle:@"Restart VM" action:@selector(restartVM:) keyEquivalent:@"r"];rs.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;
 NSMenuItem *ss=[appMenu addItemWithTitle:@"Take Screenshot" action:@selector(takeScreenshot:) keyEquivalent:@"s"];ss.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;
 [appMenu addItemWithTitle:@"Shut Down and Quit" action:@selector(terminate:) keyEquivalent:@"q"];
 NSMenu *editMenu=add(@"Edit");
 [editMenu addItemWithTitle:@"Paste into Guest" action:@selector(pasteIntoGuest:) keyEquivalent:@"v"];
 NSMenu *viewMenu=add(@"View");
 NSMenuItem *fs=[viewMenu addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFull:) keyEquivalent:@"f"];fs.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;
 app.mainMenu=bar;
 App *delegate=[App new];if(argc>=2&&argv[1][0]=='/')delegate.socketPath=[NSString stringWithUTF8String:argv[1]];delegate.startFullscreen=argc==3&&!strcmp(argv[2],"--fullscreen");app.delegate=delegate;[app run];return 0;
}}
