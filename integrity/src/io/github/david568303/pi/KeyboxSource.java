// SPDX-License-Identifier: GPL-3.0-only
//
// Part of the rootless Play Integrity strong-integrity hook baked into the OTA
// system image (see integrity/ and patch-modules/integrity.py). This file is
// original to this repository.
package io.github.david568303.pi;

import android.content.Context;

import java.io.File;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters;
import org.bouncycastle.crypto.signers.Ed25519Signer;
import org.json.JSONObject;

/**
 * Chooses the keybox the provider reads, in order:
 *
 *   1. a cached file in the hosting (GMS) process's own data dir, if adopted,
 *   2. otherwise the baked /system/etc/playintegrity/keybox.xml.
 *
 * A background fetch of the signed bundle at config keyboxUrl refreshes the
 * cache: at most one in flight, never on the verdict path (a daemon thread),
 * and only adopted if the bundle's Ed25519 signature verifies against the baked
 * public key AND the keybox validates (parses, has both RSA and ECDSA, chains
 * to a pinned Google root, not expired, no serial on the revocation list).
 * A rejected fetch keeps the current box: the source never regresses.
 */
final class KeyboxSource {
    private static final File BAKED = new File(Config.DIR, "keybox.xml");
    private static final long REFRESH_INTERVAL_MS = 6 * 60 * 60 * 1000L;
    private static final long ATTEMPT_THROTTLE_MS = 60 * 1000L;
    private static final int HTTP_TIMEOUT_MS = 15000;
    private static final int MAX_BUNDLE_BYTES = 256 * 1024;

    private static final AtomicBoolean FETCHING = new AtomicBoolean(false);
    private static volatile long sLastAttempt = 0L;

    private KeyboxSource() {}

    static File activeFile() {
        File cache = cacheFile();
        File active = (cache != null && cache.isFile() && cache.length() > 0) ? cache : BAKED;
        maybeFetch();
        return active;
    }

    static long version() {
        File f = activeFile();
        return (f == null) ? 0L : f.lastModified();
    }

    private static File cacheFile() {
        Context ctx = Ctx.get();
        if (ctx == null) {
            return null;
        }
        File base = ctx.getFilesDir();
        if (base == null) {
            return null;
        }
        return new File(new File(base, "playintegrity"), "keybox.xml");
    }

    private static void maybeFetch() {
        Config cfg = Config.current();
        if (cfg == null || cfg.keyboxUrl == null || cfg.keyboxSignKey == null) {
            return; // fetch not configured
        }
        long now = System.currentTimeMillis();
        File cache = cacheFile();
        boolean due = cache == null || !cache.isFile() || cache.length() == 0
                || (now - cache.lastModified() > REFRESH_INTERVAL_MS);
        if (!due || now - sLastAttempt < ATTEMPT_THROTTLE_MS) {
            return;
        }
        if (!FETCHING.compareAndSet(false, true)) {
            return; // one fetch in flight at most
        }
        sLastAttempt = now;
        Thread t = new Thread(() -> {
            try {
                fetchAndAdopt(cfg);
            } catch (Throwable e) {
                PiLog.w("keybox fetch rejected; keeping current box", e);
            } finally {
                FETCHING.set(false);
            }
        }, "pi-keybox-fetch");
        t.setDaemon(true);
        t.start();
    }

