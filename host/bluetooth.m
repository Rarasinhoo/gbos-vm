// Bluetooth LE devices near this Mac, shown to Android.
//
// macOS doesn't let a VM have the Mac's Bluetooth radio, but Android in the VM has a virtual one
// (netsimd, run by run_vm.py --bluetooth), and every connection to netsimd's raw HCI port is
// another controller on that same virtual radio. So for each BLE device the Mac sees, this
// opens one, and acts there as that device: it advertises what CoreBluetooth heard the device
// advertise, accepts Android's connection, and serves the real device's GATT database through
// CoreBluetooth (reads, writes, notifications and indications). Android sees a twin with a
// stable made-up address (CoreBluetooth never reveals the real one).
//
// The link to Android is not encrypted and doesn't pair: a characteristic that needs it is
// paired by macOS on the Mac's own link, so it still works, but an app that insists on bonding
// with Android itself won't. Classic Bluetooth (audio, keyboards) isn't relayed: those already
// work through the Mac.
#import "bluetooth.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <CommonCrypto/CommonDigest.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static const NSUInteger kMaxMirrors = 16, kMaxMirrorsWithPhones = 32;
static const NSTimeInterval kForgetAfter = 60;   // seconds without an advertisement
static const uint16_t kServerMTU = 247;

// The relay's log: WORK/logs/RUN_NAME/bluetooth.log (names and addresses stay out of it)
static FILE *logFile;
static void GBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void GBLog(NSString *format, ...) {
 if(!logFile)return;
 va_list a;va_start(a,format);NSString *m=[[NSString alloc] initWithFormat:format arguments:a];va_end(a);
 fprintf(logFile,"%s %s\n",[NSDate.date descriptionWithLocale:nil].UTF8String,m.UTF8String);fflush(logFile);
}

#pragma mark - Small helpers

static void put16(NSMutableData *d, uint16_t v) {uint8_t b[2]={v&0xff,v>>8};[d appendBytes:b length:2];}
static void put8(NSMutableData *d, uint8_t v) {[d appendBytes:&v length:1];}
static uint16_t get16(const uint8_t *p) {return p[0]|(p[1]<<8);}
// A CBUUID as ATT wants it: 2 bytes for a 16-bit UUID, 16 bytes (little endian) otherwise.
static NSData *uuidBytes(CBUUID *u) {
 NSData *d=u.data;
 if(d.length==2){const uint8_t *b=d.bytes;uint8_t le[2]={b[1],b[0]};return [NSData dataWithBytes:le length:2];}
 NSMutableData *full=[NSMutableData data];
 if(d.length==4){const uint8_t base[12]={0x00,0x00,0x10,0x00,0x80,0x00,0x00,0x80,0x5f,0x9b,0x34,0xfb};[full appendData:d];[full appendBytes:base length:12];}
 else [full appendData:d];
 uint8_t le[16];const uint8_t *b=full.bytes;for(int i=0;i<16;i++)le[i]=b[15-i];
 return [NSData dataWithBytes:le length:16];
}
static CBUUID *uuidFrom(const uint8_t *p, NSUInteger len) {
 uint8_t be[16];for(NSUInteger i=0;i<len;i++)be[i]=p[len-1-i];
 return [CBUUID UUIDWithData:[NSData dataWithBytes:be length:len]];
}
// A descriptor's value as bytes (CoreBluetooth hands some over as strings or numbers).
static NSData *descriptorBytes(id v) {
 if([v isKindOfClass:NSData.class])return v;
 if([v isKindOfClass:NSString.class])return [v dataUsingEncoding:NSUTF8StringEncoding];
 if([v isKindOfClass:NSNumber.class]){uint16_t n=[v unsignedShortValue];return [NSData dataWithBytes:&n length:2];}
 return [NSData data];
}

#pragma mark - One attribute in a twin's GATT database

typedef NS_ENUM(int, GBAttrKind) {GBAttrStatic, GBAttrValue, GBAttrDescriptor, GBAttrCCCD};
@interface GBAttr : NSObject
@property(nonatomic) uint16_t handle, endGroup;   // endGroup: for service declarations
@property(nonatomic,strong) CBUUID *type;
@property(nonatomic) GBAttrKind kind;
@property(nonatomic,strong) NSData *value;       // static attributes, and the last value read
@property(nonatomic,strong,nullable) CBCharacteristic *characteristic;
@property(nonatomic,strong,nullable) CBDescriptor *descriptor;
@property(nonatomic) uint16_t cccd;              // GBAttrCCCD: what Android wrote
@end
@implementation GBAttr
@end

#pragma mark - One twin: a virtual controller acting as one real device

@class GBBluetoothRelay, GBListener;
@interface GBMirror : NSObject<CBPeripheralDelegate>
@property(nonatomic,strong) CBPeripheral *peripheral;
@property(nonatomic,strong) NSDictionary *advertisement;
@property(nonatomic) NSTimeInterval lastSeen;
@property(nonatomic,weak) GBBluetoothRelay *relay;
- (BOOL)openOnPort:(int)port queue:(dispatch_queue_t)q;
- (NSData *)address;
- (void)updateAdvertisement:(NSDictionary *)ad;
- (BOOL)connected;
- (void)close;
- (void)macConnected;
- (void)macDisconnected:(nullable NSError *)error;
@end

@interface GBBluetoothRelay ()<CBCentralManagerDelegate,CBPeripheralManagerDelegate>
@property(nonatomic) int port;
@property(nonatomic) BOOL phones;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong,nullable) CBCentralManager *central;
@property(nonatomic,strong) NSMutableDictionary<NSUUID *,GBMirror *> *mirrors;
@property(nonatomic,strong,nullable) dispatch_source_t sweep;
@property(nonatomic,strong,nullable) CBPeripheralManager *advertiser;
@property(nonatomic,strong,nullable) GBListener *listener;
@property(nonatomic,strong,nullable) NSDictionary *advertising;   // what the Mac advertises for Android
- (void)androidAdvertises:(nullable NSString *)name services:(NSArray<CBUUID *> *)services;
- (NSSet<NSData *> *)twinAddresses;
- (void)connectMac:(GBMirror *)m;
- (void)disconnectMac:(GBMirror *)m;
@end

