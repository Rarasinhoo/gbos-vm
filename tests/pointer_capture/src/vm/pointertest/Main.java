// Test app for the automatic pointer (tests/pointer_capture.py): asks for pointer capture as soon
// as it has focus, logs every captured event, and lets go after 30 s.
package vm.pointertest;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.view.MotionEvent;
import android.view.PointerIcon;
import android.view.View;

public final class Main extends Activity {
    private static final String TAG = "VMPointerTest";
    private View view;
    private boolean asked;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        view = new View(this) {
            // Cursor shapes for tests/cursor_shapes: a text I-beam on the left half, a hand on the right
            @Override public PointerIcon onResolvePointerIcon(MotionEvent e, int index) {
                return PointerIcon.getSystemIcon(getContext(), e.getX(index) < getWidth() / 2f ? PointerIcon.TYPE_TEXT : PointerIcon.TYPE_HAND);
            }
        };
        view.setFocusable(true);
        view.setFocusableInTouchMode(true);
        view.setOnCapturedPointerListener((v, e) -> {
            Log.w(TAG, "captured action=" + e.getActionMasked() + " dx=" + e.getX() + " dy=" + e.getY()
                       + " buttons=" + e.getButtonState() + " source=0x" + Integer.toHexString(e.getSource()));
            return true;
        });
        setContentView(view);
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        if (!focused || asked || getIntent().getBooleanExtra("icons", false)) return;
        asked = true;
        view.requestFocus();
        view.requestPointerCapture();
        Log.w(TAG, "capture requested");
        new Handler(getMainLooper()).postDelayed(() -> {
            view.releasePointerCapture();
            Log.w(TAG, "capture released");
        }, 30000);
    }

    @Override public void onPointerCaptureChanged(boolean captured) {
        Log.w(TAG, "capture " + (captured ? "granted" : "lost"));
    }
}
