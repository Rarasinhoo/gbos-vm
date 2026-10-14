// Test app for the automatic pointer (tests/pointer_capture.py): asks for pointer capture as soon
// as it has focus, logs every captured event, and lets go after 30 s.
package vm.pointertest;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.view.View;

public final class Main extends Activity {
    private static final String TAG = "VMPointerTest";
    private View view;
    private boolean asked;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        view = new View(this);
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
        if (!focused || asked) return;
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
