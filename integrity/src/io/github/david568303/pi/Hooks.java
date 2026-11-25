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
import java.util.Arrays;
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

    // Android key-attestation extension. Present on the leaf of a real
    // attestation chain; absent on ordinary keystore keys. chain() runs OS-wide
    // (no package gate) but only replaces a chain that carries this, so normal
    // keys -- TLS client certs, app-signing keys, system keys -- are untouched.
    private static final String ATTESTATION_OID = "1.3.6.1.4.1.11129.2.1.17";

    private Hooks() {}

    /**
     * @return a spoofed certificate chain for a targeted caller, or null to let
     *         the stock keystore answer (non-target, re-entry, or any failure).
     */
    public static Certificate[] chain(String alias) {
        PiLog.d("chain() entered");
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
            PiLog.d("skip: null alias");
            return null;
        }
        Context ctx = Ctx.get();
        if (ctx == null) {
            PiLog.d("skip: no app context for " + alias);
            return null;
        }

        // uid/packages are resolved only for logging and attestationApplicationId
        // now: chain() is OS-wide, so there is no package gate. config.json's
        // "packages" list is no longer consulted here. cfg is still required for
        // the RootOfTrust and keybox settings the generator needs.
        int uid = android.os.Process.myUid();
        String[] pkgs = ctx.getPackageManager().getPackagesForUid(uid);
        Config cfg = Config.current();
        if (cfg == null) {
            PiLog.d("skip: no config loaded (uid=" + uid + " pkgs=" + Arrays.toString(pkgs) + ")");
            return null;
        }

        IKeyboxProvider kb = KeyProviderManager.getProvider();
        if (kb == null || !kb.hasKeybox()) {
            PiLog.d("skip: no keybox (provider=" + (kb != null) + ") for " + alias);
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
            PiLog.d("served cached spoofed chain for " + alias);
            return cached;
        }

        // The genuine chain tells us the key the app actually holds (public key)
        // and the attestation challenge it asked for, so the spoofed leaf is
        // about the right key. Without it we cannot build a valid attestation,
        // so we fall through rather than return a bogus chain.
        Certificate[] real = realChain(alias);
        if (real == null || real.length == 0 || !(real[0] instanceof X509Certificate)) {
            PiLog.d("skip: real chain empty/not X509 for " + alias
                    + " (len=" + (real == null ? -1 : real.length) + ")");
            return null;
        }

        // OS-wide, but only for genuine attestation requests: the real leaf must
        // carry the key-attestation extension. This replaces the package gate --
        // any app that attests is spoofed -- while an ordinary key (no extension)
        // keeps its real chain, so unrelated keystore users are never clobbered.
        X509Certificate realLeaf = (X509Certificate) real[0];
        if (realLeaf.getExtensionValue(ATTESTATION_OID) == null) {
            PiLog.d("skip: not an attestation request for " + alias
                    + " (uid=" + uid + " pkgs=" + Arrays.toString(pkgs) + ")");
            return null;
        }

        Certificate[] built = KeyboxChainGenerator.generate(realLeaf, kb, cfg, ctx, uid);
        if (built == null || built.length == 0) {
            PiLog.d("skip: generator returned nothing for " + alias);
            return null;
        }
        CACHE.put(alias, built);
        PiLog.d("served spoofed chain for " + alias + " (" + built.length + " certs, uid=" + uid
                + " pkgs=" + Arrays.toString(pkgs) + ")");
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

    /**
     * TEE/StrongBox spoofs for the client-side KeyInfo accessors, spliced into
     * the head of KeyInfo#isInsideSecureHardware and #getSecurityLevel. Applied
     * OS-wide (unconditional): the splice returns the spoofed constant whenever
     * the hook returns non-zero, and these always do, so every caller in every
     * process sees hardware-backed / TEE -- not scoped to the target config, so
     * it also covers the process that actually calls these accessors (DroidGuard
     * and apps that probe their own key), where caller resolution is unreliable.
     *
     * Caveats: these are app-facing, in-process self-reports and do not feed
     * Play Integrity's server-side verdict (that rides on chain()'s attestation
     * chain). OS-wide scope means software-only keys now report as hardware-
     * backed too, and a genuine StrongBox key's level is reported as TEE (1).
     */
    public static boolean isInsideSecureHardware() {
        PiLog.d("[TEE] isInsideSecureHardware -> true (OS-wide)");
        return true;
    }

    public static int getSecurityLevel() {
        PiLog.d("[TEE] getSecurityLevel -> TEE=1 (OS-wide)");
        return 1;
    }
}
