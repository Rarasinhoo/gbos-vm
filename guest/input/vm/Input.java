// Guest input helper for the Googlebook VM, run with app_process as
// the shell user. It connects out to the viewer on the host (10.0.2.2 is the
// host loopback under QEMU user networking) and, on its request, injects
// absolute mouse events and syncs clipboard text. Same approach as scrcpy's
// server (InputManager injection as shell), with a small line protocol:
//   host -> guest:  G width height | M x y | D button | U button | S hscroll vscroll | X | K keycode | C base64-text
//                   P width_mm height_mm natural | F button count [id x y]... | B level plugged charging
//                   W vertical horizontal (high-resolution wheel, 120 = one notch)
//   guest -> host:  c base64-text (guest clipboard changed) | m tablet|inject (pointer mode) | p touchpad|none
//                   | w wheel|none
// The first line from the host must be "A <token>", matching the random per-boot token the
// launcher put on the kernel command line (ro.boot.gbos_token). Until then nothing is accepted,
// so another program on the Mac that grabs the port first cannot drive the guest.
// Pointer mode "tablet": a uinput drawing-tablet device (absolute stylus on a
// non-direct device), which makes Android draw its own cursor at the exact
// position. If that cannot be created, events are injected instead and the
// host cursor is the pointer.
// Touchpad: a uinput multitouch touchpad the host feeds with the Mac trackpad's raw contacts
// (F: x and y from 0 to 1, top left origin), so Android's own touchpad stack does the pointer
// acceleration, two-finger scrolling, pinch and swipes, as on a real touchpad.
package vm;

import android.content.ClipData;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Base64;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.Socket;

public final class Input {
    private static final String SHELL = "com.android.shell";
    private static Object inputManager;
    private static Method inject, setActionButton;
    private static Object clipboard;
    private static long downTime;
    private static int buttons;
    private static float x, y;
    private static volatile String lastClip = "";
    private static volatile OutputStream out;
    private static String token = "";
    private static boolean authed;
    private static Process uinput;
    private static OutputStream tablet;
    private static int tabletW, tabletH;
    private static int tabletDeviceId;
    private static Process touchpadProcess;
    private static OutputStream touchpad;
    private static int padW, padH;
    private static final int PAD_RES = 12;                 // units per millimetre
    private static final int[] slotContact = { -1, -1, -1, -1, -1 };  // host contact id per slot
    private static int nextTracking = 1;

    public static void main(String[] args) throws Exception {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : 27183;
        Class<?> c;
        try { c = Class.forName("android.hardware.input.InputManagerGlobal"); }
        catch (ClassNotFoundException e) { c = Class.forName("android.hardware.input.InputManager"); }
        inputManager = c.getMethod("getInstance").invoke(null);
        inject = inputManager.getClass().getMethod("injectInputEvent", InputEvent.class, int.class);
        setActionButton = MotionEvent.class.getMethod("setActionButton", int.class);
        try {
            IBinder b = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "clipboard");
            clipboard = Class.forName("android.content.IClipboard$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
        } catch (Throwable t) { System.out.println("VM_INPUT clipboard unavailable: " + t); }
        try { token = (String) Class.forName("android.os.SystemProperties").getMethod("get", String.class).invoke(null, "ro.boot.gbos_token"); }
        catch (Throwable t) { token = ""; }
        System.out.println("VM_INPUT ready" + (token.isEmpty() ? " (no token set: accepting any host)" : ""));
        Thread poll = new Thread(Input::pollClipboard, "clip");
        poll.setDaemon(true);
        poll.start();
        while (true) {
            try (Socket s = new Socket()) {
                s.connect(new InetSocketAddress("10.0.2.2", port), 2000);
                s.setTcpNoDelay(true);
                authed = token.isEmpty();
                OutputStream link = s.getOutputStream();
                if (authed) out = link;
                System.out.println("VM_INPUT connected");
                BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
                String line;
                while ((line = r.readLine()) != null) {
                    if (!authed) {
                        if (!line.equals("A " + token)) { System.out.println("VM_INPUT rejected host: bad token"); break; }
                        authed = true; out = link;
                        continue;
                    }
                    if (line.startsWith("A ")) continue;
                    try { handle(line); } catch (Throwable t) {
                        Throwable cause = t.getCause() != null ? t.getCause() : t;
                        System.out.println("VM_INPUT error " + line.charAt(0) + ": " + cause);
                        // system_server restarted: our binder handles are dead, so start over.
                        if (cause instanceof android.os.DeadObjectException || String.valueOf(cause).contains("DeadSystem")) System.exit(3);
                    }
                }
            } catch (Throwable t) { /* host not listening yet */ }
            out = null;
            releaseAll();
            SystemClock.sleep(2000);
        }
    }