    private static void fetchAndAdopt(Config cfg) throws Exception {
        byte[] bundle = httpGet(cfg.keyboxUrl);
        byte[] keybox = verifyBundle(bundle, cfg.keyboxSignKey);
        validateKeybox(new String(keybox, StandardCharsets.UTF_8), cfg);

        File cache = cacheFile();
        if (cache == null) {
            throw new IllegalStateException("no cache dir to adopt into");
        }
        File dir = cache.getParentFile();
        if (dir != null && !dir.isDirectory() && !dir.mkdirs()) {
            throw new IllegalStateException("cannot create cache dir " + dir);
        }
        File tmp = new File(cache.getParentFile(), "keybox.xml.tmp");
        Files.write(tmp.toPath(), keybox);
        Files.move(tmp.toPath(), cache.toPath(),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        PiLog.d("adopted fetched keybox into " + cache);
    }

    /** Bundle: {"keybox":"<base64 xml>","sig":"<base64 Ed25519 over the xml bytes>"}. */
    private static byte[] verifyBundle(byte[] bundle, byte[] signPubKey) throws Exception {
        JSONObject j = new JSONObject(new String(bundle, StandardCharsets.UTF_8));
        byte[] keybox = Base64.getDecoder().decode(j.getString("keybox"));
        byte[] sig = Base64.getDecoder().decode(j.getString("sig"));

        Ed25519PublicKeyParameters pub = new Ed25519PublicKeyParameters(signPubKey, 0);
        Ed25519Signer verifier = new Ed25519Signer();
        verifier.init(false, pub);
        verifier.update(keybox, 0, keybox.length);
        if (!verifier.verifySignature(sig)) {
            throw new SecurityException("bundle signature does not verify");
        }
        return keybox;
    }

    private static void validateKeybox(String xml, Config cfg) throws Exception {
        IKeyboxProvider kb = KeyProviderManager.parseForValidation(xml);
        if (kb.getEcPrivateKey() == null || kb.getEcCertificateChain().isEmpty()
                || kb.getRsaPrivateKey() == null || kb.getRsaCertificateChain().isEmpty()) {
            throw new SecurityException("keybox missing EC or RSA material");
        }
        validateChain(kb.getEcCertificateChain(), cfg);
        validateChain(kb.getRsaCertificateChain(), cfg);
    }

    private static void validateChain(List<X509Certificate> chain, Config cfg) throws Exception {
        for (X509Certificate c : chain) {
            c.checkValidity(); // throws if expired / not yet valid
            if (cfg.revokedSerials.contains(c.getSerialNumber())) {
                throw new SecurityException("keybox serial is revoked: " + c.getSerialNumber());
            }
        }
        // Internal consistency: each cert signed by the next.
        for (int i = 0; i + 1 < chain.size(); i++) {
            chain.get(i).verify(chain.get(i + 1).getPublicKey());
        }
        // Pin the chain's top certificate to a configured Google root (SPKI SHA-256).
        if (!cfg.googleRoots.isEmpty()) {
            X509Certificate top = chain.get(chain.size() - 1);
            String spki = sha256Hex(top.getPublicKey().getEncoded());
            if (!cfg.googleRoots.contains(spki)) {
                throw new SecurityException("keybox does not chain to a pinned Google root");
            }
            top.verify(top.getPublicKey()); // root is self-signed
        }
    }

    private static String sha256Hex(byte[] data) throws Exception {
        byte[] d = java.security.MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder sb = new StringBuilder(d.length * 2);
        for (byte b : d) {
            sb.append(Character.forDigit((b >> 4) & 0xf, 16));
            sb.append(Character.forDigit(b & 0xf, 16));
        }
        return sb.toString();
    }

    private static byte[] httpGet(String url) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        try {
            conn.setConnectTimeout(HTTP_TIMEOUT_MS);
            conn.setReadTimeout(HTTP_TIMEOUT_MS);
            conn.setInstanceFollowRedirects(true);
            conn.setRequestMethod("GET");
            int code = conn.getResponseCode();
            if (code != 200) {
                throw new IllegalStateException("keybox fetch HTTP " + code);
            }
            try (InputStream in = conn.getInputStream()) {
                java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n, total = 0;
                while ((n = in.read(buf)) != -1) {
                    total += n;
                    if (total > MAX_BUNDLE_BYTES) {
                        throw new IllegalStateException("keybox bundle too large");
                    }
                    out.write(buf, 0, n);
                }
                return out.toByteArray();
            }
        } finally {
            conn.disconnect();
        }
    }
}