@implementation GBMirror {
 int _fd;
 dispatch_source_t _read;
 NSMutableData *_in;                     // H4 bytes from the controller not parsed yet
 NSMutableArray<NSData *> *_commands;    // HCI commands waiting for the controller to take them
 BOOL _commandOut;
 uint16_t _aclLen, _aclCredits;
 NSMutableArray<NSData *> *_aclOut;
 int _conn;                              // connection handle, -1 when none
 NSMutableData *_l2cap;                  // a PDU being reassembled
 NSUInteger _l2capWant;
 uint16_t _mtu;
 NSData *_advData, *_scanData;
 BOOL _advertising, _extended;
 NSMutableArray<GBAttr *> *_attrs;       // nil until the real device's database is discovered
 NSUInteger _discovering;
 NSMutableArray<NSData *> *_attQueue;    // requests from Android waiting for the database or a reply
 BOOL _attBusy;                          // a request is waiting on CoreBluetooth
 GBAttr *_pending;                       // ... for this attribute
 uint8_t _pendingOp;
 uint16_t _pendingOffset;
 NSUInteger _waitSerial;
}

- (instancetype)init {
 if((self=[super init])){_fd=-1;_conn=-1;_mtu=23;_aclLen=27;_aclCredits=1;_in=[NSMutableData data];_commands=[NSMutableArray array];
  _aclOut=[NSMutableArray array];_attQueue=[NSMutableArray array];}
 return self;
}

- (BOOL)connected {return _conn>=0;}