    private static void handle(String line) throws Exception {
        if (line.isEmpty()) return;
        String[] p = line.split(" ");
        switch (line.charAt(0)) {
            case 'G': registerTablet(Integer.parseInt(p[1]), Integer.parseInt(p[2])); break;
            case 'M':
                x = Float.parseFloat(p[1]); y = Float.parseFloat(p[2]);
                if (tabletAlive()) { tabletSend("3,0," + Math.round(x) + ",3,1," + Math.round(y) + ",1,320,1,0,0,0"); break; }
                motion(buttons != 0 ? MotionEvent.ACTION_MOVE : MotionEvent.ACTION_HOVER_MOVE, 0, 0, 0);
                break;
            case 'D': {
                int b = Integer.parseInt(p[1]);
                if (tabletAlive()) { buttons |= b; tabletSend((b == 2 ? "1,273,1," : b == 4 ? "1,274,1," : "") + "1,330,1,3,24,255,0,0,0"); break; }
                if (buttons == 0) { downTime = SystemClock.uptimeMillis(); buttons |= b; motion(MotionEvent.ACTION_DOWN, 0, 0, 0); }
                else buttons |= b;
                motion(MotionEvent.ACTION_BUTTON_PRESS, b, 0, 0);
                break;
            }
            case 'U': {
                int b = Integer.parseInt(p[1]);
                if ((buttons & b) == 0) break;
                buttons &= ~b;
                if (tabletAlive()) { tabletSend((b == 2 ? "1,273,0," : b == 4 ? "1,274,0," : "") + (buttons == 0 ? "1,330,0,3,24,0," : "") + "0,0,0"); break; }
                motion(MotionEvent.ACTION_BUTTON_RELEASE, b, 0, 0);
                if (buttons == 0) motion(MotionEvent.ACTION_UP, 0, 0, 0);
                break;
            }
            case 'S': {
                float hs = Float.parseFloat(p[1]), vs = Float.parseFloat(p[2]);
                if (tabletAlive()) {
                    // The tablet's wheel axes are ignored by this Android build, and a scroll injected as a
                    // separate mouse makes apps un-hide the idle system mouse cursor and gets dropped while
                    // the tablet hovers. So inject the scroll as if it came from the tablet itself.
                    if (tabletDeviceId == 0) tabletDeviceId = findTabletDevice();
                    if (tabletDeviceId != 0) scrollAs(tabletDeviceId, InputDevice.SOURCE_MOUSE | InputDevice.SOURCE_STYLUS, MotionEvent.TOOL_TYPE_STYLUS, hs, vs);
                    break;
                }
                motion(MotionEvent.ACTION_SCROLL, 0, hs, vs);
                break;
            }
            case 'X':
                if (tabletAlive()) { if (buttons == 0) tabletSend("1,320,0,0,0,0"); break; }
                if (buttons == 0) motion(MotionEvent.ACTION_HOVER_EXIT, 0, 0, 0);
                break;
            case 'K': key(Integer.parseInt(p[1])); break;
            case 'C': setClip(p.length > 1 ? new String(Base64.decode(p[1], Base64.NO_WRAP), "UTF-8") : ""); break;
            case 'P': registerTouchpad(Float.parseFloat(p[1]), Float.parseFloat(p[2]), p.length > 3 && p[3].equals("1")); break;
            case 'F': touchFrame(p); break;
            case 'W': wheel(Integer.parseInt(p[1]), Integer.parseInt(p[2])); break;
            case 'B': battery(Integer.parseInt(p[1]), p[2].equals("1"), p[3].equals("1")); break;
            default: break;
        }
    }

