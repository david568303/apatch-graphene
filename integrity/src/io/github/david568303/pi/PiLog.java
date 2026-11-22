// SPDX-License-Identifier: GPL-3.0-only
//
// Part of the rootless Play Integrity strong-integrity hook baked into the OTA
// system image (see integrity/ and patch-modules/integrity.py). This file is
// original to this repository.
package io.github.david568303.pi;

import android.util.Log;

/**
 * Thin logging wrapper. Everything the hook does runs inside an app's own
 * process (whatever called the AndroidKeyStore), so it must never be chatty on
 * a hit and never throw out of a log call. Verbose output is gated on a
 * property so a shipped build is silent unless someone opts in.
 */
final class PiLog {
    static final String TAG = "PIHook";

    /** Toggle with: setprop persist.pihook.debug 1 (read once, cheaply). */
    private static final boolean DEBUG = readDebug();

    private PiLog() {}

    private static boolean readDebug() {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            Object v = sp.getMethod("get", String.class, String.class)
                    .invoke(null, "persist.pihook.debug", "0");
            return "1".equals(v) || "true".equals(v);
        } catch (Throwable t) {
            return false;
        }
    }

    static void d(String msg) {
        if (DEBUG) {
            Log.d(TAG, msg);
        }
    }

    static void w(String msg) {
        Log.w(TAG, msg);
    }

    static void w(String msg, Throwable t) {
        if (DEBUG) {
            Log.w(TAG, msg, t);
        } else {
            Log.w(TAG, msg + ": " + t);
        }
    }
}
