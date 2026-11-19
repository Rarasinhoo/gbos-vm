// Switch a Realtek USB Wi-Fi adapter out of its 0bda:1a2b driver-CD mode, the way
// usb_modeswitch's StandardEject does: Bulk-Only CBWs for PREVENT/ALLOW MEDIUM REMOVAL (allow)
// and START STOP UNIT (LoEj=1), reading the CSW after each. macOS's storage driver can leave
// the bulk endpoints halted, so they are cleared first. Detaching that driver needs root.
// Polls every 100 ms for 2 minutes, so it can be started before the adapter is plugged in.
// If every send times out, the CD side is wedged: replug the adapter while this runs.
// Build: cc -O2 -o work/tools/rtl_eject tools-src/rtl_eject.c -I/opt/homebrew/include \
//          -L/opt/homebrew/lib -lusb-1.0      Run: sudo work/tools/rtl_eject
#include <libusb-1.0/libusb.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static unsigned tag = 0x12345678;

static int command(libusb_device_handle *h, unsigned char out, unsigned char in,
                   const unsigned char *cdb, int cdb_len, const char *name) {
    unsigned char cbw[31] = {0x55,0x53,0x42,0x43};
    memcpy(cbw + 4, &tag, 4); tag++;
    cbw[14] = cdb_len;
    memcpy(cbw + 15, cdb, cdb_len);
    int n = 0, r = libusb_bulk_transfer(h, out, cbw, sizeof cbw, &n, 1500);
    printf("  %s CBW: %s (%d bytes)\n", name, libusb_error_name(r), n);
    if (r) return r;
    unsigned char csw[13];
    r = libusb_bulk_transfer(h, in, csw, sizeof csw, &n, 1500);
    if (r == LIBUSB_ERROR_PIPE) { libusb_clear_halt(h, in); r = libusb_bulk_transfer(h, in, csw, sizeof csw, &n, 1500); }
    printf("  %s CSW: %s (%d bytes, status %d)\n", name, libusb_error_name(r), n, n == 13 ? csw[12] : -1);
    return 0;   // a missing CSW is normal when the device switches away
}

static int attempt(libusb_context *ctx) {
    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, 0x0bda, 0x1a2b);
    if (!h) return 1;
    struct libusb_config_descriptor *cfg;
    if (libusb_get_active_config_descriptor(libusb_get_device(h), &cfg)) { libusb_close(h); return 1; }
    const struct libusb_interface_descriptor *alt = &cfg->interface[0].altsetting[0];
    unsigned char out = 0, in = 0;
    for (int i = 0; i < alt->bNumEndpoints; i++) {
        const struct libusb_endpoint_descriptor *e = &alt->endpoint[i];
        if ((e->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
        if (e->bEndpointAddress & 0x80) in = e->bEndpointAddress; else out = e->bEndpointAddress;
    }
    libusb_free_config_descriptor(cfg);
    printf("attempt: bulk OUT 0x%02x, IN 0x%02x\n", out, in);
    if (!out || !in) { libusb_close(h); return 1; }

    int r = libusb_detach_kernel_driver(h, 0);
    if (r && r != LIBUSB_ERROR_NOT_FOUND) { printf("  detach: %s\n", libusb_error_name(r)); libusb_close(h); return 1; }
    if ((r = libusb_claim_interface(h, 0))) { printf("  claim: %s\n", libusb_error_name(r)); libusb_close(h); return 1; }
    printf("  clear halt OUT: %s, IN: %s\n", libusb_error_name(libusb_clear_halt(h, out)), libusb_error_name(libusb_clear_halt(h, in)));

    const unsigned char allow[6] = {0x1e, 0, 0, 0, 0, 0};
    const unsigned char eject[6] = {0x1b, 0, 0, 0, 0x02, 0};
    r = command(h, out, in, allow, 6, "allow-removal");
    if (!r) r = command(h, out, in, eject, 6, "eject");
    libusb_release_interface(h, 0);
    libusb_close(h);
    return r ? 1 : 0;
}

int main(void) {
    libusb_context *ctx;
    if (libusb_init(&ctx)) { fprintf(stderr, "libusb_init failed\n"); return 1; }
    for (int i = 0; i < 1200; i++) {
        if (attempt(ctx) == 0) { printf("eject sent\n"); libusb_exit(ctx); return 0; }
        usleep(100000);
    }
    fprintf(stderr, "gave up\n");
    libusb_exit(ctx);
    return 1;
}