    private static boolean tabletAlive() {
        if (tablet == null) return false;
        if (uinput.isAlive()) return true;
        tablet = null; buttons = 0;
        System.out.println("VM_INPUT tablet process ended; injecting instead");
        reply("m inject");
        return false;
    }

    private static void tabletSend(String events) {
        try {
            tablet.write(("{\"id\":1,\"command\":\"inject\",\"events\":[" + events + "]}\n").getBytes("UTF-8"));
            tablet.flush();
        } catch (Throwable t) { tablet = null; }
    }

    // BTN_TOOL_PEN 320, BTN_TOUCH 330, BTN_RIGHT 273, BTN_MIDDLE 274; ABS_X 0, ABS_Y 1, ABS_PRESSURE 24.
    private static void registerTablet(int w, int h) {
        if (tablet != null && uinput.isAlive() && w == tabletW && h == tabletH) { reply("m tablet"); return; }
        if (w <= 0 || h <= 0) {   // host asked for injection mode (Mac cursor is the pointer)
            if (uinput != null) uinput.destroy();
            tablet = null; buttons = 0; tabletW = tabletH = 0;
            reply("m inject");
            return;
        }
        try {
            if (uinput != null) uinput.destroy();
            tablet = null; buttons = 0;
            uinput = new ProcessBuilder("/system/bin/uinput", "-").redirectErrorStream(true).start();
            OutputStream o = uinput.getOutputStream();
            String axis = "{\"value\":0,\"minimum\":0,\"maximum\":%d,\"fuzz\":0,\"flat\":0,\"resolution\":0}";
            o.write(("{\"id\":1,\"command\":\"register\",\"name\":\"VM Absolute Pointer\",\"vid\":6900,\"pid\":30465,\"bus\":\"usb\","
                    + "\"configuration\":[{\"type\":100,\"data\":[1,3]},{\"type\":101,\"data\":[273,274,320,330]},{\"type\":103,\"data\":[0,1,24]}],"
                    + "\"abs_info\":[{\"code\":0,\"info\":" + String.format(axis, w - 1) + "},{\"code\":1,\"info\":" + String.format(axis, h - 1) + "},{\"code\":24,\"info\":" + String.format(axis, 255) + "}]}\n").getBytes("UTF-8"));
            o.flush();
            SystemClock.sleep(1500);
            if (!uinput.isAlive()) throw new IllegalStateException("uinput exited " + uinput.exitValue());
            tablet = o; tabletW = w; tabletH = h; tabletDeviceId = findTabletDevice();
            System.out.println("VM_INPUT tablet registered " + w + "x" + h + " device " + tabletDeviceId);
            drain(uinput, "uinput");
            reply("m tablet");
        } catch (Throwable t) {
            tablet = null;
            System.out.println("VM_INPUT tablet unavailable: " + t);
            reply("m inject");
        }
    }