// A stable random static address for this device (two top bits set), from its CoreBluetooth id
- (NSData *)address {
 NSData *idb=[self.peripheral.identifier.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
 uint8_t h[CC_SHA256_DIGEST_LENGTH];CC_SHA256(idb.bytes,(CC_LONG)idb.length,h);
 h[5]|=0xc0;
 return [NSData dataWithBytes:h length:6];
}

- (BOOL)openOnPort:(int)port queue:(dispatch_queue_t)q {
 _fd=socket(AF_INET,SOCK_STREAM,0);
 struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons(port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
 if(_fd<0||connect(_fd,(struct sockaddr *)&a,sizeof a)){if(_fd>=0)close(_fd);_fd=-1;return NO;}
 int one=1;setsockopt(_fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof one);setsockopt(_fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof one);
 int fd=_fd;
 _read=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,q);
 __weak GBMirror *weak=self;
 dispatch_source_set_event_handler(_read,^{
  uint8_t buf[4096];ssize_t n=read(fd,buf,sizeof buf);
  GBMirror *m=weak;if(!m)return;
  if(n<=0){if(n<0&&errno==EAGAIN)return;[m close];return;}
  [m received:buf length:n];
 });
 dispatch_source_set_cancel_handler(_read,^{close(fd);});
 dispatch_resume(_read);
 // Reset; all events, LE ones too; buffer sizes; then advertise as the real device.
 [self command:0x0c03 params:nil];
 [self command:0x0c01 params:[NSData dataWithBytes:(uint8_t[]){0xff,0xff,0xff,0xff,0xff,0xff,0xbf,0x3d} length:8]];
 [self command:0x2001 params:[NSData dataWithBytes:(uint8_t[]){0x1f,0x0a,0,0,0,0,0,0} length:8]];
 [self command:0x2002 params:nil];
 [self command:0x2005 params:[self address]];
 [self updateAdvertisement:self.advertisement];
 return YES;
}

- (void)close {
 if(_read){dispatch_source_cancel(_read);_read=nil;}
 _fd=-1;
 if(_conn>=0){_conn=-1;[self.relay disconnectMac:self];}
}

#pragma mark HCI

- (void)write:(NSData *)d {
 if(_fd<0)return;
 const uint8_t *p=d.bytes;size_t left=d.length;
 while(left){ssize_t n=write(_fd,p,left);if(n<0){if(errno==EINTR)continue;if(errno==EAGAIN){usleep(1000);continue;}[self close];return;}p+=n;left-=n;}
}
- (void)command:(uint16_t)op params:(nullable NSData *)params {
 NSMutableData *d=[NSMutableData dataWithBytes:(uint8_t[]){1} length:1];put16(d,op);put8(d,(uint8_t)params.length);if(params)[d appendData:params];
 [_commands addObject:d];[self pumpCommands];
}
- (void)pumpCommands {
 if(_commandOut||!_commands.count)return;
 _commandOut=YES;NSData *d=_commands.firstObject;[_commands removeObjectAtIndex:0];[self write:d];
}

- (void)received:(const uint8_t *)b length:(size_t)n {
 [_in appendBytes:b length:n];
 while(_in.length){
  const uint8_t *p=_in.bytes;size_t have=_in.length,need;
  if(p[0]==4){if(have<3)return;need=3+p[2];}
  else if(p[0]==2){if(have<5)return;need=5+get16(p+3);}
  else {[_in setLength:0];return;}   // out of step: drop it all
  if(have<need)return;
  if(p[0]==4)[self event:p[1] data:p+3 length:p[2]];else [self acl:p+1 length:need-1];
  [_in replaceBytesInRange:NSMakeRange(0,need) withBytes:NULL length:0];
 }
}

- (void)event:(uint8_t)code data:(const uint8_t *)p length:(size_t)len {
 switch(code){
  case 0x0e: case 0x0f: {   // command complete, command status
   uint16_t op=code==0x0e?get16(p+1):get16(p+2);
   if(code==0x0e&&op==0x2002&&len>=7){uint16_t l=get16(p+4);if(l)_aclLen=l;if(p[6])_aclCredits=p[6];}
   uint8_t status=code==0x0e?(len>3?p[3]:0):p[0];
   if(status&&op!=0x200a)GBLog(@"command %04x failed: %02x",op,status);
   _commandOut=NO;[self pumpCommands];break;}
  case 0x13: {              // packets the controller has sent: room for more
   for(uint8_t i=0;i<p[0]&&len>=1+4*(i+1);i++)_aclCredits+=get16(p+3+4*i);
   [self pumpAcl];break;}
  case 0x05:                // disconnected
   if(len>=3&&get16(p+1)==_conn){_conn=-1;_attrs=nil;[_attQueue removeAllObjects];_attBusy=NO;_pending=nil;
    [self.relay disconnectMac:self];_advertising=NO;[self advertise];}
   break;
  case 0x3e: {              // LE meta
   uint8_t sub=p[0];
   if((sub==0x01||sub==0x0a)&&len>=4&&p[1]==0){
    _conn=get16(p+2);_mtu=23;_l2cap=nil;_attrs=nil;_advertising=NO;
    [self.relay connectMac:self];
   }
   break;}
 }
}

#pragma mark Advertising

// What CoreBluetooth heard, as advertising data. In a classic (legacy) advertisement when it
// fits, the rest in its scan response (CoreBluetooth reports both together); otherwise in one
// extended advertisement of up to 251 bytes, as Nearby's beacons often need. A controller
// takes one kind or the other until it is reset, so a twin that outgrows the classic one is
// reset and starts over extended.
- (void)updateAdvertisement:(NSDictionary *)ad {
 self.advertisement=ad;
 NSMutableArray<NSData *> *items=[NSMutableArray array];
 void (^item)(uint8_t,NSData *)=^(uint8_t type,NSData *v){if(v.length>240)v=[v subdataWithRange:NSMakeRange(0,240)];
  NSMutableData *d=[NSMutableData data];put8(d,(uint8_t)v.length+1);put8(d,type);[d appendData:v];[items addObject:d];};
 NSMutableData *u16=[NSMutableData data],*u128=[NSMutableData data];
 for(CBUUID *u in ad[CBAdvertisementDataServiceUUIDsKey]){NSData *b=uuidBytes(u);[(b.length==2?u16:u128) appendData:b];}
 if(u16.length)item(0x03,u16);
 if(u128.length)item(0x07,u128);
 // Service data: AD type 0x16 for a 16-bit UUID, 0x21 for a 128-bit one
 NSDictionary<CBUUID *,NSData *> *sd=ad[CBAdvertisementDataServiceDataKey];
 for(CBUUID *u in sd){NSData *ub=uuidBytes(u);NSMutableData *d=[NSMutableData dataWithData:ub];[d appendData:sd[u]];item(ub.length==2?0x16:0x21,d);}
 NSData *mfr=ad[CBAdvertisementDataManufacturerDataKey];if(mfr.length)item(0xff,mfr);
 NSNumber *tx=ad[CBAdvertisementDataTxPowerLevelKey];if(tx){int8_t t=tx.charValue;item(0x0a,[NSData dataWithBytes:&t length:1]);}
 NSString *name=ad[CBAdvertisementDataLocalNameKey]?:self.peripheral.name;
 if(name.length)item(0x09,[name dataUsingEncoding:NSUTF8StringEncoding]);
 NSMutableData *adv=[NSMutableData dataWithBytes:(uint8_t[]){2,1,6} length:3],*scan=[NSMutableData data];
 BOOL fits=YES;
 for(NSData *d in items){if(adv.length+d.length<=31)[adv appendData:d];else if(scan.length+d.length<=31)[scan appendData:d];else fits=NO;}
 if(!fits){   // one extended advertisement with everything
  adv=[NSMutableData dataWithBytes:(uint8_t[]){2,1,6} length:3];scan=[NSMutableData data];
  for(NSData *d in items)if(adv.length+d.length<=251)[adv appendData:d];
 }
 if([adv isEqualToData:_advData?:[NSData data]]&&[scan isEqualToData:_scanData?:[NSData data]])return;
 BOOL first=_advData==nil;_advData=adv;_scanData=scan;
 if(_fd<0)return;
 BOOL connectable=[ad[CBAdvertisementDataIsConnectable] boolValue];
 if(!fits&&!_extended){
  _extended=YES;first=YES;
  GBLog(@"a device needs an extended advertisement (%lu bytes)",(unsigned long)adv.length);
  if(_advertising||_conn>=0){
   // Start over in extended mode (a connected twin finishes that first: tried again on update)
   if(_conn>=0){_extended=NO;_advData=nil;return;}
   _advertising=NO;
   [self command:0x0c03 params:nil];
   [self command:0x0c01 params:[NSData dataWithBytes:(uint8_t[]){0xff,0xff,0xff,0xff,0xff,0xff,0xbf,0x3d} length:8]];
   [self command:0x2001 params:[NSData dataWithBytes:(uint8_t[]){0x1f,0x0a,0x02,0,0,0,0,0} length:8]];
   [self command:0x2002 params:nil];
  }
 }
 if(_extended){
  if(first){
   // Set 0: connectable or not; scannable can't go with connectable here, and needn't
   NSMutableData *p=[NSMutableData data];put8(p,0);put16(p,connectable?0x0001:0x0000);
   uint8_t interval[3]={0xa0,0,0};[p appendBytes:interval length:3];[p appendBytes:interval length:3];
   put8(p,7);put8(p,1);put8(p,0);[p appendBytes:(uint8_t[6]){0} length:6];put8(p,0);put8(p,0x7f);put8(p,1);put8(p,0);put8(p,1);put8(p,0);put8(p,0);
   [self command:0x2036 params:p];
   NSMutableData *r=[NSMutableData dataWithBytes:(uint8_t[]){0} length:1];[r appendData:[self address]];[self command:0x2035 params:r];
  }
  NSMutableData *d=[NSMutableData data];put8(d,0);put8(d,3);put8(d,1);put8(d,(uint8_t)adv.length);[d appendData:adv];
  [self command:0x2037 params:d];
  [self advertise];
  return;
 }
 if(first){
  // ADV_IND when Android may connect, else ADV_SCAN_IND (scannable) or ADV_NONCONN_IND
  uint8_t type=connectable?0:(scan.length?2:3);
  NSMutableData *p=[NSMutableData data];put16(p,0xa0);put16(p,0xa0);put8(p,type);put8(p,1);put8(p,0);[p appendBytes:(uint8_t[6]){0} length:6];put8(p,7);put8(p,0);
  [self command:0x2006 params:p];
 }
 NSMutableData *a=[NSMutableData data];put8(a,(uint8_t)adv.length);[a appendData:adv];[a setLength:32];[self command:0x2008 params:a];
 NSMutableData *s=[NSMutableData data];put8(s,(uint8_t)scan.length);[s appendData:scan];[s setLength:32];[self command:0x2009 params:s];
 [self advertise];
}
- (void)advertise {
 if(_advertising||_conn>=0||_fd<0||!_advData)return;
 _advertising=YES;
 if(_extended)[self command:0x2039 params:[NSData dataWithBytes:(uint8_t[]){1,1,0,0,0,0} length:6]];
 else [self command:0x200a params:[NSData dataWithBytes:(uint8_t[]){1} length:1]];
}

#pragma mark L2CAP

- (void)acl:(const uint8_t *)p length:(size_t)len {
 if(len<4)return;
 uint16_t hf=get16(p),dl=get16(p+2);uint8_t pb=(hf>>12)&3;const uint8_t *d=p+4;
 if((hf&0x0fff)!=_conn||dl>len-4)return;
 if(pb==2||pb==0){
  if(dl<4)return;
  _l2capWant=get16(d)+4;_l2cap=[NSMutableData dataWithBytes:d length:dl];
 } else if(_l2cap) [_l2cap appendBytes:d length:dl];
 if(_l2cap&&_l2cap.length>=_l2capWant){
  const uint8_t *q=_l2cap.bytes;uint16_t cid=get16(q+2);
  NSData *pdu=[_l2cap subdataWithRange:NSMakeRange(4,_l2capWant-4)];_l2cap=nil;
  if(cid==4)[self attRequest:pdu];
  else if(cid==5)[self signaling:pdu];
  else if(cid==6)[self send:6 payload:[NSData dataWithBytes:(uint8_t[]){0x05,0x05} length:2]];   // SMP: pairing not supported
 }
}
- (void)signaling:(NSData *)pdu {
 if(pdu.length<4)return;const uint8_t *p=pdu.bytes;uint8_t code=p[0],ident=p[1];
 if(code==0x01||code==0x13||!(code&1))return;      // rejects and responses need no answer
 NSMutableData *r=[NSMutableData data];put8(r,0x01);put8(r,ident);put16(r,2);put16(r,0);   // command not understood
 [self send:5 payload:r];
}
- (void)send:(uint16_t)cid payload:(NSData *)payload {
 if(_conn<0)return;
 NSMutableData *pdu=[NSMutableData data];put16(pdu,(uint16_t)payload.length);put16(pdu,cid);[pdu appendData:payload];
 for(NSUInteger off=0;off<pdu.length;off+=_aclLen){
  NSUInteger n=MIN((NSUInteger)_aclLen,pdu.length-off);
  NSMutableData *a=[NSMutableData dataWithBytes:(uint8_t[]){2} length:1];
  put16(a,(uint16_t)(_conn|((off?1:0)<<12)));put16(a,(uint16_t)n);[a appendData:[pdu subdataWithRange:NSMakeRange(off,n)]];
  [_aclOut addObject:a];
 }
 [self pumpAcl];
}
- (void)pumpAcl {
 while(_aclCredits&&_aclOut.count){_aclCredits--;NSData *a=_aclOut.firstObject;[_aclOut removeObjectAtIndex:0];[self write:a];}
}

#pragma mark The GATT database, from CoreBluetooth

- (void)macConnected {
 self.peripheral.delegate=self;
 _discovering=1;[self.peripheral discoverServices:nil];
}
- (void)macDisconnected:(NSError *)error {
 // The real device went away: so does Android's connection to its twin.
 if(_conn>=0){NSMutableData *p=[NSMutableData data];put16(p,(uint16_t)_conn);put8(p,0x13);[self command:0x0406 params:p];}
}
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)error {
 for(CBService *s in p.services){_discovering++;[p discoverCharacteristics:nil forService:s];}
 [self discovered];
}
- (void)peripheral:(CBPeripheral *)p didDiscoverCharacteristicsForService:(CBService *)s error:(NSError *)error {
 for(CBCharacteristic *c in s.characteristics){_discovering++;[p discoverDescriptorsForCharacteristic:c];}
 [self discovered];
}
- (void)peripheral:(CBPeripheral *)p didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {[self discovered];}
- (void)discovered {
 if(--_discovering)return;
 _attrs=[NSMutableArray array];
 __block uint16_t h=1;
 GBAttr *(^add)(CBUUID *,GBAttrKind,NSData *)=^GBAttr *(CBUUID *t,GBAttrKind k,NSData *v){GBAttr *a=[GBAttr new];a.handle=h++;a.type=t;a.kind=k;a.value=v?:[NSData data];[self->_attrs addObject:a];return a;};
 CBUUID *primary=[CBUUID UUIDWithString:@"2800"],*secondary=[CBUUID UUIDWithString:@"2801"],*decl=[CBUUID UUIDWithString:@"2803"],*cccd=[CBUUID UUIDWithString:@"2902"];
 NSData *(^charDecl)(uint8_t,uint16_t,CBUUID *)=^NSData *(uint8_t props,uint16_t vh,CBUUID *u){NSMutableData *d=[NSMutableData data];put8(d,props);put16(d,vh);[d appendData:uuidBytes(u)];return d;};
 // CoreBluetooth hides the GAP and GATT services: the twin has its own (the name; no service-changed).
 GBAttr *gap=add(primary,GBAttrStatic,uuidBytes([CBUUID UUIDWithString:@"1800"]));
 add(decl,GBAttrStatic,charDecl(0x02,h+1,[CBUUID UUIDWithString:@"2A00"]));
 add([CBUUID UUIDWithString:@"2A00"],GBAttrStatic,[(self.peripheral.name?:@"") dataUsingEncoding:NSUTF8StringEncoding]);
 add(decl,GBAttrStatic,charDecl(0x02,h+1,[CBUUID UUIDWithString:@"2A01"]));
 add([CBUUID UUIDWithString:@"2A01"],GBAttrStatic,[NSData dataWithBytes:(uint8_t[]){0,0} length:2]);
 gap.endGroup=h-1;
 GBAttr *gatt=add(primary,GBAttrStatic,uuidBytes([CBUUID UUIDWithString:@"1801"]));gatt.endGroup=gatt.handle;
 for(CBService *s in self.peripheral.services){
  GBAttr *sa=add(s.isPrimary?primary:secondary,GBAttrStatic,uuidBytes(s.UUID));
  for(CBCharacteristic *c in s.characteristics){
   uint8_t props=(uint8_t)(c.properties&0xff);
   add(decl,GBAttrStatic,charDecl(props,h+1,c.UUID));
   GBAttr *v=add(c.UUID,GBAttrValue,nil);v.characteristic=c;
   BOOL hasCCCD=NO;
   for(CBDescriptor *d in c.descriptors){
    if([d.UUID isEqual:cccd]){hasCCCD=YES;GBAttr *a=add(cccd,GBAttrCCCD,nil);a.characteristic=c;continue;}
    GBAttr *a=add(d.UUID,GBAttrDescriptor,nil);a.descriptor=d;a.characteristic=c;
   }
   if(!hasCCCD&&(c.properties&(CBCharacteristicPropertyNotify|CBCharacteristicPropertyIndicate))){GBAttr *a=add(cccd,GBAttrCCCD,nil);a.characteristic=c;}
  }
  sa.endGroup=h-1;
 }
 GBLog(@"a device is ready for Android (%lu attributes)",(unsigned long)_attrs.count);
 [self nextAtt];
}

