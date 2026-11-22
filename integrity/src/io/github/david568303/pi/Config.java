// SPDX-License-Identifier: GPL-3.0-only
//
// Part of the rootless Play Integrity strong-integrity hook baked into the OTA
// system image (see integrity/ and patch-modules/integrity.py). This file is
// original to this repository.
package io.github.david568303.pi;

import java.io.File;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Base64;
import java.util.Collections;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * The baked, read-only configuration under /system/etc/playintegrity:
 *
 *   config.json          which caller packages get a spoofed chain
 *   root_of_trust.json   the RootOfTrust the fresh leaf attests to
 *
 * Both are re-stat'd by mtime and reloaded on change, so an on-device override
 * (the module writes 0644, world-readable) takes effect without a reboot. A
 * parse failure never changes the live config: the last good value is kept.
 */
final class Config {
    static final String DIR = "/system/etc/playintegrity";
    private static final File CONFIG_FILE = new File(DIR, "config.json");
    private static final File ROT_FILE = new File(DIR, "root_of_trust.json");

    private static volatile Config sCurrent;
    private static volatile long sConfigMtime = -1L;
    private static volatile long sRotMtime = -1L;

    final Set<String> packages;
    final String keyboxUrl;          // $INTEGRITY_KEYBOX_URL, baked into config
    final byte[] keyboxSignKey;      // Ed25519 public half of the bundle signer
    final Set<String> googleRoots;   // pinned root SPKI SHA-256, lowercase hex
    final Set<BigInteger> revokedSerials;
    final RootOfTrust rootOfTrust;

    private Config(Set<String> packages, String keyboxUrl, byte[] keyboxSignKey,
                   Set<String> googleRoots, Set<BigInteger> revokedSerials, RootOfTrust rot) {
        this.packages = packages;
        this.keyboxUrl = keyboxUrl;
        this.keyboxSignKey = keyboxSignKey;
        this.googleRoots = googleRoots;
        this.revokedSerials = revokedSerials;
        this.rootOfTrust = rot;
    }

    /** Immutable RootOfTrust values; deviceLocked/verifiedBootState default to the strong state. */
    static final class RootOfTrust {
        final byte[] verifiedBootKey;
        final byte[] verifiedBootHash;
        final boolean deviceLocked;
        final int verifiedBootState; // 0 = Verified

        RootOfTrust(byte[] key, byte[] hash, boolean locked, int state) {
            this.verifiedBootKey = key;
            this.verifiedBootHash = hash;
            this.deviceLocked = locked;
            this.verifiedBootState = state;
        }
    }

    /** Re-stat both files; reload whichever changed. Returns the current config, or null if none is usable. */
    static Config current() {
        long cm = CONFIG_FILE.lastModified();
        long rm = ROT_FILE.lastModified();
        if (sCurrent != null && cm == sConfigMtime && rm == sRotMtime) {
            return sCurrent;
        }
        synchronized (Config.class) {
            cm = CONFIG_FILE.lastModified();
            rm = ROT_FILE.lastModified();
            if (sCurrent != null && cm == sConfigMtime && rm == sRotMtime) {
                return sCurrent;
            }
            try {
                Config loaded = load();
                sCurrent = loaded;
                sConfigMtime = cm;
                sRotMtime = rm;
                return loaded;
            } catch (Throwable t) {
                PiLog.w("config reload failed", t);
                // Record the mtimes so a broken edit is not retried every call,
                // but never regress a config that was already good.
                sConfigMtime = cm;
                sRotMtime = rm;
                return sCurrent;
            }
        }
    }