    // BTN_LEFT 272, BTN_TOOL_FINGER 325, BTN_TOOL_QUINTTAP 328, BTN_TOUCH 330, BTN_TOOL_DOUBLETAP 333,
    // BTN_TOOL_TRIPLETAP 334, BTN_TOOL_QUADTAP 335; ABS_X 0, ABS_Y 1, ABS_MT_SLOT 47,
    // ABS_MT_POSITION_X 53, ABS_MT_POSITION_Y 54, ABS_MT_TRACKING_ID 57, ABS_MT_TOUCH_MAJOR 48,
    // ABS_MT_TOUCH_MINOR 49, ABS_MT_PRESSURE 58 (the Mac reports neither size nor pressure per
    // finger, but Android's touchpad gestures need both to tell a finger from a hover). Type 110 is
    // UI_SET_PROPBIT: INPUT_PROP_POINTER (0, not a touchscreen) and INPUT_PROP_BUTTONPAD (2, the
    // whole pad clicks), which is what makes Android treat it as a touchpad.
    private static void registerTouchpad(float widthMm, float heightMm, boolean natural) {
        int w = Math.max(100, Math.round(widthMm * PAD_RES)), h = Math.max(100, Math.round(heightMm * PAD_RES));
        if (touchpad != null && touchpadProcess.isAlive() && w == padW && h == padH) { reply("p touchpad"); return; }
        try {
            if (touchpadProcess != null) touchpadProcess.destroy();
            touchpad = null;
            touchpadProcess = new ProcessBuilder("/system/bin/uinput", "-").redirectErrorStream(true).start();
            OutputStream o = touchpadProcess.getOutputStream();
            String axis = "{\"value\":0,\"minimum\":0,\"maximum\":%d,\"fuzz\":0,\"flat\":0,\"resolution\":%d}";
            String x = String.format(axis, w - 1, PAD_RES), y = String.format(axis, h - 1, PAD_RES);
            o.write(("{\"id\":1,\"command\":\"register\",\"name\":\"VM Touchpad\",\"vid\":6900,\"pid\":30466,\"bus\":\"usb\","
                    + "\"configuration\":[{\"type\":100,\"data\":[1,3]},{\"type\":101,\"data\":[272,325,328,330,333,334,335]},"
                    + "{\"type\":103,\"data\":[0,1,24,47,48,49,53,54,57,58]},{\"type\":110,\"data\":[0,2]}],"
                    + "\"abs_info\":[{\"code\":0,\"info\":" + x + "},{\"code\":1,\"info\":" + y + "},"
                    + "{\"code\":47,\"info\":" + String.format(axis, slotContact.length - 1, 0) + "},"
                    + "{\"code\":53,\"info\":" + x + "},{\"code\":54,\"info\":" + y + "},"
                    + "{\"code\":57,\"info\":" + String.format(axis, 65535, 0) + "},"
                    + "{\"code\":24,\"info\":" + String.format(axis, 255, 0) + "},{\"code\":58,\"info\":" + String.format(axis, 255, 0) + "},"
                    + "{\"code\":48,\"info\":" + String.format(axis, 255, 1) + "},{\"code\":49,\"info\":" + String.format(axis, 255, 1) + "}]}\n").getBytes("UTF-8"));
            o.flush();
            SystemClock.sleep(1500);
            if (!touchpadProcess.isAlive()) throw new IllegalStateException("uinput exited " + touchpadProcess.exitValue());
            touchpad = o; padW = w; padH = h;
            java.util.Arrays.fill(slotContact, -1);
            // The Mac decides what is a click (a press, or a tap if the Mac has tap to click), so
            // Android must not turn taps into clicks as well; scroll direction follows the Mac.
            // In the background: each `settings` call takes about a second, and touches must not wait.
            Thread prefs = new Thread(() -> {
                try {
                    Runtime.getRuntime().exec(new String[] { "settings", "--user", "current", "put", "system", "touchpad_tap_to_click", "0" }).waitFor();
                    Runtime.getRuntime().exec(new String[] { "settings", "--user", "current", "put", "system", "touchpad_natural_scrolling", natural ? "1" : "0" }).waitFor();
                } catch (Throwable t) { System.out.println("VM_INPUT touchpad settings: " + t); }
            }, "touchpad-settings");
            prefs.setDaemon(true);
            prefs.start();
            System.out.println("VM_INPUT touchpad registered " + w + "x" + h + (natural ? " natural" : ""));
            drain(touchpadProcess, "touchpad");
            reply("p touchpad");
        } catch (Throwable t) {
            touchpad = null;
            System.out.println("VM_INPUT touchpad unavailable: " + t);
            reply("p none");
        }
    }

