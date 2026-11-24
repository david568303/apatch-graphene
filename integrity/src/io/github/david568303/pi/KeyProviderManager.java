// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from UN1CA's io.mesalabs.unica.KeyProviderManager and its
// DefaultKeyboxProvider (salvogiangri/UN1CA, GPL-3.0). Re-implemented, not
// copied: the keybox is read from a file (standard AndroidAttestation keybox
// XML) rather than a Samsung Settings.Secure blob, keys/certs are parsed
// eagerly into PrivateKey/X509Certificate, and reload is driven by file mtime.
// The XML shape (NumberOfKeyboxes, Key@algorithm, PrivateKey@format=pem,
// Certificate@format=pem) and the EC/RSA split follow UN1CA.
package io.github.david568303.pi;

import android.util.Xml;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.PrivateKey;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;

import org.bouncycastle.openssl.PEMKeyPair;
import org.bouncycastle.openssl.PEMParser;
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter;
import org.xmlpull.v1.XmlPullParser;

/** Singleton access to the active keybox provider. */
final class KeyProviderManager {

    private static volatile DefaultKeyboxProvider sInstance;

    private KeyProviderManager() {}

    static IKeyboxProvider getProvider() {
        DefaultKeyboxProvider p = sInstance;
        long version = version();
        if (p == null || p.version != version) {
            synchronized (KeyProviderManager.class) {
                p = sInstance;
                if (p == null || p.version != version) {
                    p = DefaultKeyboxProvider.load(version);
                    sInstance = p;
                }
            }
        }
        return p;
    }

    /** Version token of the active keybox; changes invalidate the chain cache. */
    static long version() {
        return KeyboxSource.version();
    }

    static File activeFile() {
        return KeyboxSource.activeFile();
    }

    /** Parse arbitrary keybox XML without caching, for KeyboxSource validation. */
    static IKeyboxProvider parseForValidation(String xml) throws Exception {
        return DefaultKeyboxProvider.parse(0L, xml);
    }

    /** Parses a keybox XML into EC/RSA batch keys and certificate chains. */
    static final class DefaultKeyboxProvider implements IKeyboxProvider {
        final long version;
        private final PrivateKey ecKey;
        private final List<X509Certificate> ecChain;
        private final PrivateKey rsaKey;
        private final List<X509Certificate> rsaChain;

        private DefaultKeyboxProvider(long version, PrivateKey ecKey, List<X509Certificate> ecChain,
                                      PrivateKey rsaKey, List<X509Certificate> rsaChain) {
            this.version = version;
            this.ecKey = ecKey;
            this.ecChain = ecChain;
            this.rsaKey = rsaKey;
            this.rsaChain = rsaChain;
        }

        static DefaultKeyboxProvider load(long version) {
            File f = activeFile();
            try {
                if (f == null || !f.isFile()) {
                    return empty(version);
                }
                String xml = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
                return parse(version, xml);
            } catch (Throwable t) {
                PiLog.w("keybox load failed from " + f, t);
                return empty(version);
            }
        }

        private static DefaultKeyboxProvider empty(long version) {
            return new DefaultKeyboxProvider(version, null, new ArrayList<>(), null, new ArrayList<>());
        }