#pragma mark ATT server

- (void)attRequest:(NSData *)pdu {
 if(!pdu.length)return;
 uint8_t op=((const uint8_t *)pdu.bytes)[0];
 if(op==0x1e)return;                                // confirmation of an indication
 if(op==0x52||op==0xd2){[self attHandle:pdu];return;} // write command: no reply, never waits
 [_attQueue addObject:pdu];[self nextAtt];
}
- (void)nextAtt {
 while(_attrs&&!_attBusy&&_attQueue.count){NSData *pdu=_attQueue.firstObject;[_attQueue removeObjectAtIndex:0];[self attHandle:pdu];}
}
- (void)attError:(uint8_t)op handle:(uint16_t)h code:(uint8_t)code {
 NSMutableData *r=[NSMutableData data];put8(r,0x01);put8(r,op);put16(r,h);put8(r,code);[self send:4 payload:r];
}
- (GBAttr *)attr:(uint16_t)h {return h>=1&&h<=_attrs.count?_attrs[h-1]:nil;}
- (BOOL)isType:(GBAttr *)a uuid:(CBUUID *)u {return [a.type isEqual:u];}

- (void)attHandle:(NSData *)pdu {
 const uint8_t *p=pdu.bytes;NSUInteger n=pdu.length;uint8_t op=p[0];
 NSMutableData *r=[NSMutableData data];
 switch(op){
  case 0x02: {   // exchange MTU
   if(n<3)break;_mtu=MAX((uint16_t)23,MIN(get16(p+1),kServerMTU));
   put8(r,0x03);put16(r,kServerMTU);[self send:4 payload:r];return;}
  case 0x04: {   // find information
   if(n<5)break;uint16_t s=get16(p+1),e=get16(p+3);int fmt=0;put8(r,0x05);put8(r,0);
   for(GBAttr *a in _attrs){if(a.handle<s||a.handle>e)continue;NSData *u=uuidBytes(a.type);int f=u.length==2?1:2;
    if(!fmt)fmt=f;if(f!=fmt||r.length+2+u.length>_mtu)break;put16(r,a.handle);[r appendData:u];}
   if(!fmt){[self attError:op handle:s code:0x0a];return;}
   ((uint8_t *)r.mutableBytes)[1]=fmt;[self send:4 payload:r];return;}
  case 0x06: {   // find by type value: primary services with this UUID
   if(n<7)break;uint16_t s=get16(p+1),e=get16(p+3),t=get16(p+5);NSData *v=[pdu subdataWithRange:NSMakeRange(7,n-7)];put8(r,0x07);
   for(GBAttr *a in _attrs){if(a.handle<s||a.handle>e||t!=0x2800||![a.type isEqual:[CBUUID UUIDWithString:@"2800"]]||![a.value isEqualToData:v])continue;
    if(r.length+4>_mtu)break;put16(r,a.handle);put16(r,a.endGroup);}
   if(r.length==1){[self attError:op handle:s code:0x0a];return;}
   [self send:4 payload:r];return;}
  case 0x10: {   // read by group type: services
   if(n!=7&&n!=21)break;uint16_t s=get16(p+1),e=get16(p+3);CBUUID *t=uuidFrom(p+5,n-5);
   if(![t isEqual:[CBUUID UUIDWithString:@"2800"]]&&![t isEqual:[CBUUID UUIDWithString:@"2801"]]){[self attError:op handle:s code:0x10];return;}
   int len=0;put8(r,0x11);put8(r,0);
   for(GBAttr *a in _attrs){if(a.handle<s||a.handle>e||![a.type isEqual:t])continue;int l=4+(int)a.value.length;
    if(!len)len=l;if(l!=len||r.length+l>_mtu)break;put16(r,a.handle);put16(r,a.endGroup);[r appendData:a.value];}
   if(!len){[self attError:op handle:s code:0x0a];return;}
   ((uint8_t *)r.mutableBytes)[1]=len;[self send:4 payload:r];return;}
  case 0x08: {   // read by type: declarations, or one characteristic's value by its UUID
   if(n!=7&&n!=21)break;uint16_t s=get16(p+1),e=get16(p+3);CBUUID *t=uuidFrom(p+5,n-5);
   int len=0;put8(r,0x09);put8(r,0);
   for(GBAttr *a in _attrs){if(a.handle<s||a.handle>e||![a.type isEqual:t])continue;
    if(a.kind!=GBAttrStatic){[self read:a op:0x08 offset:0];return;}
    int l=2+(int)MIN(a.value.length,(NSUInteger)_mtu-4);if(!len)len=l;if(l!=len||r.length+l>_mtu)break;
    put16(r,a.handle);[r appendData:[a.value subdataWithRange:NSMakeRange(0,l-2)]];}
   if(!len){[self attError:op handle:s code:0x0a];return;}
   ((uint8_t *)r.mutableBytes)[1]=len;[self send:4 payload:r];return;}
  case 0x0a: case 0x0c: {   // read, read blob
   if(n<3)break;GBAttr *a=[self attr:get16(p+1)];if(!a){[self attError:op handle:get16(p+1) code:0x01];return;}
   uint16_t off=op==0x0c&&n>=5?get16(p+3):0;
   if(a.kind==GBAttrStatic||a.kind==GBAttrCCCD||(op==0x0c&&off>0&&a.value.length)){[self reply:a op:op offset:off];return;}
   [self read:a op:op offset:off];return;}
  case 0x12: case 0x52: {   // write request, write command
   if(n<3)break;GBAttr *a=[self attr:get16(p+1)];NSData *v=[pdu subdataWithRange:NSMakeRange(3,n-3)];
   if(!a){if(op==0x12)[self attError:op handle:get16(p+1) code:0x01];return;}
   if(a.kind==GBAttrCCCD){
    a.cccd=v.length>=2?get16(v.bytes):0;
    [self.peripheral setNotifyValue:a.cccd!=0 forCharacteristic:a.characteristic];
    if(op==0x12){put8(r,0x13);[self send:4 payload:r];}return;}
   if(a.kind==GBAttrValue){
    BOOL response=op==0x12;
    [self.peripheral writeValue:v forCharacteristic:a.characteristic type:response?CBCharacteristicWriteWithResponse:CBCharacteristicWriteWithoutResponse];
    if(response)[self wait:a op:op];return;}
   if(a.kind==GBAttrDescriptor&&op==0x12){[self.peripheral writeValue:v forDescriptor:a.descriptor];[self wait:a op:op];return;}
   if(op==0x12)[self attError:op handle:a.handle code:0x03];return;}
 }
 if(op!=0x52&&op!=0xd2)[self attError:op handle:0 code:0x06];   // request not supported
}