    // F button count [id x y]...: the contacts now on the Mac trackpad, and the pad's button.
    private static int framesSeen; private static long firstFrame;
    private static void touchFrame(String[] p) {
        if (touchpad == null || !touchpadProcess.isAlive()) { touchpad = null; return; }
        if (framesSeen++ == 0) firstFrame = SystemClock.uptimeMillis();
        else if (framesSeen % 100 == 0) System.out.println("VM_INPUT touchpad got " + framesSeen + " frames in " + (SystemClock.uptimeMillis() - firstFrame) + " ms");
        int button = Integer.parseInt(p[1]), count = Math.min(Integer.parseInt(p[2]), slotContact.length);
        int[] ids = new int[count], xs = new int[count], ys = new int[count];
        for (int i = 0; i < count; i++) {
            ids[i] = Integer.parseInt(p[3 + 3 * i]);
            xs[i] = Math.round(Math.max(0f, Math.min(1f, Float.parseFloat(p[4 + 3 * i]))) * (padW - 1));
            ys[i] = Math.round(Math.max(0f, Math.min(1f, Float.parseFloat(p[5 + 3 * i]))) * (padH - 1));
        }
        StringBuilder e = new StringBuilder();
        // Lift the slots whose contact is gone, then place each contact in its slot (a new one gets
        // a free slot and a fresh tracking id).
        for (int s = 0; s < slotContact.length; s++) {
            if (slotContact[s] < 0) continue;
            boolean present = false;
            for (int id : ids) present |= id == slotContact[s];
            if (!present) { e.append("3,47,").append(s).append(",3,57,-1,"); slotContact[s] = -1; }
        }
        for (int i = 0; i < count; i++) {
            int s = -1;
            for (int k = 0; k < slotContact.length && s < 0; k++) if (slotContact[k] == ids[i]) s = k;
            e.append("3,47,");
            if (s < 0) {
                for (int k = 0; k < slotContact.length && s < 0; k++) if (slotContact[k] < 0) s = k;
                slotContact[s] = ids[i];
                e.append(s).append(",3,57,").append(nextTracking++ & 0xFFFF).append(',');
            } else e.append(s).append(',');
            // A typical fingertip on a trackpad: about 10 x 8 mm, moderate pressure.
            e.append("3,53,").append(xs[i]).append(",3,54,").append(ys[i]).append(",3,48,10,3,49,8,3,58,60,");
        }
        if (count > 0) e.append("3,0,").append(xs[0]).append(",3,1,").append(ys[0]).append(",3,24,60,");
        else e.append("3,24,0,");
        e.append("1,330,").append(count > 0 ? 1 : 0).append(",1,325,").append(count == 1 ? 1 : 0)
         .append(",1,333,").append(count == 2 ? 1 : 0).append(",1,334,").append(count == 3 ? 1 : 0)
         .append(",1,335,").append(count == 4 ? 1 : 0).append(",1,328,").append(count >= 5 ? 1 : 0)
         .append(",1,272,").append(button != 0 ? 1 : 0).append(",0,0,0");
        try {
            touchpad.write(("{\"id\":1,\"command\":\"inject\",\"events\":[" + e + "]}\n").getBytes("UTF-8"));
            touchpad.flush();
        } catch (Throwable t) { touchpad = null; }
    }

    // B: the Mac's battery, so Android shows it instead of an empty one (a VM has none). The level
    // goes first: an override that unplugs before raising the level is an empty battery, and
    // Android shuts down at once. Status: 2 charging, 3 discharging, 5 full.
    private static int batteryLevel = -1;
    private static boolean batteryPlugged, batteryCharging;
    private static void battery(int level, boolean plugged, boolean charging) throws Exception {
        level = Math.max(1, Math.min(100, level));
        if (level == batteryLevel && plugged == batteryPlugged && charging == batteryCharging) return;
        String status = charging ? "2" : plugged ? "5" : "3";
        for (String[] a : new String[][] { { "level", String.valueOf(level) }, { "present", "1" }, { "ac", plugged ? "1" : "0" },
                                           { "usb", "0" }, { "wireless", "0" }, { "status", status } })
            Runtime.getRuntime().exec(new String[] { "cmd", "battery", "set", a[0], a[1] }).waitFor();
        if (batteryLevel < 0) System.out.println("VM_INPUT battery " + level + "%" + (plugged ? " plugged" : "") + (charging ? " charging" : ""));
        batteryLevel = level; batteryPlugged = plugged; batteryCharging = charging;
    }

