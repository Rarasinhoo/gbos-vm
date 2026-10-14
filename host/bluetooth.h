// Bluetooth LE devices near this Mac, shown to Android: see bluetooth.m.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GBBluetoothRelay : NSObject
/// port: the raw HCI port of the VM's virtual Bluetooth controller (netsimd --hci-port);
/// log: a file to append what it does to
- (instancetype)initWithHCIPort:(int)port log:(NSString *)log;
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