// Android's ATT gives up on a request after 30 s and drops the link. CoreBluetooth can take
// longer (macOS may be pairing with the device), so answer with an error first.
- (void)wait:(GBAttr *)a op:(uint8_t)op {
 _attBusy=YES;_pending=a;_pendingOp=op;NSUInteger serial=++_waitSerial;
 __weak GBMirror *weak=self;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(20*NSEC_PER_SEC)),self.relay.queue,^{
  GBMirror *m=weak;if(!m||!m->_attBusy||m->_pending!=a||m->_waitSerial!=serial)return;
  [m finish:a error:[NSError errorWithDomain:CBATTErrorDomain code:CBATTErrorInsufficientResources userInfo:nil]];
 });
}
- (void)read:(GBAttr *)a op:(uint8_t)op offset:(uint16_t)off {
 [self wait:a op:op];_pendingOffset=off;
 if(a.kind==GBAttrDescriptor)[self.peripheral readValueForDescriptor:a.descriptor];
 else [self.peripheral readValueForCharacteristic:a.characteristic];
}
- (void)reply:(GBAttr *)a op:(uint8_t)op offset:(uint16_t)off {
 NSData *v=a.value;if(a.kind==GBAttrCCCD){uint16_t c=a.cccd;v=[NSData dataWithBytes:&c length:2];}
 NSMutableData *r=[NSMutableData data];
 if(op==0x08){put8(r,0x09);NSUInteger l=MIN(v.length,(NSUInteger)_mtu-4);put8(r,(uint8_t)(2+l));put16(r,a.handle);[r appendData:[v subdataWithRange:NSMakeRange(0,l)]];}
 else {if(off>v.length){[self attError:op handle:a.handle code:0x07];return;}
  put8(r,op==0x0a?0x0b:0x0d);[r appendData:[v subdataWithRange:NSMakeRange(off,MIN(v.length-off,(NSUInteger)_mtu-1))]];}
 [self send:4 payload:r];
}
- (void)finish:(GBAttr *)a error:(NSError *)error {
 if(!_attBusy||_pending!=a)return;
 _attBusy=NO;_pending=nil;
 // CoreBluetooth's ATT errors carry the ATT error code itself
 if(error)[self attError:_pendingOp handle:a.handle code:[error.domain isEqualToString:CBATTErrorDomain]?(uint8_t)error.code:0x0e];
 else if(_pendingOp==0x12){NSMutableData *r=[NSMutableData data];put8(r,0x13);[self send:4 payload:r];}
 else [self reply:a op:_pendingOp offset:_pendingOffset];
 [self nextAtt];
}
- (GBAttr *)attrFor:(CBCharacteristic *)c kind:(GBAttrKind)k {for(GBAttr *a in _attrs)if(a.characteristic==c&&a.kind==k)return a;return nil;}

- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
 GBAttr *a=[self attrFor:c kind:GBAttrValue];if(!a)return;
 if(!error)a.value=c.value?:[NSData data];
 if(_attBusy&&_pending==a){[self finish:a error:error];return;}
 // Not asked for: a notification or an indication, sent on if Android subscribed
 GBAttr *cc=[self attrFor:c kind:GBAttrCCCD];if(error||!cc||!cc.cccd)return;
 NSMutableData *r=[NSMutableData data];put8(r,(cc.cccd&1)?0x1b:0x1d);put16(r,a.handle);
 [r appendData:[a.value subdataWithRange:NSMakeRange(0,MIN(a.value.length,(NSUInteger)_mtu-3))]];[self send:4 payload:r];
}
- (void)peripheral:(CBPeripheral *)p didWriteValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {[self finish:[self attrFor:c kind:GBAttrValue] error:error];}
- (void)peripheral:(CBPeripheral *)p didUpdateValueForDescriptor:(CBDescriptor *)d error:(NSError *)error {
 for(GBAttr *a in _attrs)if(a.descriptor==d){if(!error)a.value=descriptorBytes(d.value);[self finish:a error:error];return;}
}
- (void)peripheral:(CBPeripheral *)p didWriteValueForDescriptor:(CBDescriptor *)d error:(NSError *)error {
 for(GBAttr *a in _attrs)if(a.descriptor==d){[self finish:a error:error];return;}
}
@end

#pragma mark - The other way: what Android advertises, from the Mac