    // W: scrolling with a Mac trackpad's precision. The USB mouse has a wheel of whole notches
    // only (a fixed jump each); this uinput mouse has a high-resolution wheel, 1/120 notch per
    // unit, which Android scrolls by exactly. Being a mouse, it shares Android's mouse pointer,
    // so the scroll lands wherever that is. REL_X 0, REL_Y 1, REL_HWHEEL 6, REL_WHEEL 8,
    // REL_WHEEL_HI_RES 11, REL_HWHEEL_HI_RES 12; BTN_LEFT 272 makes it count as a mouse.
    private static Process wheelProcess;
    private static OutputStream wheelOut;
    private static void wheel(int vertical, int horizontal) {
        if (wheelOut == null || !wheelProcess.isAlive()) {
            try {
                if (wheelProcess != null) wheelProcess.destroy();
                wheelOut = null;
                wheelProcess = new ProcessBuilder("/system/bin/uinput", "-").redirectErrorStream(true).start();
                OutputStream o = wheelProcess.getOutputStream();
                o.write(("{\"id\":1,\"command\":\"register\",\"name\":\"VM Scroll Wheel\",\"vid\":6900,\"pid\":30467,\"bus\":\"usb\","
                        + "\"configuration\":[{\"type\":100,\"data\":[1,2]},{\"type\":101,\"data\":[272]},{\"type\":102,\"data\":[0,1,6,8,11,12]}]}\n").getBytes("UTF-8"));
                o.flush();
                SystemClock.sleep(1500);
                if (!wheelProcess.isAlive()) throw new IllegalStateException("uinput exited " + wheelProcess.exitValue());
                wheelOut = o;
                drain(wheelProcess, "wheel");
                System.out.println("VM_INPUT wheel registered");
                reply("w wheel");
            } catch (Throwable t) {
                System.out.println("VM_INPUT wheel unavailable: " + t);
                reply("w none");
                return;
            }
        }
        if (vertical == 0 && horizontal == 0) return;
        try {
            wheelOut.write(("{\"id\":1,\"command\":\"inject\",\"events\":[2,11," + vertical + ",2,12," + horizontal + ",0,0,0]}\n").getBytes("UTF-8"));
            wheelOut.flush();
        } catch (Throwable t) { wheelOut = null; }
    }

