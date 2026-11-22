// SPDX-License-Identifier: GPL-3.0-only
//
// Part of the rootless Play Integrity strong-integrity hook baked into the OTA
// system image (see integrity/ and patch-modules/integrity.py). This file is
// original to this repository.
package io.github.david568303.pi;

import android.content.Context;

import java.lang.reflect.Method;

/**
 * Framework code appended to framework.jar runs with no Context of its own. The
 * only way to reach the hosting app's package list (to resolve the caller) and
 * its data dir (for the keybox cache) is the current process's Application,
 * which the platform exposes through hidden statics. Those are grey-listed, so
 * they are reached by reflection rather than a compile-time reference.
 */
final class Ctx {
    private static volatile Context sContext;

    private Ctx() {}

    static Context get() {
        Context c = sContext;
        if (c != null) {
            return c;
        }
        c = resolve();
        if (c != null) {
            sContext = c;
        }
        return c;
    }

    private static Context resolve() {
        Context c = viaActivityThread();
        if (c == null) {
            c = viaAppGlobals();
        }
        return c;
    }

    private static Context viaActivityThread() {
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Method m = at.getMethod("currentApplication");
            Object app = m.invoke(null);
            return (app instanceof Context) ? (Context) app : null;
        } catch (Throwable t) {
            return null;
        }
    }

    private static Context viaAppGlobals() {
        try {
            Class<?> ag = Class.forName("android.app.AppGlobals");
            Method m = ag.getMethod("getInitialApplication");
            Object app = m.invoke(null);
            return (app instanceof Context) ? (Context) app : null;
        } catch (Throwable t) {
            return null;
        }
    }
}
