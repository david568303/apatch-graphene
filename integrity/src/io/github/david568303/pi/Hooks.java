// SPDX-License-Identifier: GPL-3.0-only
//
// Entry point of the rootless Play Integrity strong-integrity hook. A single
// call to Hooks.chain is spliced into the head of
//   android.security.keystore2.AndroidKeyStoreSpi#engineGetCertificateChain
// by integrity/insert_hook.py; see integrity/ and patch-modules/integrity.py.
//
// The spoofing design (a keybox-signed leaf carrying a clean RootOfTrust,
// chained to the keybox's own Google-rooted certificates) is ported from
// UN1CA's KeyboxImitationHooks / KeyProviderManager / KeyboxChainGenerator
// (salvogiangri/UN1CA, GPL-3.0). This entry class is original to this
// repository.
package io.github.david568303.pi;

import android.content.Context;

import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public final class Hooks {

    // Guards the re-entrant lookup of the caller's *real* attestation chain:
    // chain() calls back into AndroidKeyStore, which re-enters this very hook.
    // While the flag is set we return null so the nested call runs the stock
    // engineGetCertificateChain body and hands back the genuine chain.
    private static final ThreadLocal<Boolean> REENTRANT = new ThreadLocal<>();

    // Built chains are cached by alias and invalidated whenever the active
    // keybox file's mtime changes (KeyProviderManager.version()).
    private static final Map<String, Certificate[]> CACHE = new ConcurrentHashMap<>();
    private static volatile long sCacheVersion = Long.MIN_VALUE;

    private Hooks() {}

    /**
     * @return a spoofed certificate chain for a targeted caller, or null to let
     *         the stock keystore answer (non-target, re-entry, or any failure).
     */
    public static Certificate[] chain(String alias) {
        if (Boolean.TRUE.equals(REENTRANT.get())) {
            return null; // nested lookup -> fall through to the real body
        }
        REENTRANT.set(Boolean.TRUE);
        try {
            return chainInner(alias);
        } catch (Throwable t) {
            // Fail open: a broken hook must never break an app's own keystore.
            PiLog.w("chain(" + alias + ") failed", t);
            return null;
        } finally {
            REENTRANT.remove();
        }
    }

    private static Certificate[] chainInner(String alias) throws Exception {
        if (alias == null) {
            return null;
        }
        Context ctx = Ctx.get();
        if (ctx == null) {
            return null;
        }

        // uid -> packages -> config match. A miss is the overwhelmingly common
        // path (every keystore user that is not a target), so it stays cheap.
        int uid = android.os.Process.myUid();
        String[] pkgs = ctx.getPackageManager().getPackagesForUid(uid);
        Config cfg = Config.current();
        if (cfg == null || !cfg.matches(pkgs)) {
            return null;
        }

        IKeyboxProvider kb = KeyProviderManager.getProvider();
        if (kb == null || !kb.hasKeybox()) {
            return null;
        }

        // Invalidate the cache when the active keybox changed under us.
        long version = KeyProviderManager.version();
        if (version != sCacheVersion) {
            CACHE.clear();
            sCacheVersion = version;
        }

        Certificate[] cached = CACHE.get(alias);
        if (cached != null) {
            return cached;
        }

        // The genuine chain tells us the key the app actually holds (public key)
        // and the attestation challenge it asked for, so the spoofed leaf is
        // about the right key. Without it we cannot build a valid attestation,
        // so we fall through rather than return a bogus chain.
        Certificate[] real = realChain(alias);
        if (real == null || real.length == 0 || !(real[0] instanceof X509Certificate)) {
            return null;
        }

        Certificate[] built = KeyboxChainGenerator.generate((X509Certificate) real[0], kb, cfg, ctx, uid);
        if (built == null || built.length == 0) {
            return null;
        }
        CACHE.put(alias, built);
        PiLog.d("served spoofed chain for " + alias + " (" + built.length + " certs)");
        return built;
    }

    /** Re-enter the stock keystore (guard set by chain()) to read the real chain. */
    private static Certificate[] realChain(String alias) {
        try {
            KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
            ks.load(null);
            return ks.getCertificateChain(alias);
        } catch (Throwable t) {
            PiLog.w("real chain lookup failed for " + alias, t);
            return null;
        }
    }
}
