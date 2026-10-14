# gbos-vm

Runs a real Googlebook OS image in a VM on an Apple Silicon Mac — GPU-accelerated, with Chrome working.

It's not an emulator image or a generic Android build. The install script downloads Google's own recovery image for the Dell Googlebook (ARM64, Android 17), swaps the hardware-specific bits for virtual ones, and boots it under QEMU with [gfxstream](https://android.googlesource.com/platform/hardware/google/gfxstream): Android's Vulkan and OpenGL ES run on the Mac's GPU, through MoltenVK and Metal, and frames reach the window without a trip through the CPU.

> This isn't affiliated with Google or Dell, and it's not a verified Googlebook. Read [System Structure](#system-structure) before you sign into anything.

## Quick start

```bash
git clone https://github.com/Rarasinhoo/gbos-vm.git
cd gbos-vm
./install.sh
```

Then open the app it built:

```bash
open "work/host/Googlebook VM.app"
```

Drag that into your Dock if you want it there. It boots the VM when you open it and shuts Android down properly when you quit.

The first boot takes about 45 seconds on a M5 MacBook, and it goes straight into the one user account (no password).

`install.sh` downloads about 9 GB and wants 60 GB free. On an M5 MacBook the build part takes around five minutes; the downloads take however long your connection takes.

## What you need

- An **Apple Silicon Mac**. Intel Macs won't work — this is an ARM guest running on the hypervisor, not emulation.
- **16 GB of RAM**, realistically. The VM gets 4 GB (8 GB on Macs with 24 GB or more: in 4 GB Android 16 swaps a lot, which makes some screens lag) and the builds want a few more.
- **Xcode command line tools** and **[Homebrew](https://brew.sh)**.
- The **Android SDK** with an NDK, a build-tools version, and a platform (API 34+). Android Studio's defaults are fine. We build with NDK `28.2.13676358`; if you don't have that one the script uses your newest (30 is reported to work), or set `ANDROID_NDK` to pick.
- **Rust, CMake and Bazel** for the graphics stack (gfxstream's renderer and its QEMU device). `install.sh` installs them through Homebrew.
- A **JDK**. If you have Android Studio, its bundled one gets picked up automatically.
- **Python 3.10 or newer** for the build tools (meson). The `python3` that comes with Xcode's command line tools is 3.9, so this usually means `brew install python@3.13`. To use a specific interpreter, set `GBOS_PYTHON`.

`install.sh` checks all of this before it downloads anything, and offers to install what's missing — the Homebrew packages, a JDK, and the Android pieces through Google's `sdkmanager` (you don't need Android Studio). It never asks for `sudo`. Run `./prereqs.sh` on its own to see where you stand.

We build and test on one machine (M5, 16 GB, macOS 27). A couple of people have reported it working on M4 Macs too — if you try it on something else, tell us how it went.

## Using it

| Shortcut | What it does |
|---|---|
| `⌃⌘F` | Full screen |
| `⌃⌥` | Release a locked or captured mouse |
| `⌃⌘R` | Restart the VM |
| `⌘V` | Paste the Mac clipboard into the guest |
| `⌘,` | Settings |

Android shows your Mac's battery: its level, and whether it is charging (a VM has no battery of its own, so it used to read empty). Quitting (or closing the window) shuts Android down properly. Your data lives in `work/image/googlebook.raw` and sticks around between runs.

**Settings** (`⌘,`) has the touchpad option, clipboard, resolution, memory, CPU cores, network, and toggles for audio, the camera and the microphone. The touchpad and clipboard options change right away; everything else is a VM option, so it applies the next time you start it. The refresh rate isn't a setting: it follows the screen the window opens on (Android's own refresh setting has nothing to switch between, since the virtual display offers it one rate).

Resolution defaults to your display's native pixels at 16:10, and Android's UI is sized the way macOS sizes its own (density 320 at native resolution on a Retina screen, macOS's 2x). On a notched MacBook that's exactly the area below the notch, so full screen is pixel-for-pixel. Settings also offers 1080p, 1440p, 4K and 3440 × 1440 ultrawide.

**Clipboard.** `⌘V` pastes the Mac clipboard into the guest, and that is the only time it is sent. Copying from Android to the Mac is off by default; enable it in Settings if you trust what you run in the guest.

**Network** (Settings) is *Internet* by default. *Isolated from this Mac* (experimental) blocks the internet and your Mac's local services from the guest, keeping only the pointer and clipboard link; normal networking lets the guest reach your Mac's `127.0.0.1` through `10.0.2.2`. *Off* removes networking, and with it the pointer and clipboard link.

### Updating

After a `git pull`, quit the VM and run:

```bash
./update-image.sh
```

It rebuilds whatever changed (the app, the guest helpers, the graphics stack) and refreshes the system part of your disk.

`update-image.sh` keeps your data — it only replaces the system area, and it leaves the previous disk next to the new one as `googlebook.raw.before-update` in case something goes wrong.

If you'd rather start it from a terminal, `python3 run/launch.py work` opens the app and waits for it to quit; `--display 1920x1200` and `--fullscreen` set those options first.

### The pointer

It's automatic. Your Mac cursor moves in and out of the window freely, and over the window Android's own pointer takes its place, exactly where yours is: a small helper in the guest steers a virtual mouse there. So it's a real mouse to Android (hover, right-click, scrolling), and it takes the shapes apps ask for: an I-beam over text, a hand over links, resize arrows. It's drawn at the guest's frame rate, so it can trail your hand very slightly. Scrolling is as fine as on the Mac, momentum included.

When an Android app asks to lock the pointer (a game, or a web page using pointer lock), the Mac mouse locks for it and raw motion goes to a mouse that exists in Android only while it's locked. When the app lets go, so does the Mac. `⌃⌥` gets your mouse back early; clicking in the window gives it back to the app. The lock only happens while the window is in front with the cursor over it, so a game in the background can't take your mouse.

With **Trackpad as an Android touchpad** on in Settings (experimental, off by default), a Mac trackpad becomes a real touchpad instead: click the window to capture, `⌃⌥` to let go. The viewer passes your raw finger positions to a virtual multitouch touchpad in the guest, so Android does its own pointer acceleration, two-finger scrolling, pinch and swipes. Clicks follow your Mac's settings (press, or tap if you have tap to click on), and so does the scroll direction. Its touch reports reach Android less evenly than the mouse's under load, so the pointer can stutter. If the helper can't connect (network set to off), the same click-to-capture USB mouse is the fallback.

`⌘V` pastes the Mac clipboard in every case.

### Camera and microphone

Android sees your Mac's camera as a plugged-in USB webcam ("Mac Camera"), offered at 1280×720, 1920×1080 and 640×480, 30 fps. The first time an Android app opens it, macOS asks whether **Googlebook VM** may use the camera. The Mac camera (and its green light) only runs while an app is actually streaming from it, and switches off a few seconds after the app stops. Turn it off entirely in Settings.

Your Mac's microphone shows up the same way, as a USB microphone ("Mac Microphone", 48 kHz mono). Recording video and calls need it: without one, Android's recorder waits for sound that never comes. macOS asks for microphone access the first time an app records, and the Mac microphone (and its orange dot) only runs while something in Android is recording. Turned off in Settings, Android has no microphone at all, so nothing that records sound (video included) will work.

The built-in Camera app shows a live preview and records video with sound, and the recordings play back.

## System Structure

The image starts as Google's unmodified recovery download. We don't touch the system partitions — but Googlebook OS expects hardware our VM doesn't have (a TPM, Trusty, a Qualcomm DSP, a specific GPU), so the **vendor partition gets rebuilt** with virtual-device replacements from Google's own Cuttlefish project:

- **Software KeyMint and Gatekeeper** instead of hardware-backed ones. Your keys aren't protected by a secure element, because there isn't one.
- **No verified boot on the vendor partition.** The other partitions keep their original verity; the one we modify can't.
- **Three extra SELinux rules**, all narrowly about graphics buffer sharing. SELinux stays enforcing. They apply to `platform_app`, `priv_app` and `priv_app_36`, for the graphics allocator's shared memory only.
- **No lock screen, unlocked boot state.** Setup is skipped and the screen stays on. Keys are software only and sit on the same disk as your data, so keep `work/image/googlebook.raw` private (the build makes it readable only by you).
- **A guest log.** `work/logs/<run>/serial.log` holds guest console output, including crash excerpts and package names. Nothing prunes old runs.
- **Cuttlefish's Bluetooth service** instead of the Qualcomm one, so the missing Qualcomm radio doesn't crash on boot. With no radio attached, Android is told it has no Bluetooth.
- **A helper running as the Android shell user** that takes pointer and clipboard input from the viewer. It listens to nothing and connects out to `127.0.0.1` on your Mac. Both ends prove a random token to each other before anything else is sent. The token reaches Android over the serial console, into a file only the shell user can read.
- **AOSP's V4L2 camera provider** (Cuttlefish's build) instead of Googlebook's USB camera HAL, plus one service label for it in `vendor_service_contexts`. The SELinux policy itself is unchanged. The device also declares an external camera instead of a front one, because that's what the provider reports.
- **Cuttlefish's audio configuration, edited for a USB microphone:** an input-only USB audio module is added, and the built-in microphone the VM doesn't have is removed.

So: treat it like a dev VM. It's great for poking at the OS. I wouldn’t daily drive it or anything, but I’m sure some freaks (laudatory) will try.

## What doesn't work yet

- **Bluetooth is LE only, and off by default.** With **Bluetooth** on in Settings (it needs the Android Emulator package, which `prereqs.sh` installs with the SDK), Android sees the Bluetooth LE accessories near your Mac and its apps can connect to them. Classic Bluetooth isn't relayed (headphones, keyboards and mice already work through the Mac), Android can't bond with a device itself, and other people's laptops and phones are left out on purpose. See "Bluetooth through the Mac" below.
- **The refresh rate follows the screen the window opens on**, up to 120 Hz, as a whole fraction of it where needed so every frame stays up the same number of refreshes (144 Hz gets 72). QEMU hard-codes 75 Hz in the display description it gives the guest, so the runner patches that one constant in a copy of QEMU's library (`work/host/qemu-gfx-aarch64-softmmu-<rate>mhz`); if a future QEMU changes that code, it falls back to 60 or 75 Hz. Move the window to another screen and it keeps the old rate until the next restart.
- **Frames are shown on the guest's clock**, not as they arrive: the viewer rebuilds the guest's frame timing and shows every frame the same few milliseconds after it was due (about 7 ms at 120 Hz), so jitter in the copy from the guest doesn't make frames stay up a refresh too long or too short. The viewer never asks for a new drawable while a frame is still waiting to be shown (it draws the newest frame once that one is up), so it never waits on the display, and neither does the mouse, which the same thread delivers. `VM_NO_PACING=1` turns this off. `tests/perf.py` measures it.
- **Flat shading can be wrong.** Chrome needs a Vulkan extension MoltenVK doesn't have, so we tell the guest it exists. That's fine for almost everything; `flat`-interpolated WebGL content may pick the wrong vertex.
- **Copying *out* of the guest, right-click, and long sessions** are implemented but haven't had a proper test. They might be fine. They might not.
- **Audio was silent on one boot** and then worked. We don't know why yet.

## The Custom Bits

The graphics took the most building:

**A guest driver that matches the Mac's renderer.** gfxstream's Mac support lives in a fork of Google's renderer, cut from one revision of Android's Mesa; the guest's Vulkan driver has to speak exactly that revision's protocol, or Android's compositor crashes on its first frame. So `build-gfxstream.sh` builds the guest driver from that same Mesa revision, outside the Android source tree, with small stand-ins for the few Android headers it wants (`guest/gfxstream-shims`, `patches/mesa-gfxstream-guest.patch`).

**Frames without a copy.** gfxstream draws into Metal textures, and QEMU's SPICE display already knows how to blit a Metal texture into the IOSurface the viewer shows. The renderer now hands QEMU the texture behind each scanout, and a small compute shader converts its RGBA to the viewer's BGRA on the GPU (`patches/gfxstream-host.patch`, `patches/qemu-gfxstream.patch`). That roughly doubled the frame rate over reading every frame back.

**Android's assumptions about a GPU.** Android's UI renderer insists on two graphics queues (MoltenVK has one; gfxstream offers a virtual second). The Linux kernel hands a graphics context id to the next process the moment the last one lets go, while the renderer was still cleaning up after the old owner under that id, destroying the new process's objects; the renderer now finishes first. And ANGLE offers OpenGL ES 3, which Chrome needs, only with `VK_EXT_provoking_vertex`, which UTM's MoltenVK leaves out, so the guest driver offers it itself.

**Video in the right colours.** Android's software decoders hand the compositor YV12 frames (a brightness plane, then two quarter-size colour planes). Those buffers are marked for CPU access, so the renderer made them linear, while the guest reads them through optimally tiled images bound to the same memory; on MoltenVK the two don't lay planes out alike. Three-plane images don't alias between the two sides either. YUV buffers are now always optimal and kept in the NV12 shape (brightness, then interleaved colour) on both sides, converted on the way in and out.

**A pointer that is a mouse after all.** Android wouldn't accept QEMU's absolute tablet, and a relative mouse drifts from your real cursor. Injecting events at the exact position (the way scrcpy does) works, but Android counts every injected event as one virtual device and gives cursor shapes only to real mice, so the pointer was always an arrow. So the helper creates a real virtual mouse and steers it: once into the corner, where Android stops it, then by exact pixel deltas (Android's pointer acceleration is off), and it checks where Android says the pointer is whenever it rests. Pointer capture has no listener a shell process can use either, so the helper reads the input service's state twice a second while you're using the VM; when an app asks, the viewer locks the Mac mouse and the same virtual mouse passes on raw motion.

**Bluetooth through the Mac.** macOS doesn't hand a VM its Bluetooth radio, so Android gets a virtual one (the Android Emulator's `netsimd`) and the viewer fills it with twins. Every connection to netsimd's raw HCI port is one more controller on the same simulated radio, so for each BLE accessory CoreBluetooth sees, the viewer opens one and acts there as that device: it advertises what the Mac heard it advertise, accepts Android's connection, and answers GATT from the real device through CoreBluetooth: reads, writes, notifications and indications (`host/bluetooth.m`, a small BLE peripheral stack: HCI, L2CAP and an ATT server). CoreBluetooth never reveals a device's address, so each twin has a stable made-up one. If a characteristic needs encryption, macOS pairs on its own link, so you may see a macOS pairing prompt. `tests/bluetooth_relay.py` joins the radio as one more central to check it.

**A webcam that is really a process.** QEMU on macOS has no virtual camera, and the Mac's camera isn't a USB device it could pass through. But QEMU's `usb-redir` lets something outside the VM *be* a USB device, so the viewer speaks that protocol over a socket and presents a standard UVC webcam (MJPEG over a bulk endpoint) fed by AVFoundation — `host/webcam.m`. The guest kernel already has `uvcvideo`. Googlebook OS ships its own USB camera HAL, but it runs every session through GPU effects (OpenGL, OpenCL, Vulkan with external memory) the VM can't provide, so the image retires it and adds AOSP's plain V4L2 camera provider from Cuttlefish instead — `image/mica_camera_port.py`. The microphone is the same trick (`host/microphone.m`): QEMU's own audio devices and its coreaudio backend can only play sound, so the viewer presents a USB Audio Class microphone and streams one isochronous packet per millisecond from AVAudioEngine. Android then needed two changes before it would record from it. Cuttlefish's audio setup has no USB module at all, so the image adds one for input only (the speaker stays on the module that already plays it). And it declares a built-in microphone, which Android picks over a USB one when recording video; the VM has none, so the image removes it — `image/mica_audio_port.py`.

The rest is plumbing: `fetch.sh` gets the images, `build-host.sh` builds the launcher and the viewer, `build-guest.sh` builds the guest helpers, `build-gfxstream.sh` builds the renderer, QEMU and the guest's graphics driver, and `build-image.sh` assembles the disk.

## Layout

```
install.sh          runs the five steps below in order
fetch.sh            downloads + verifies the Googlebook image, Cuttlefish, and UTM
build-host.sh       QEMU launcher, viewer app
build-guest.sh      pointer helper, Vulkan self-test, SELinux policy tool
build-gfxstream.sh  gfxstream renderer, QEMU with its device, the guest's Vulkan driver
build-image.sh      assembles the bootable disk
update-image.sh     refreshes an existing disk after a git pull, keeping your data
run/                VM runner and a command-line launcher (the app bundles these)
image/              the scripts that rebuild the vendor partition
guest/  host/       sources for the bits we wrote
patches/            our changes to gfxstream, QEMU, Mesa and CocoaSpice
tests/              soak and display smoothness runs on throwaway test images
```

Everything lands in `work/` (set `GOOGLEBOOK_WORK` to put it elsewhere). If you already have the big downloads, point `GOOGLEBOOK_DOWNLOADS` at them and they won't be fetched again. Builds use four jobs by default — raise `GBOS_JOBS` if you have the RAM, but an uncapped Mesa build will happily push a 16 GB Mac into swap (ask me how I know).

## What gets downloaded, and from where

Nothing from Google or UTM is redistributed here. The script fetches each of these on your machine and checks it against a pinned SHA-256:

- Googlebook recovery image — `dl.google.com` (build `16471258`)
- Cuttlefish virtual device image — `ci.android.com` (build `16373615`)
- UTM 5.0.6 beta — the official GitHub release (for MoltenVK, ANGLE and QEMU's firmware)
- UTM's QEMU 10.0.12 source, gfxstream (the macOS fork from google/gfxstream#168), rutabaga_gfx and Android's Mesa — each at a pinned commit or checksum
- libsepol 3.11 — its upstream release tarball

## Credits

This leans entirely on other people's work: [UTM](https://github.com/utmapp/UTM) and its forks of QEMU and CocoaSpice, Google's [gfxstream](https://android.googlesource.com/platform/hardware/google/gfxstream) and [rutabaga_gfx](https://github.com/magma-gpu/rutabaga_gfx), [Mesa](https://mesa3d.org), [MoltenVK](https://github.com/KhronosGroup/MoltenVK), QEMU, and the Android Cuttlefish team, whose virtual-device components are what make the image boot at all. The pointer helper uses the same trick as [scrcpy](https://github.com/Genymobile/scrcpy).

## License

MIT for everything we wrote — see [LICENSE](LICENSE). The patches apply to MIT-licensed projects, except `patches/cocoaspice-viewer.patch`, which modifies Apache-2.0 code and stays under that license.

## AI Usage

The following AI tools were used to assist in this project:
- OpenAI GPT 6 Astra
- DeepSeek 4.1 Flash
- Anthropic Claude Opus 5.5