    private static Config load() throws Exception {
        JSONObject cfg = new JSONObject(read(CONFIG_FILE));

        Set<String> pkgs = new HashSet<>();
        JSONArray arr = cfg.optJSONArray("packages");
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                String p = arr.optString(i, null);
                if (p != null && !p.isEmpty()) {
                    pkgs.add(p);
                }
            }
        }
        String keyboxUrl = emptyToNull(cfg.optString("keyboxUrl", null));

        byte[] signKey = null;
        String sk = emptyToNull(cfg.optString("keyboxSignKey", null));
        if (sk != null) {
            signKey = decode(sk);
        }

        Set<String> roots = new HashSet<>();
        JSONArray rootsArr = cfg.optJSONArray("googleRoots");
        if (rootsArr != null) {
            for (int i = 0; i < rootsArr.length(); i++) {
                String h = rootsArr.optString(i, null);
                if (h != null && !h.isEmpty()) {
                    roots.add(h.trim().toLowerCase(Locale.ROOT));
                }
            }
        }

        Set<BigInteger> revoked = new HashSet<>();
        JSONArray revArr = cfg.optJSONArray("revokedSerials");
        if (revArr != null) {
            for (int i = 0; i < revArr.length(); i++) {
                BigInteger s = parseSerial(revArr.optString(i, null));
                if (s != null) {
                    revoked.add(s);
                }
            }
        }

        RootOfTrust rot = loadRootOfTrust();
        return new Config(Collections.unmodifiableSet(pkgs), keyboxUrl, signKey,
                Collections.unmodifiableSet(roots), Collections.unmodifiableSet(revoked), rot);
    }

    private static String emptyToNull(String s) {
        return (s == null || s.trim().isEmpty()) ? null : s.trim();
    }

    /** Serials may be written as hex (0x.. or an even hex run) or decimal. */
    static BigInteger parseSerial(String s) {
        if (s == null) {
            return null;
        }
        s = s.trim();
        if (s.isEmpty()) {
            return null;
        }
        try {
            if (s.startsWith("0x") || s.startsWith("0X")) {
                return new BigInteger(s.substring(2), 16);
            }
            if (s.matches("(?i)^[0-9a-f]+$") && s.matches(".*[a-fA-F].*")) {
                return new BigInteger(s, 16);
            }
            return new BigInteger(s);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static RootOfTrust loadRootOfTrust() throws Exception {
        JSONObject j = new JSONObject(read(ROT_FILE));
        byte[] key = decode(j.optString("verifiedBootKey", ""));
        byte[] hash = decode(j.optString("verifiedBootHash", ""));
        boolean locked = j.optBoolean("deviceLocked", true);
        int state = parseState(j.opt("verifiedBootState"));
        return new RootOfTrust(key, hash, locked, state);
    }

    private static int parseState(Object v) {
        if (v == null) {
            return 0; // Verified
        }
        String s = String.valueOf(v).trim();
        if ("VERIFIED".equalsIgnoreCase(s) || "0".equals(s)) {
            return 0;
        }
        if ("SELF_SIGNED".equalsIgnoreCase(s) || "1".equals(s)) {
            return 1;
        }
        if ("UNVERIFIED".equalsIgnoreCase(s) || "2".equals(s)) {
            return 2;
        }
        if ("FAILED".equalsIgnoreCase(s) || "3".equals(s)) {
            return 3;
        }
        return 0;
    }

    /** Accept hex or base64 for the 32-byte boot key/hash; empty -> 32 zero bytes. */
    private static byte[] decode(String s) {
        s = s == null ? "" : s.trim();
        if (s.isEmpty()) {
            return new byte[32];
        }
        if (s.matches("(?i)^[0-9a-f]+$") && (s.length() % 2 == 0)) {
            int n = s.length() / 2;
            byte[] out = new byte[n];
            for (int i = 0; i < n; i++) {
                out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
            }
            return out;
        }
        return Base64.getDecoder().decode(s);
    }

    private static String read(File f) throws Exception {
        return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    }

    boolean matches(String[] callerPackages) {
        if (callerPackages == null || packages.isEmpty()) {
            return false;
        }
        for (String p : callerPackages) {
            if (packages.contains(p)) {
                return true;
            }
        }
        return false;
    }
}