// One more controller on the VM's radio, only listening. Every advertisement on it that isn't
// one of the twins' comes from Android, and the Mac advertises it in turn through its own
// radio, as far as macOS lets an app: a name and service UUIDs, no service or maker data.
@interface GBListener : NSObject
@property(nonatomic,weak) GBBluetoothRelay *relay;
- (BOOL)openOnPort:(int)port queue:(dispatch_queue_t)q;
- (void)close;
@end
@implementation GBListener {
 int _fd;
 dispatch_source_t _read;
 NSMutableData *_in;
 NSMutableArray<NSData *> *_commands;
 BOOL _commandOut;
 NSString *_name;
 NSMutableOrderedSet<CBUUID *> *_services;
 NSMutableSet<NSString *> *_dropped;   // advertisement types macOS can't carry, logged once
 NSTimeInterval _lastHeard;
 dispatch_source_t _tick;
}
- (BOOL)openOnPort:(int)port queue:(dispatch_queue_t)q {
 _fd=socket(AF_INET,SOCK_STREAM,0);_in=[NSMutableData data];_commands=[NSMutableArray array];
 _services=[NSMutableOrderedSet orderedSet];_dropped=[NSMutableSet set];
 struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons(port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
 if(_fd<0||connect(_fd,(struct sockaddr *)&a,sizeof a)){if(_fd>=0)close(_fd);_fd=-1;return NO;}
 int one=1;setsockopt(_fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof one);
 int fd=_fd;__weak GBListener *weak=self;
 _read=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,q);
 dispatch_source_set_event_handler(_read,^{uint8_t buf[4096];ssize_t n=read(fd,buf,sizeof buf);GBListener *l=weak;if(!l)return;
  if(n<=0){if(n<0&&errno==EAGAIN)return;[l close];return;}[l received:buf length:n];});
 dispatch_source_set_cancel_handler(_read,^{close(fd);});
 dispatch_resume(_read);
 // Reset; LE events; passive scan, every advertisement (no duplicate filtering)
 [self command:0x0c03 params:nil];
 [self command:0x0c01 params:[NSData dataWithBytes:(uint8_t[]){0xff,0xff,0xff,0xff,0xff,0xff,0xbf,0x3d} length:8]];
 [self command:0x2001 params:[NSData dataWithBytes:(uint8_t[]){0x1f,0,0,0,0,0,0,0} length:8]];
 NSMutableData *sp=[NSMutableData data];put8(sp,0);put16(sp,0x30);put16(sp,0x30);put8(sp,0);put8(sp,0);[self command:0x200b params:sp];
 [self command:0x200c params:[NSData dataWithBytes:(uint8_t[]){1,0} length:2]];
 // What Android stopped advertising, the Mac stops advertising too
 _tick=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,q);
 dispatch_source_set_timer(_tick,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),2*NSEC_PER_SEC,NSEC_PER_SEC/4);
 dispatch_source_set_event_handler(_tick,^{GBListener *l=weak;if(!l)return;
  if(CFAbsoluteTimeGetCurrent()-l->_lastHeard>10){l->_name=nil;[l->_services removeAllObjects];}
  [l.relay androidAdvertises:l->_name services:l->_services.array];});
 dispatch_resume(_tick);
 return YES;
}
- (void)close {
 if(_tick){dispatch_source_cancel(_tick);_tick=nil;}
 if(_read){dispatch_source_cancel(_read);_read=nil;}
 _fd=-1;
}
- (void)command:(uint16_t)op params:(nullable NSData *)params {
 NSMutableData *d=[NSMutableData dataWithBytes:(uint8_t[]){1} length:1];put16(d,op);put8(d,(uint8_t)params.length);if(params)[d appendData:params];
 [_commands addObject:d];[self pump];
}
- (void)pump {
 if(_commandOut||!_commands.count||_fd<0)return;
 _commandOut=YES;NSData *d=_commands.firstObject;[_commands removeObjectAtIndex:0];
 if(write(_fd,d.bytes,d.length)!=(ssize_t)d.length)[self close];
}
- (void)received:(const uint8_t *)b length:(size_t)n {
 [_in appendBytes:b length:n];
 while(_in.length>=3){
  const uint8_t *p=_in.bytes;
  if(p[0]!=4){[_in setLength:0];return;}
  size_t need=3+p[2];if(_in.length<need)return;
  if(p[1]==0x0e||p[1]==0x0f){_commandOut=NO;[self pump];}
  else if(p[1]==0x3e&&p[2]>=2&&p[3]==0x02)[self reports:p+4 length:need-4];
  [_in replaceBytesInRange:NSMakeRange(0,need) withBytes:NULL length:0];
 }
}
- (void)reports:(const uint8_t *)p length:(size_t)len {
 if(len<1)return;
 NSSet<NSData *> *twins=[self.relay twinAddresses];
 size_t q=1;
 for(uint8_t i=0;i<p[0]&&q+9<=len;i++){
  NSData *addr=[NSData dataWithBytes:p+q+2 length:6];uint8_t dl=p[q+8];
  if(q+9+dl>len)return;
  const uint8_t *d=p+q+9;
  if(![twins containsObject:addr]){
   _lastHeard=CFAbsoluteTimeGetCurrent();
   for(size_t k=0;k+1<dl&&d[k];k+=d[k]+1){
    uint8_t n=d[k],t=d[k+1];const uint8_t *v=d+k+2;size_t vl=n-1;
    if(k+1+n>dl)break;
    if(t==0x08||t==0x09)_name=[[NSString alloc] initWithBytes:v length:vl encoding:NSUTF8StringEncoding];
    else if(t==0x02||t==0x03)for(size_t j=0;j+1<vl;j+=2)[_services addObject:uuidFrom(v+j,2)];
    else if(t==0x06||t==0x07)for(size_t j=0;j+15<vl;j+=16)[_services addObject:uuidFrom(v+j,16)];
    else if(t!=0x01&&t!=0x0a){
     NSString *what=t==0x16&&vl>=2?[NSString stringWithFormat:@"service data %@",uuidFrom(v,2).UUIDString]:t==0xff&&vl>=2?[NSString stringWithFormat:@"maker data %04x",get16(v)]:[NSString stringWithFormat:@"type %02x",t];
     if(![_dropped containsObject:what]){[_dropped addObject:what];GBLog(@"Android advertises %@, which macOS won't let the Mac advertise",what);}
    }
   }
  }
  q+=10+dl;
 }
}
@end

#pragma mark - The relay: CoreBluetooth's view of the neighbourhood

