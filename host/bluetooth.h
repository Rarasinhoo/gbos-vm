// Bluetooth LE devices near this Mac, shown to Android: see bluetooth.m.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GBBluetoothRelay : NSObject
/// port: the raw HCI port of the VM's virtual Bluetooth controller (netsimd --hci-port);
/// log: a file to append what it does to; phones: relay Android phones too (their Nearby
/// and Quick Share beacons; normally left out: they are mostly other people's)
- (instancetype)initWithHCIPort:(int)port log:(NSString *)log phones:(BOOL)phones;
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