        private static DefaultKeyboxProvider parse(long version, String xml) throws Exception {
            XmlPullParser xp = Xml.newPullParser();
            xp.setInput(new StringReader(xml));

            PrivateKey ecKey = null, rsaKey = null;
            List<X509Certificate> ecChain = new ArrayList<>();
            List<X509Certificate> rsaChain = new ArrayList<>();
            CertificateFactory cf = CertificateFactory.getInstance("X.509");

            String algo = null;        // "EC" or "RSA"
            int event = xp.getEventType();
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG) {
                    String name = xp.getName();
                    if ("Key".equals(name)) {
                        algo = normalizeAlgo(xp.getAttributeValue(null, "algorithm"));
                    } else if ("PrivateKey".equals(name) && algo != null) {
                        requirePem(xp, "PrivateKey");
                        PrivateKey k = parsePrivateKey(xp.nextText());
                        if ("EC".equals(algo)) {
                            ecKey = k;
                        } else if ("RSA".equals(algo)) {
                            rsaKey = k;
                        }
                    } else if ("Certificate".equals(name) && algo != null) {
                        requirePem(xp, "Certificate");
                        X509Certificate c = (X509Certificate) cf.generateCertificate(
                                new ByteArrayInputStream(
                                        canonicalPem(xp, "Certificate").getBytes(StandardCharsets.UTF_8)));
                        if ("EC".equals(algo)) {
                            ecChain.add(c);
                        } else if ("RSA".equals(algo)) {
                            rsaChain.add(c);
                        }
                    }
                }
                event = xp.next();
            }
            return new DefaultKeyboxProvider(version, ecKey, ecChain, rsaKey, rsaChain);
        }

        private static String normalizeAlgo(String a) {
            if (a == null) {
                return null;
            }
            a = a.trim().toLowerCase();
            if (a.startsWith("ec")) {
                return "EC";
            }
            if (a.startsWith("rsa")) {
                return "RSA";
            }
            return null;
        }

        private static void requirePem(XmlPullParser xp, String what) {
            String fmt = xp.getAttributeValue(null, "format");
            if (fmt != null && !"pem".equalsIgnoreCase(fmt)) {
                throw new IllegalArgumentException("Unsupported " + what + " format: " + fmt);
            }
        }

        /**
         * Rewrites an indented PEM block as canonical 64-column PEM.
         *
         * Keybox XML indents every line, which pushes base64 body lines past
         * OpenSSL's 64-character limit; Conscrypt's CertificateFactory then
         * fails with "PEM routines::OPENSSL_internal:BAD_END_LINE". The text
         * node is consumed here, so callers must not call nextText() again.
         */
        private static String canonicalPem(XmlPullParser xp, String what) throws Exception {
            String raw = xp.nextText();
            int begin = raw.indexOf("-----BEGIN ");
            if (begin < 0) {
                throw new IllegalArgumentException("Missing BEGIN marker in " + what);
            }
            int labelEnd = raw.indexOf("-----", begin + 11);
            if (labelEnd < 0) {
                throw new IllegalArgumentException("Malformed BEGIN marker in " + what);
            }
            String label = raw.substring(begin + 11, labelEnd).trim();
            String end = "-----END " + label + "-----";
            int endAt = raw.indexOf(end, labelEnd + 5);
            if (endAt < 0) {
                throw new IllegalArgumentException("Missing \"" + end + "\" in " + what);
            }
            String body = raw.substring(labelEnd + 5, endAt).replaceAll("\\s+", "");
            if (body.isEmpty()) {
                throw new IllegalArgumentException("Empty " + what + " PEM body");
            }
            StringBuilder sb = new StringBuilder(body.length() + 64);
            sb.append("-----BEGIN ").append(label).append("-----\n");
            for (int i = 0; i < body.length(); i += 64) {
                sb.append(body, i, Math.min(i + 64, body.length())).append('\n');
            }
            return sb.append(end).append('\n').toString();
        }

        private static PrivateKey parsePrivateKey(String pem) throws Exception {
            String normalizedPem = pem.replaceAll("(?m)^[\\t ]+", "").trim();

            try (PEMParser parser = new PEMParser(new StringReader(normalizedPem))) {
                Object o = parser.readObject();
                JcaPEMKeyConverter conv = new JcaPEMKeyConverter();
                if (o instanceof PEMKeyPair) {
                    return conv.getKeyPair((PEMKeyPair) o).getPrivate();
                }
                if (o instanceof org.bouncycastle.asn1.pkcs.PrivateKeyInfo) {
                    return conv.getPrivateKey((org.bouncycastle.asn1.pkcs.PrivateKeyInfo) o);
                }
                throw new IllegalArgumentException("Unsupported PrivateKey PEM object: "
                        + (o == null ? "null" : o.getClass().getName()));
            }
        }

        @Override
        public boolean hasKeybox() {
            return (ecKey != null && !ecChain.isEmpty()) || (rsaKey != null && !rsaChain.isEmpty());
        }

        @Override
        public PrivateKey getEcPrivateKey() {
            return ecKey;
        }

        @Override
        public List<X509Certificate> getEcCertificateChain() {
            return ecChain;
        }

        @Override
        public PrivateKey getRsaPrivateKey() {
            return rsaKey;
        }

        @Override
        public List<X509Certificate> getRsaCertificateChain() {
            return rsaChain;
        }
    }
}