@implementation GBBluetoothRelay
- (instancetype)initWithHCIPort:(int)port log:(NSString *)path phones:(BOOL)phones {
 if(!logFile)logFile=fopen(path.fileSystemRepresentation,"a");
 if((self=[super init])){_phones=phones;_port=port;_queue=dispatch_queue_create("bluetooth relay",DISPATCH_QUEUE_SERIAL);_mirrors=[NSMutableDictionary dictionary];}
 return self;
}
- (void)start {
 dispatch_async(self.queue,^{
  if(self.central)return;
  self.central=[[CBCentralManager alloc] initWithDelegate:self queue:self.queue options:@{CBCentralManagerOptionShowPowerAlertKey:@NO}];
  self.sweep=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
  dispatch_source_set_timer(self.sweep,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),10*NSEC_PER_SEC,NSEC_PER_SEC);
  dispatch_source_set_event_handler(self.sweep,^{[self forgetStale];});
  dispatch_resume(self.sweep);
  self.listener=[GBListener new];self.listener.relay=self;
  if(![self.listener openOnPort:self.port queue:self.queue])self.listener=nil;
  self.advertiser=[[CBPeripheralManager alloc] initWithDelegate:self queue:self.queue options:@{CBPeripheralManagerOptionShowPowerAlertKey:@NO}];
 });
}
- (NSSet<NSData *> *)twinAddresses {
 NSMutableSet *s=[NSMutableSet set];
 // Advertising reports carry addresses least significant byte first, as the twins set them
 for(GBMirror *m in self.mirrors.allValues)[s addObject:m.address];
 return s;
}
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)p {
 if(p.state==CBManagerStatePoweredOn&&self.advertising)[p startAdvertising:self.advertising];
}
- (void)androidAdvertises:(NSString *)name services:(NSArray<CBUUID *> *)services {
 NSMutableDictionary *ad=[NSMutableDictionary dictionary];
 if(name.length)ad[CBAdvertisementDataLocalNameKey]=name;
 if(services.count)ad[CBAdvertisementDataServiceUUIDsKey]=services;
 if(!ad.count)ad=nil;
 if((ad==nil&&self.advertising==nil)||[ad isEqualToDictionary:self.advertising])return;
 self.advertising=ad;
 if(self.advertiser.state!=CBManagerStatePoweredOn)return;
 [self.advertiser stopAdvertising];
 if(ad){[self.advertiser startAdvertising:ad];GBLog(@"the Mac advertises for Android: %@%lu services",name.length?@"its name, ":@"",(unsigned long)services.count);}
 else GBLog(@"Android stopped advertising");
}
- (void)stop {
 dispatch_sync(self.queue,^{
  if(self.sweep){dispatch_source_cancel(self.sweep);self.sweep=nil;}
  [self.central stopScan];
  for(GBMirror *m in self.mirrors.allValues){[m close];if(m.peripheral.state!=CBPeripheralStateDisconnected)[self.central cancelPeripheralConnection:m.peripheral];}
  [self.mirrors removeAllObjects];self.central.delegate=nil;self.central=nil;
  [self.listener close];self.listener=nil;
  [self.advertiser stopAdvertising];self.advertiser.delegate=nil;self.advertiser=nil;
 });
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)c {
 if(c.state==CBManagerStatePoweredOn){
  GBLog(@"relaying BLE devices near this Mac to Android");
  [c scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@YES}];
 } else if(c.state==CBManagerStateUnauthorized) GBLog(@"not allowed (System Settings > Privacy & Security > Bluetooth)");
}
// Worth showing: accessories. Computers and phones nearby announce themselves all the time for
// their own device-to-device features: Apple's (0x004C) or Microsoft's (0x0006) maker data, or
// Google's Quick Share and Nearby services. They are other people's machines more often than
// not, and nothing an Android app pairs with.
// With phones on (Settings: your own Android phone, for Quick Share and Better Together),
// Google's device-to-device services are relayed too; Apple's and Microsoft's never are.
static BOOL worthRelaying(NSDictionary *ad, CBPeripheral *p, BOOL phones) {
 NSData *m=ad[CBAdvertisementDataManufacturerDataKey];
 uint16_t company=m.length>=2?get16(m.bytes):0xffff;
 if(company==0x004c||company==0x0006)return NO;
 NSArray<CBUUID *> *sharing=@[[CBUUID UUIDWithString:@"FCF1"],[CBUUID UUIDWithString:@"FEF3"],[CBUUID UUIDWithString:@"FE9F"]];
 for(CBUUID *u in sharing)if([ad[CBAdvertisementDataServiceUUIDsKey] containsObject:u]||ad[CBAdvertisementDataServiceDataKey][u])return phones;
 return [ad[CBAdvertisementDataLocalNameKey] length]||p.name.length||[ad[CBAdvertisementDataServiceUUIDsKey] count]||[ad[CBAdvertisementDataServiceDataKey] count]||m.length>=2;
}
- (void)centralManager:(CBCentralManager *)c didDiscoverPeripheral:(CBPeripheral *)p advertisementData:(NSDictionary *)ad RSSI:(NSNumber *)rssi {
 GBMirror *m=self.mirrors[p.identifier];
 if(!m){
  if(!worthRelaying(ad,p,self.phones)||self.mirrors.count>=(self.phones?kMaxMirrorsWithPhones:kMaxMirrors))return;
  m=[GBMirror new];m.peripheral=p;m.advertisement=ad;m.relay=self;
  if(![m openOnPort:self.port queue:self.queue]){GBLog(@"the VM's Bluetooth controller isn't reachable");return;}
  self.mirrors[p.identifier]=m;
  // What kind of device, for tuning worthRelaying (no names or addresses)
  NSData *mfr=ad[CBAdvertisementDataManufacturerDataKey];
  GBLog(@"relaying a device: company %@, services %@, service data %@, connectable %@",
        mfr.length>=2?[NSString stringWithFormat:@"%04x",get16(mfr.bytes)]:@"none",
        [[ad[CBAdvertisementDataServiceUUIDsKey] valueForKey:@"UUIDString"] componentsJoinedByString:@","]?:@"",
        [[[ad[CBAdvertisementDataServiceDataKey] allKeys] valueForKey:@"UUIDString"] componentsJoinedByString:@","]?:@"",
        ad[CBAdvertisementDataIsConnectable]);
 } else {
  NSMutableDictionary *merged=[m.advertisement mutableCopy];[merged addEntriesFromDictionary:ad];[m updateAdvertisement:merged];
 }
 m.lastSeen=CFAbsoluteTimeGetCurrent();
}
- (void)forgetStale {
 NSTimeInterval now=CFAbsoluteTimeGetCurrent();
 for(NSUUID *k in self.mirrors.allKeys){GBMirror *m=self.mirrors[k];if(m.connected||now-m.lastSeen<kForgetAfter)continue;[m close];[self.mirrors removeObjectForKey:k];}
}
- (void)connectMac:(GBMirror *)m {
 GBLog(@"Android connected to a device");
 if(m.peripheral.state==CBPeripheralStateConnected)[m macConnected];else [self.central connectPeripheral:m.peripheral options:nil];
}
- (void)disconnectMac:(GBMirror *)m {
 if(m.peripheral.state!=CBPeripheralStateDisconnected)[self.central cancelPeripheralConnection:m.peripheral];
}
- (void)centralManager:(CBCentralManager *)c didConnectPeripheral:(CBPeripheral *)p {[self.mirrors[p.identifier] macConnected];}
- (void)centralManager:(CBCentralManager *)c didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)e {[self.mirrors[p.identifier] macDisconnected:e];}
- (void)centralManager:(CBCentralManager *)c didDisconnectPeripheral:(CBPeripheral *)p error:(NSError *)e {[self.mirrors[p.identifier] macDisconnected:e];}
@end