    private static void drain(Process process, String tag) {
        Thread t = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                String line; int n = 0;
                while ((line = r.readLine()) != null && n++ < 40) System.out.println("VM_INPUT " + tag + ": " + line);
            } catch (Throwable e) { /* process ended */ }
        }, tag);
        t.setDaemon(true);
        t.start();
    }

    private static void reply(String line) {
        OutputStream o = out;
        if (o == null) return;
        try { synchronized (Input.class) { o.write((line + "\n").getBytes("UTF-8")); o.flush(); } } catch (Throwable t) { /* link closed */ }
    }

    private static void releaseAll() {
        try { if (touchpad != null) touchFrame(new String[] { "F", "0", "0" }); } catch (Throwable t) { /* gone */ }
        try {
            for (int b = 1; b <= 4 && buttons != 0; b <<= 1) if ((buttons & b) != 0) handle("U " + b);
        } catch (Throwable t) { buttons = 0; }
    }

    private static void motion(int action, int actionButton, float hscroll, float vscroll) throws Exception {
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] props = { new MotionEvent.PointerProperties() };
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        coords[0].x = x; coords[0].y = y;
        coords[0].pressure = buttons != 0 ? 1f : 0f;
        coords[0].size = 1f;
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hscroll);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vscroll);
        MotionEvent e = MotionEvent.obtain(buttons != 0 || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_BUTTON_RELEASE ? downTime : now,
                now, action, 1, props, coords, 0, buttons, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        if (actionButton != 0) setActionButton.invoke(e, actionButton);
        inject.invoke(inputManager, e, 0);
        e.recycle();
    }

    private static int findTabletDevice() {
        try {
            for (int id : InputDevice.getDeviceIds()) {
                InputDevice d = InputDevice.getDevice(id);
                if (d != null && "VM Absolute Pointer".equals(d.getName())) return id;
            }
        } catch (Throwable t) { System.out.println("VM_INPUT device lookup: " + t); }
        return 0;
    }

    private static void scrollAs(int deviceId, int source, int toolType, float hscroll, float vscroll) throws Exception {
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] props = { new MotionEvent.PointerProperties() };
        props[0].id = 0;
        props[0].toolType = toolType;
        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        coords[0].x = Math.round(x); coords[0].y = Math.round(y);
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hscroll);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vscroll);
        MotionEvent e = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1, props, coords, 0, 0, 1f, 1f, deviceId, 0, source, 0);
        inject.invoke(inputManager, e, 0);
        e.recycle();
    }

    private static void key(int code) throws Exception {
        long now = SystemClock.uptimeMillis();
        for (int action : new int[] { KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP }) {
            inject.invoke(inputManager, new KeyEvent(now, now, action, code, 0, 0, -1, 0, 0, InputDevice.SOURCE_KEYBOARD), 0);
        }
    }

    private static int currentUser() {
        try { return (Integer) Class.forName("android.app.ActivityManager").getMethod("getCurrentUser").invoke(null); }
        catch (Throwable t) { return 0; }
    }

    // IClipboard signatures change between releases; fill arguments by type.
    private static Object callClipboard(String name, ClipData clip) throws Exception {
        if (clipboard == null) return null;
        for (Method m : clipboard.getClass().getMethods()) {
            if (!m.getName().equals(name)) continue;
            Class<?>[] types = m.getParameterTypes();
            Object[] a = new Object[types.length];
            int strings = 0, ints = 0;
            for (int i = 0; i < types.length; i++) {
                if (types[i] == ClipData.class) a[i] = clip;
                else if (types[i] == String.class) a[i] = strings++ == 0 ? SHELL : null;
                else if (types[i] == int.class) a[i] = ints++ == 0 ? currentUser() : 0;
                else if (types[i] == boolean.class) a[i] = false;
            }
            return m.invoke(clipboard, a);
        }
        return null;
    }

    private static void setClip(String text) {
        try {
            lastClip = text;
            callClipboard("setPrimaryClip", ClipData.newPlainText("", text));
        } catch (Throwable t) { System.out.println("VM_INPUT setClip: " + t); }
    }

    private static void pollClipboard() {
        boolean reported = false;
        while (true) {
            SystemClock.sleep(700);
            OutputStream o = out;
            if (o == null) continue;
            try {
                ClipData clip = (ClipData) callClipboard("getPrimaryClip", null);
                if (clip == null || clip.getItemCount() == 0) continue;
                CharSequence cs = clip.getItemAt(0).getText();
                if (cs == null) continue;
                String text = cs.toString();
                if (text.equals(lastClip) || text.length() > 200000) continue;
                lastClip = text;
                byte[] msg = ("c " + Base64.encodeToString(text.getBytes("UTF-8"), Base64.NO_WRAP) + "\n").getBytes("UTF-8");
                synchronized (Input.class) { o.write(msg); o.flush(); }
            } catch (Throwable t) {
                if (!reported) { reported = true; System.out.println("VM_INPUT getClip: " + t + (t.getCause() != null ? " / " + t.getCause() : "")); }
            }
        }
    }
}
