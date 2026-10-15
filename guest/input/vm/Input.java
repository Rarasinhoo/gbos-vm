// Guest input helper for the Googlebook VM, run with app_process as
// the shell user. It connects out to the viewer on the host (10.0.2.2 is the
// host loopback under QEMU user networking, 10.0.2.100 in isolated mode, the Mac's own address
// when the VM is on its network) and, on its request, injects
// absolute mouse events and syncs clipboard text. Same approach as scrcpy's
// server (InputManager injection as shell), with a small line protocol:
//   host -> guest:  M x y | D button | U button | S hscroll vscroll | X | K keycode | C base64-text
//                   P width_mm height_mm natural | F button count [id x y]... | B level plugged charging
//                   W vertical horizontal (high-resolution wheel, 120 = one notch)
//                   Q 1|0 (the Mac has locked its mouse for an app, or let go) | R dx dy (locked motion)
//   guest -> host:  c base64-text (guest clipboard changed) | p touchpad|none | w wheel|none
//                   | k 1|0 (an app has asked for pointer capture, or released it)
// Both ends prove the per boot token with an HMAC exchange; the token is never sent. It arrives
// over the serial console and vm-host-control writes it to TOKEN_FILE, readable only by shell:
//   host -> guest:  N host-nonce
//   guest -> host:  a guest-nonce HMAC-SHA256(token, "gbos-guest:" host-nonce ":" guest-nonce)
//   host -> guest:  A HMAC-SHA256(token, "gbos-host:" guest-nonce ":" host-nonce)
// Nothing else is sent or accepted until it succeeds.
// The pointer: Android's own, a uinput mouse steered to the Mac cursor's position (see steer),
// so it takes the shapes apps ask for. When an app asks for pointer capture (a game, a browser's
// pointer lock), the Mac locks its mouse and the same mouse passes on the raw motion.
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
import java.io.FileReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

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
    private static final String TOKEN_FILE = "/data/local/tmp/vm-input.token";
    private static String token = "", host = "10.0.2.2";
    private static boolean authed;
    private static final SecureRandom random = new SecureRandom();
    private static volatile boolean locked;     // the Mac's mouse is locked for an app
    private static float mouseCarryX, mouseCarryY;
    private static volatile long lastActive;    // uptime of the host's last pointer or key event
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
        try (BufferedReader f = new BufferedReader(new FileReader(GAIN_FILE))) {
            String[] g = f.readLine().trim().split(" ");
            double gx = Double.parseDouble(g[0]), gy = Double.parseDouble(g[1]);
            if (gx > 0.25 && gx < 4 && gy > 0.25 && gy < 4) { gainX = gx; gainY = gy; }
        } catch (Throwable t) { /* learnt as the pointer moves */ }
        System.out.println("VM_INPUT ready");
        Thread poll = new Thread(Input::pollClipboard, "clip");
        poll.setDaemon(true);
        poll.start();
        Thread capture = new Thread(Input::watchPointerCapture, "capture");
        capture.setDaemon(true);
        capture.start();
        Thread storage = new Thread(Input::reportStorage, "storage");
        storage.setDaemon(true);
        storage.start();
        boolean waiting = false;
        while (true) {
            // No token, no connection.
            if (!loadToken()) {
                if (!waiting) System.out.println("VM_INPUT waiting for the host's token");
                waiting = true;
                SystemClock.sleep(2000);
                continue;
            }
            waiting = false;
            try (Socket s = new Socket()) {
                link = s;
                s.connect(new InetSocketAddress(host, port), 2000);
                s.setTcpNoDelay(true);
                authed = false;
                OutputStream link = s.getOutputStream();
                System.out.println("VM_INPUT connected");
                BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
                String line, guestNonce = null, expected = null;
                while ((line = readLine(r, authed ? 1 << 20 : 256)) != null) {
                    if (!authed) {
                        if (guestNonce == null && line.matches("N [0-9a-f]{32}")) {
                            String hostNonce = line.substring(2);
                            guestNonce = nonce();
                            expected = "A " + hmac("gbos-host:" + guestNonce + ":" + hostNonce);
                            link.write(("a " + guestNonce + " " + hmac("gbos-guest:" + hostNonce + ":" + guestNonce) + "\n").getBytes("UTF-8"));
                            link.flush();
                            continue;
                        }
                        if (expected == null || !MessageDigest.isEqual(line.getBytes("UTF-8"), expected.getBytes("UTF-8"))) {
                            System.out.println("VM_INPUT rejected host: bad token");
                            break;
                        }
                        authed = true; out = link;
                        continue;
                    }
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

    /** One line, or null at end of stream or when a line exceeds max. */
    private static String readLine(BufferedReader r, int max) throws java.io.IOException {
        StringBuilder sb = new StringBuilder();
        int c;
        while ((c = r.read()) >= 0) {
            if (c == '\n') return sb.toString();
            if (sb.length() >= max) return null;
            sb.append((char) c);
        }
        return null;
    }

    private static boolean loadToken() {
        try (BufferedReader f = new BufferedReader(new FileReader(TOKEN_FILE))) {
            String t = f.readLine(), h = f.readLine();
            if (t == null || !t.matches("[0-9a-f]{32}")) return false;
            token = t;
            // QEMU's host address, its isolated-mode forward, or the Mac on its own network (--lan)
            host = h != null && h.matches("\\d{1,3}(\\.\\d{1,3}){3}") ? h : "10.0.2.2";
            return true;
        } catch (Exception e) { return false; }
    }

    private static String nonce() {
        byte[] b = new byte[16];
        random.nextBytes(b);
        return hex(b);
    }

    private static String hmac(String msg) throws Exception {
        Mac m = Mac.getInstance("HmacSHA256");
        m.init(new SecretKeySpec(token.getBytes("UTF-8"), "HmacSHA256"));
        return hex(m.doFinal(msg.getBytes("UTF-8")));
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte v : b) sb.append(Character.forDigit((v >> 4) & 15, 16)).append(Character.forDigit(v & 15, 16));
        return sb.toString();
    }

    private static void handle(String line) throws Exception {
        if (line.isEmpty()) return;
        String[] p = line.split(" ");
        switch (line.charAt(0)) {
            case 'M':
                lastActive = SystemClock.uptimeMillis();
                x = Float.parseFloat(p[1]); y = Float.parseFloat(p[2]);
                if (pointerOut != null) { steer(x, y); break; }
                motion(buttons != 0 ? MotionEvent.ACTION_MOVE : MotionEvent.ACTION_HOVER_MOVE, 0, 0, 0);
                break;
            case 'D': {
                lastActive = SystemClock.uptimeMillis();
                int b = Integer.parseInt(p[1]);
                if (pointerOut != null) { pointerSend("1," + mouseButton(b) + ",1,0,0,0"); break; }
                if (buttons == 0) { downTime = SystemClock.uptimeMillis(); buttons |= b; motion(MotionEvent.ACTION_DOWN, 0, 0, 0); }
                else buttons |= b;
                motion(MotionEvent.ACTION_BUTTON_PRESS, b, 0, 0);
                break;
            }
            case 'U': {
                int b = Integer.parseInt(p[1]);
                if (pointerOut != null) { pointerSend("1," + mouseButton(b) + ",0,0,0,0"); break; }
                if ((buttons & b) == 0) break;
                buttons &= ~b;
                motion(MotionEvent.ACTION_BUTTON_RELEASE, b, 0, 0);
                if (buttons == 0) motion(MotionEvent.ACTION_UP, 0, 0, 0);
                break;
            }
            case 'S': {
                lastActive = SystemClock.uptimeMillis();
                float hs = Float.parseFloat(p[1]), vs = Float.parseFloat(p[2]);
                if (pointerOut != null) { wheel(Math.round(vs * 120), Math.round(hs * 120)); break; }
                motion(MotionEvent.ACTION_SCROLL, 0, hs, vs);
                break;
            }
            case 'X':
                if (pointerOut == null && buttons == 0) motion(MotionEvent.ACTION_HOVER_EXIT, 0, 0, 0);
                break;
            case 'K': lastActive = SystemClock.uptimeMillis(); key(Integer.parseInt(p[1])); break;
            case 'Q':
                locked = p[1].equals("1"); mouseCarryX = mouseCarryY = 0;
                System.out.println("VM_INPUT mouse " + (locked ? "locked" : "released"));
                break;
            case 'R': {
                // Locked for an app: raw motion. Android's pointer stays where it was meanwhile.
                lastActive = SystemClock.uptimeMillis();
                if (!locked || pointerOut == null) break;
                float dx = mouseCarryX + Float.parseFloat(p[1]), dy = mouseCarryY + Float.parseFloat(p[2]);
                int ix = (int) dx, iy = (int) dy;
                mouseCarryX = dx - ix; mouseCarryY = dy - iy;
                if (ix != 0 || iy != 0) pointerSend("2,0," + ix + ",2,1," + iy + ",0,0,0");
                break;
            }
            case 'C': setClip(p.length > 1 ? new String(Base64.decode(p[1], Base64.NO_WRAP), "UTF-8") : ""); break;
            case 'P': registerTouchpad(Float.parseFloat(p[1]), Float.parseFloat(p[2]), p.length > 3 && p[3].equals("1")); break;
            case 'F': touchFrame(p); break;
            case 'W': wheel(Integer.parseInt(p[1]), Integer.parseInt(p[2])); break;
            case 'B': battery(Integer.parseInt(p[1]), p[2].equals("1"), p[3].equals("1")); break;
            case 'L': { String id = p.length > 1 ? p[1] : ""; Thread t = new Thread(() -> keyboardLayout(id), "layout"); t.setDaemon(true); t.start(); break; }
            default: break;
        }
    }

    private static int mouseButton(int hostButton) { return hostButton == 2 ? 273 : hostButton == 4 ? 274 : 272; }

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
            waitForDevice(touchpadProcess, "VM Touchpad");
            touchpad = o; padW = w; padH = h;
            java.util.Arrays.fill(slotContact, -1);
            // Taps are Android's too (three-finger tap): the viewer only sends two fingers once
            // they move, so a two-finger tap stays the Mac's right click. Scroll direction follows the Mac.
            // In the background: each `settings` call takes about a second, and touches must not wait.
            Thread prefs = new Thread(() -> {
                try {
                    Runtime.getRuntime().exec(new String[] { "settings", "--user", "current", "put", "system", "touchpad_tap_to_click", "1" }).waitFor();
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
    private static void touchFrame(String[] p) {
        if (touchpad == null || !touchpadProcess.isAlive()) { touchpad = null; return; }
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
    // Android shuts down at once. Status: 2 charging, 3 discharging, 5 full. Each `cmd` takes a
    // while, so they run on their own thread, never holding up the input behind them.
    private static int batteryLevel = -1;
    private static boolean batteryPlugged, batteryCharging;
    private static final Object batteryLock = new Object();
    private static String[] batteryPending; // newest level, ac, status not yet applied
    private static void battery(int level, boolean plugged, boolean charging) {
        level = Math.max(1, Math.min(100, level));
        if (level == batteryLevel && plugged == batteryPlugged && charging == batteryCharging) return;
        if (batteryLevel < 0) {
            System.out.println("VM_INPUT battery " + level + "%" + (plugged ? " plugged" : "") + (charging ? " charging" : ""));
            Thread t = new Thread(Input::batteryLoop, "battery");
            t.setDaemon(true);
            t.start();
        }
        batteryLevel = level; batteryPlugged = plugged; batteryCharging = charging;
        synchronized (batteryLock) {
            batteryPending = new String[] { String.valueOf(level), plugged ? "1" : "0", charging ? "2" : plugged ? "5" : "3" };
            batteryLock.notify();
        }
    }

    private static void batteryLoop() {
        boolean first = true;
        while (true) {
            String[] v;
            synchronized (batteryLock) {
                while (batteryPending == null) try { batteryLock.wait(); } catch (InterruptedException e) { return; }
                v = batteryPending; batteryPending = null;
            }
            String[][] set = first
                ? new String[][] { { "level", v[0] }, { "present", "1" }, { "ac", v[1] }, { "usb", "0" }, { "wireless", "0" }, { "status", v[2] } }
                : new String[][] { { "level", v[0] }, { "ac", v[1] }, { "status", v[2] } };
            first = false;
            try {
                for (String[] a : set) Runtime.getRuntime().exec(new String[] { "cmd", "battery", "set", a[0], a[1] }).waitFor();
            } catch (Throwable t) { System.out.println("VM_INPUT battery: " + t); }
        }
    }

    // The pointer: a uinput mouse, so it is Android's own pointer and takes the shapes apps ask
    // for (an I-beam over text, a hand over a link), which Android applies to real mice only:
    // injected events all count as one virtual device. It is steered to the Mac cursor's position
    // (pointer acceleration is off, so motion maps 1:1), clicks and scrolls with it, and gives an
    // app holding pointer capture its raw motion. Its wheel has high resolution, 1/120 notch per
    // unit (W), so a Mac trackpad scrolls as finely as on the Mac. REL_X 0, REL_Y 1, REL_HWHEEL 6,
    // REL_WHEEL 8, REL_WHEEL_HI_RES 11, REL_HWHEEL_HI_RES 12; BTN_LEFT 272, BTN_RIGHT 273,
    // BTN_MIDDLE 274. Until it exists, events are injected instead.
    private static Process pointerProcess;
    private static volatile OutputStream pointerOut;
    private static volatile int pointerDeviceId;
    private static final Object steering = new Object();
    private static boolean steered;          // the pointer's position is known: px, py
    private static int px, py;
    private static long lastSteer;
    // Android moves the pointer by a fixed multiple of the motion (with acceleration off it still
    // scales it, by the display density it seems: 1.6875 at 240 dpi). Learnt from where the
    // pointer comes to rest (checkSteering): the motion sent since the last known position,
    // against how far the pointer went.
    private static double gainX = 1, gainY = 1, carryX, carryY;
    private static final String GAIN_FILE = "/data/local/tmp/vm-input.gain";   // so a boot starts right
    private static int anchorX, anchorY;
    private static long sentX, sentY;

    private static void steer(float tx, float ty) {
        synchronized (steering) {
            int sx = Math.round(tx), sy = Math.round(ty);
            // First, into the top left corner (Android stops it there), so the position is known
            if (!steered) {
                pointerSend("2,0,-30000,2,1,-30000,0,0,0");
                px = py = anchorX = anchorY = 0; sentX = sentY = 0; carryX = carryY = 0; steered = true;
            }
            double dx = (sx - px) / gainX + carryX, dy = (sy - py) / gainY + carryY;
            long ix = Math.round(dx), iy = Math.round(dy);
            carryX = dx - ix; carryY = dy - iy;
            if (ix != 0 || iy != 0) { pointerSend("2,0," + ix + ",2,1," + iy + ",0,0,0"); sentX += ix; sentY += iy; }
            px = sx; py = sy;
            lastSteer = SystemClock.uptimeMillis();
        }
    }

    /** Where Android has the pointer, from the input dump: if it isn't where the steering thinks
     *  (something else moved it), start from there. Only while the pointer rests. */
    private static void checkSteering(String dump) {
        int id = pointerDeviceId;
        if (id == 0 || locked) return;
        // Each window lists the pointer in its own coordinates; the pointer overlay covers the
        // display at its origin, so its entry is in display coordinates.
        int overlay = dump.indexOf("name='PointerEventDispatcherOverlay");
        if (overlay < 0) return;
        java.util.regex.Matcher m = java.util.regex.Pattern.compile("DeviceId\\(" + id + "\\):\\[touchingPointers=\\[[^\\]]*\\], downTimeInTarget=[^,]*, "
            + "hoveringPointers=\\[Pointer\\(id=0, MOUSE\\) at \\((-?[0-9.]+), (-?[0-9.]+)\\)").matcher(dump);
        if (!m.find(overlay) || dump.lastIndexOf("name='", m.start()) != overlay) return;
        int ax = Math.round(Float.parseFloat(m.group(1))), ay = Math.round(Float.parseFloat(m.group(2)));
        synchronized (steering) {
            if (!steered || SystemClock.uptimeMillis() - lastSteer < 400) return;
            if (Math.abs(ax - px) <= 1 && Math.abs(ay - py) <= 1) return;
            // Far enough moved to tell the gain (the corner stops are clean, so these are too)
            boolean learnt = false;
            if (Math.abs(sentX) >= 100 && ax - anchorX != 0) { double g = (double) (ax - anchorX) / sentX; if (g > 0.25 && g < 4) { gainX = g; learnt = true; } }
            if (Math.abs(sentY) >= 100 && ay - anchorY != 0) { double g = (double) (ay - anchorY) / sentY; if (g > 0.25 && g < 4) { gainY = g; learnt = true; } }
            if (learnt) {
                try (java.io.FileWriter f = new java.io.FileWriter(GAIN_FILE)) { f.write(gainX + " " + gainY + "\n"); }
                catch (Throwable t) { /* next boot learns it again */ }
            }
            System.out.println("VM_INPUT pointer at " + ax + "," + ay + ", expected " + px + "," + py + (learnt
                ? String.format(java.util.Locale.ROOT, ": gain now %.3f x %.3f", gainX, gainY) : ": corrected"));
            px = anchorX = ax; py = anchorY = ay; sentX = sentY = 0; carryX = carryY = 0;
        }
    }

    private static void pointerSend(String events) {
        try {
            OutputStream o = pointerOut;
            o.write(("{\"id\":1,\"command\":\"inject\",\"events\":[" + events + "]}\n").getBytes("UTF-8"));
            o.flush();
        } catch (Throwable t) { pointerOut = null; steered = false; }
    }

    private static void wheel(int vertical, int horizontal) {
        if (pointerOut == null || !pointerProcess.isAlive()) {
            try {
                if (pointerProcess != null) pointerProcess.destroy();
                pointerOut = null; steered = false;
                pointerProcess = new ProcessBuilder("/system/bin/uinput", "-").redirectErrorStream(true).start();
                OutputStream o = pointerProcess.getOutputStream();
                o.write(("{\"id\":1,\"command\":\"register\",\"name\":\"VM Pointer\",\"vid\":6900,\"pid\":30467,\"bus\":\"usb\","
                        + "\"configuration\":[{\"type\":100,\"data\":[1,2]},{\"type\":101,\"data\":[272,273,274]},{\"type\":102,\"data\":[0,1,6,8,11,12]}]}\n").getBytes("UTF-8"));
                o.flush();
                // Steering needs motion to map 1:1: no acceleration, the middle speed. In the
                // background (each `settings` call takes about a second); steering starts after.
                Thread accel = new Thread(() -> {
                    try {
                        for (String[] kv : new String[][] { { "mouse_pointer_acceleration_enabled", "0" }, { "pointer_speed", "0" } })
                            Runtime.getRuntime().exec(new String[] { "settings", "--user", "current", "put", "system", kv[0], kv[1] }).waitFor();
                    } catch (Throwable t) { System.out.println("VM_INPUT pointer settings: " + t); }
                    synchronized (steering) { steered = false; }
                }, "pointer-settings");
                accel.setDaemon(true);
                accel.start();
                pointerDeviceId = waitForDevice(pointerProcess, "VM Pointer");
                pointerOut = o;
                drain(pointerProcess, "pointer");
                System.out.println("VM_INPUT pointer registered");
                reply("w wheel");
            } catch (Throwable t) {
                System.out.println("VM_INPUT pointer unavailable, injecting instead: " + t);
                reply("w none");
                return;
            }
        }
        if (vertical != 0 || horizontal != 0) pointerSend("2,11," + vertical + ",2,12," + horizontal + ",0,0,0");
    }

    private static void drain(Process process, String tag) {
        Thread t = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                // Keep reading to the end, so a chatty process never blocks on a full pipe.
                String line; int n = 0;
                while ((line = r.readLine()) != null) if (n++ < 40) System.out.println("VM_INPUT " + tag + ": " + line);
            } catch (Throwable e) { /* process ended */ }
        }, tag);
        t.setDaemon(true);
        t.start();
    }

    // The keyboard: Android types with the layout picked for the VM's USB keyboard, US unless told
    // otherwise. The viewer sends the Mac's input source (L com.apple.keylayout.Brazilian-Pro, say)
    // and the closest of Android's own layouts goes on that keyboard, for the IME language in use.
    // Mac ids, most specific first; unknown ones leave Android's choice alone.
    private static final String[][] LAYOUTS = {
        { "Brazilian-Pro", "english_us_intl" }, { "USInternational", "english_us_intl" }, { "Brazilian", "brazilian" },
        { "Dvorak", "english_us_dvorak" }, { "Colemak", "english_us_colemak" }, { "British", "english_uk" }, { "Irish", "english_uk" },
        { "US", "english_us" }, { "ABC", "english_us" }, { "Australian", "english_us" }, { "Canadian-CSA", "french_ca" }, { "Canadian", "english_us" },
        { "SwissFrench", "swiss_french" }, { "Swiss French", "swiss_french" }, { "SwissGerman", "swiss_german" }, { "Swiss German", "swiss_german" },
        { "German", "german" }, { "Austrian", "german" }, { "Belgian", "belgian" }, { "French", "french" }, { "Spanish", "spanish" }, { "LatinAmerican", "spanish_latin" },
        { "Italian", "italian" }, { "Portuguese", "portuguese" }, { "Danish", "danish" }, { "Norwegian", "norwegian" }, { "Swedish", "swedish" },
        { "Finnish", "finnish" }, { "Icelandic", "icelandic" }, { "Dutch", "english_us" }, { "Polish", "polish" }, { "Czech-QWERTY", "czech_qwerty" },
        { "Czech", "czech" }, { "Slovak", "slovak" }, { "Hungarian", "hungarian" }, { "Croatian", "croatian" }, { "Slovenian", "slovenian" },
        { "Estonian", "estonian" }, { "Latvian", "latvian" }, { "Lithuanian", "lithuanian" }, { "Turkish-QWERTY", "turkish" }, { "Turkish", "turkish_f" },
        { "Greek", "greek" }, { "Russian", "russian_mac" }, { "Ukrainian", "ukrainian" }, { "Bulgarian", "bulgarian" }, { "Hebrew", "hebrew" }, { "Arabic", "arabic" },
    };
    private static String appliedLayout;

    private static synchronized void keyboardLayout(String macId) {
        String name = macId.startsWith("com.apple.keylayout.") ? macId.substring(20) : null, layout = null;
        if (name != null) for (String[] m : LAYOUTS) if (name.startsWith(m[0])) { layout = m[1]; break; }
        if (layout == null) { System.out.println("VM_INPUT keyboard: no Android layout for " + macId); return; }
        String descriptor = "com.android.inputdevices/com.android.inputdevices.InputDeviceReceiver/keyboard_layout_" + layout;
        try {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            java.lang.reflect.Method get = sm.getMethod("getService", String.class);
            Object im = Class.forName("android.hardware.input.IInputManager$Stub").getMethod("asInterface", IBinder.class).invoke(null, get.invoke(null, "input"));
            Object imm = Class.forName("com.android.internal.view.IInputMethodManager$Stub").getMethod("asInterface", IBinder.class).invoke(null, get.invoke(null, "input_method"));
            int user = (Integer) Class.forName("android.app.ActivityManager").getMethod("getCurrentUser").invoke(null);
            Object info = null, subtype = null;
            for (java.lang.reflect.Method m : imm.getClass().getMethods()) {
                if (m.getName().equals("getCurrentInputMethodInfoAsUser") && m.getParameterCount() == 1) info = m.invoke(imm, user);
                if (m.getName().equals("getCurrentInputMethodSubtype") && m.getParameterCount() == 1) subtype = m.invoke(imm, user);
            }
            int done = 0;
            for (int id : (int[]) im.getClass().getMethod("getInputDeviceIds").invoke(im)) {
                android.view.InputDevice d = (android.view.InputDevice) im.getClass().getMethod("getInputDevice", int.class).invoke(im, id);
                // QEMU's USB keyboard: the one the Mac keyboard types through
                if (d == null || d.isVirtual() || !d.getName().contains("Keyboard") || d.getKeyboardType() != android.view.InputDevice.KEYBOARD_TYPE_ALPHABETIC) continue;
                Object ident = d.getClass().getMethod("getIdentifier").invoke(d);
                boolean set = false;
                for (java.lang.reflect.Method m : im.getClass().getMethods()) {
                    if (!m.getName().equals("setKeyboardLayoutForInputDevice")) continue;
                    Class<?>[] t = m.getParameterTypes();
                    if (t.length == 5) { m.invoke(im, ident, user, info, subtype, descriptor); set = true; }
                    else if (t.length == 2) { m.invoke(im, ident, descriptor); set = true; }
                }
                if (set) done++;
                else {
                    StringBuilder sb = new StringBuilder();
                    for (java.lang.reflect.Method m : im.getClass().getMethods()) if (m.getName().contains("KeyboardLayout")) sb.append(' ').append(m.getName()).append(m.getParameterCount());
                    System.out.println("VM_INPUT keyboard: no way to set a layout here:" + sb);
                }
            }
            if (done > 0 && !descriptor.equals(appliedLayout)) {
                // Whether it took: the keyboard's character map has the layout's accent keys now
                SystemClock.sleep(1500);
                String check = "";
                for (int id : (int[]) im.getClass().getMethod("getInputDeviceIds").invoke(im)) {
                    android.view.InputDevice d = (android.view.InputDevice) im.getClass().getMethod("getInputDevice", int.class).invoke(im, id);
                    if (d == null || d.isVirtual() || !d.getName().contains("Keyboard")) continue;
                    android.view.KeyCharacterMap k = d.getKeyCharacterMap();
                    check = ", apostrophe " + ((k.get(android.view.KeyEvent.KEYCODE_APOSTROPHE, 0) & android.view.KeyCharacterMap.COMBINING_ACCENT) != 0 ? "is an accent" : "types '" + (char) k.get(android.view.KeyEvent.KEYCODE_APOSTROPHE, 0) + "'");
                }
                System.out.println("VM_INPUT keyboard " + name + " -> " + layout + check);
            }
            if (done > 0) appliedLayout = descriptor;
        } catch (Throwable t) {
            Throwable c = t instanceof java.lang.reflect.InvocationTargetException ? t.getCause() : t;
            System.out.println("VM_INPUT keyboard layout failed: " + c);
        }
    }

    /** How full Android's storage is ("d FREE TOTAL", MiB), so the viewer can warn before it runs
     *  out: on each new link, then every ten minutes. */
    private static void reportStorage() {
        OutputStream sentTo = null; long sentAt = 0;
        while (true) {
            OutputStream o = out;
            if (o != null && (o != sentTo || SystemClock.uptimeMillis() - sentAt > 600_000)) {
                try {
                    android.os.StatFs f = new android.os.StatFs("/data");
                    reply("d " + (f.getAvailableBytes() >> 20) + " " + (f.getTotalBytes() >> 20));
                    sentTo = o; sentAt = SystemClock.uptimeMillis();
                } catch (Throwable t) { /* not this time */ }
            }
            SystemClock.sleep(15_000);
        }
    }

    private static void reply(String line) {
        OutputStream o = out;
        if (o == null) return;
        try { synchronized (Input.class) { o.write((line + "\n").getBytes("UTF-8")); o.flush(); } } catch (Throwable t) { /* link closed */ }
    }

    private static void releaseAll() {
        locked = false;
        captureSent = false;
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

    private static int findDevice(String name) {
        try {
            for (int id : InputDevice.getDeviceIds()) {
                InputDevice d = InputDevice.getDevice(id);
                if (d != null && name.equals(d.getName())) return id;
            }
        } catch (Throwable t) { System.out.println("VM_INPUT device lookup: " + t); }
        return 0;
    }

    /** The id of the device a uinput process just registered, once Android has it (or 0 after
     *  3 s: it may still come, and events written meanwhile are only queued). */
    private static int waitForDevice(Process process, String name) {
        long until = SystemClock.uptimeMillis() + 3000;
        while (true) {
            if (!process.isAlive()) throw new IllegalStateException("uinput exited " + process.exitValue());
            int id = findDevice(name);
            if (id != 0 || SystemClock.uptimeMillis() > until) return id;
            SystemClock.sleep(30);
        }
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

    // Pointer capture has no listener a shell process can use, so read the input service's state
    // (the same text `dumpsys input` prints), twice a second while the Mac is using the VM.
    private static final java.util.regex.Pattern CAPTURE =
        java.util.regex.Pattern.compile("Pointer Capture (?:Mode )?Requested: (\\w+)");
    private static volatile boolean captureSent;
    private static void watchPointerCapture() {
        IBinder service = null;
        boolean reported = false;
        while (true) {
            // Twice a second while the Mac uses the VM, then not at all until it does again
            SystemClock.sleep(500);
            long idle = SystemClock.uptimeMillis() - lastActive;
            if (out == null || idle > 10000) continue;
            try {
                if (service == null) service = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "input");
                long start = SystemClock.uptimeMillis();
                String text = dump(service);
                java.util.regex.Matcher m = CAPTURE.matcher(text);
                // Android 16: UNCAPTURED, or the mode an app asked for; older releases: false or true
                boolean found = m.find(), wanted = found && !m.group(1).equals("UNCAPTURED") && !m.group(1).equals("false");
                if (!reported) {
                    reported = true;
                    System.out.println("VM_INPUT pointer capture " + (found ? "watched" : "state not found in the input dump")
                                       + " (" + (SystemClock.uptimeMillis() - start) + " ms a look, " + text.length() + " chars)");
                    if (!found) for (String l : text.split("\n")) if (l.contains("Pointer Capture")) System.out.println("VM_INPUT dump: " + l.trim());
                }
                if (!found) return;
                checkSteering(text);
                if (wanted != captureSent) {
                    captureSent = wanted;
                    reply("k " + (wanted ? "1" : "0"));
                    System.out.println("VM_INPUT pointer capture " + (wanted ? "requested" : "released"));
                }
            } catch (Throwable t) {
                if (!reported) { reported = true; System.out.println("VM_INPUT pointer capture watch: " + t); }
                service = null;
            }
        }
    }

    /** What a service writes for dumpsys. It writes into a pipe while we read the other end. */
    private static String dump(IBinder service) throws Exception {
        android.os.ParcelFileDescriptor[] pipe = android.os.ParcelFileDescriptor.createPipe();
        java.io.ByteArrayOutputStream text = new java.io.ByteArrayOutputStream();
        Thread reader = new Thread(() -> {
            try (java.io.InputStream in = new android.os.ParcelFileDescriptor.AutoCloseInputStream(pipe[0])) {
                byte[] b = new byte[16384];
                for (int n; (n = in.read(b)) > 0; ) text.write(b, 0, n);
            } catch (Throwable t) { /* closed */ }
        });
        reader.start();
        try { service.dump(pipe[1].getFileDescriptor(), new String[0]); }
        finally { pipe[1].close(); }
        reader.join(2000);
        return text.toString("UTF-8");
    }

    // The Mac's address on a shared network can change (Wi-Fi reconnects): the host then sends
    // the token again with the new one. The old connection would wait forever, so drop it.
    private static volatile Socket link;
    private static void followHost() {
        String was = host;
        if (!loadToken() || host.equals(was)) { host = was; return; }
        System.out.println("VM_INPUT the Mac moved to " + host);
        try { Socket s = link; if (s != null) s.close(); } catch (Throwable t) { /* closed */ }
    }

    private static void pollClipboard() {
        boolean reported = false;
        while (true) {
            SystemClock.sleep(700);
            followHost();
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
