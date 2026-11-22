// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from UN1CA's io.mesalabs.unica.KeyboxChainGenerator
// (salvogiangri/UN1CA, GPL-3.0). Re-implemented, not copied: it builds the
// fresh attestation leaf over the caller's *real* public key and challenge
// (so the spoof is about the key the app actually holds), signs it with the
// keybox batch key and prepends it to the keybox chain. The KeyDescription /
// AuthorizationList / RootOfTrust shape, tag numbers and the
// softwareEnforced/teeEnforced split follow UN1CA (and the Android key
// attestation spec); the RootOfTrust is forced to the strong state with the
// values from root_of_trust.json. Bundled BouncyCastle (org.bouncycastle),
// repackaged by R8, is used rather than the platform's hidden copy.
package io.github.david568303.pi;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Build;

import java.math.BigInteger;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPublicKey;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import org.bouncycastle.asn1.ASN1EncodableVector;
import org.bouncycastle.asn1.ASN1Enumerated;
import org.bouncycastle.asn1.ASN1Integer;
import org.bouncycastle.asn1.ASN1ObjectIdentifier;
import org.bouncycastle.asn1.ASN1OctetString;
import org.bouncycastle.asn1.ASN1Sequence;
import org.bouncycastle.asn1.ASN1Boolean;
import org.bouncycastle.asn1.DEROctetString;
import org.bouncycastle.asn1.DERNull;
import org.bouncycastle.asn1.DERSequence;
import org.bouncycastle.asn1.DERSet;
import org.bouncycastle.asn1.DERTaggedObject;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.asn1.x509.Extension;
import org.bouncycastle.asn1.x509.KeyUsage;
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo;
import org.bouncycastle.cert.X509CertificateHolder;
import org.bouncycastle.cert.X509v3CertificateBuilder;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;

final class KeyboxChainGenerator {

    private static final String ATTESTATION_OID = "1.3.6.1.4.1.11129.2.1.17";

    // KeyMint / Keymaster tag numbers (attestation AuthorizationList).
    private static final int T_PURPOSE = 1;
    private static final int T_ALGORITHM = 2;
    private static final int T_KEY_SIZE = 3;
    private static final int T_DIGEST = 5;
    private static final int T_PADDING = 6;
    private static final int T_EC_CURVE = 10;
    private static final int T_RSA_PUBLIC_EXPONENT = 200;
    private static final int T_NO_AUTH_REQUIRED = 503;
    private static final int T_CREATION_DATETIME = 701;
    private static final int T_ORIGIN = 702;
    private static final int T_ROOT_OF_TRUST = 704;
    private static final int T_OS_VERSION = 705;
    private static final int T_OS_PATCH_LEVEL = 706;
    private static final int T_ATTESTATION_APPLICATION_ID = 709;
    private static final int T_VENDOR_PATCH_LEVEL = 718;
    private static final int T_BOOT_PATCH_LEVEL = 719;

    // KeyMint enums.
    private static final int ALG_RSA = 1;
    private static final int ALG_EC = 3;
    private static final int PURPOSE_SIGN = 2;
    private static final int PURPOSE_VERIFY = 3;
    private static final int DIGEST_SHA_2_256 = 4;
    private static final int PAD_RSA_PKCS1_1_5_SIGN = 5;
    private static final int ORIGIN_GENERATED = 0;
    private static final int SECURITY_LEVEL_TEE = 1; // TrustedEnvironment

    private KeyboxChainGenerator() {}

    /** Context passed through only so the attestationApplicationId reflects the real caller. */
    static Certificate[] generate(X509Certificate realLeaf, IKeyboxProvider kb,
                                  Config cfg, Context ctx, int uid) throws Exception {
        PublicKey appKey = realLeaf.getPublicKey();
        boolean isEc = isEc(appKey.getAlgorithm());

        PrivateKey batchKey = isEc ? kb.getEcPrivateKey() : kb.getRsaPrivateKey();
        List<X509Certificate> batchChain = isEc ? kb.getEcCertificateChain() : kb.getRsaCertificateChain();
        if (batchKey == null || batchChain == null || batchChain.isEmpty()) {
            PiLog.d("keybox has no " + (isEc ? "EC" : "RSA") + " material");
            return null;
        }

        KeyGenParameters p = KeyGenParameters.from(realLeaf, appKey, isEc);
        X509Certificate leaf = buildLeaf(appKey, batchKey, batchChain.get(0), p, isEc,
                cfg.rootOfTrust, ctx, uid);

        Certificate[] out = new Certificate[1 + batchChain.size()];
        out[0] = leaf;
        for (int i = 0; i < batchChain.size(); i++) {
            out[i + 1] = batchChain.get(i);
        }
        return out;
    }

    private static boolean isEc(String alg) {
        return alg != null && (alg.equalsIgnoreCase("EC") || alg.equalsIgnoreCase("ECDSA"));
    }

    private static X509Certificate buildLeaf(PublicKey appKey, PrivateKey batchKey,
                                             X509Certificate batchCert, KeyGenParameters p,
                                             boolean isEc, Config.RootOfTrust rot,
                                             Context ctx, int uid) throws Exception {
        X500Name issuer = X500Name.getInstance(batchCert.getSubjectX500Principal().getEncoded());
        X500Name subject = new X500Name("CN=Android Keystore Key");
        SubjectPublicKeyInfo spki = SubjectPublicKeyInfo.getInstance(appKey.getEncoded());

        X509v3CertificateBuilder builder = new X509v3CertificateBuilder(
                issuer, p.serial, p.notBefore, p.notAfter, subject, spki);

        builder.addExtension(createExtension(p, rot, ctx, uid));
        builder.addExtension(Extension.keyUsage, true, new KeyUsage(KeyUsage.digitalSignature));

        ContentSigner signer = new JcaContentSignerBuilder(isEc ? "SHA256withECDSA" : "SHA256withRSA")
                .build(batchKey);
        X509CertificateHolder holder = builder.build(signer);
        return new JcaX509CertificateConverter().getCertificate(holder);
    }

    /** Builds the 1.3.6.1.4.1.11129.2.1.17 extension (KeyDescription). */
    private static Extension createExtension(KeyGenParameters p, Config.RootOfTrust rot,
                                             Context ctx, int uid) throws Exception {
        List<org.bouncycastle.asn1.ASN1Encodable> tee = new ArrayList<>();
        List<org.bouncycastle.asn1.ASN1Encodable> sw = new ArrayList<>();

        tee.add(tagged(T_PURPOSE, intSet(p.purposes)));
        tee.add(tagged(T_ALGORITHM, new ASN1Integer(p.algorithm)));
        tee.add(tagged(T_KEY_SIZE, new ASN1Integer(p.keySize)));
        tee.add(tagged(T_DIGEST, intSet(p.digests)));
        if (p.algorithm == ALG_RSA) {
            tee.add(tagged(T_PADDING, intSet(Collections.singletonList(PAD_RSA_PKCS1_1_5_SIGN))));
            tee.add(tagged(T_RSA_PUBLIC_EXPONENT, new ASN1Integer(p.rsaExponent)));
        } else {
            tee.add(tagged(T_EC_CURVE, new ASN1Integer(p.ecCurve)));
        }
        tee.add(tagged(T_NO_AUTH_REQUIRED, DERNull.INSTANCE));
        tee.add(tagged(T_ORIGIN, new ASN1Integer(ORIGIN_GENERATED)));
        tee.add(tagged(T_ROOT_OF_TRUST, rootOfTrust(rot)));
        tee.add(tagged(T_OS_VERSION, new ASN1Integer(p.osVersion)));
        tee.add(tagged(T_OS_PATCH_LEVEL, new ASN1Integer(p.osPatchLevel)));
        tee.add(tagged(T_VENDOR_PATCH_LEVEL, new ASN1Integer(p.vendorPatchLevel)));
        tee.add(tagged(T_BOOT_PATCH_LEVEL, new ASN1Integer(p.bootPatchLevel)));

        sw.add(tagged(T_CREATION_DATETIME, new ASN1Integer(System.currentTimeMillis())));
        sw.add(tagged(T_ATTESTATION_APPLICATION_ID, createApplicationId(ctx, uid)));

        ASN1OctetString keyDescription = getAsn1OctetString(
                tee.toArray(new org.bouncycastle.asn1.ASN1Encodable[0]),
                sw.toArray(new org.bouncycastle.asn1.ASN1Encodable[0]), p);
        return new Extension(new ASN1ObjectIdentifier(ATTESTATION_OID), false, keyDescription);
    }

    private static DERTaggedObject tagged(int tag, org.bouncycastle.asn1.ASN1Encodable v) {
        return new DERTaggedObject(true, tag, v);
    }

    private static DERSet intSet(List<Integer> values) {
        ASN1EncodableVector v = new ASN1EncodableVector();
        for (int i : values) {
            v.add(new ASN1Integer(i));
        }
        return new DERSet(v);
    }

    private static DERSequence rootOfTrust(Config.RootOfTrust rot) {
        ASN1EncodableVector v = new ASN1EncodableVector();
        v.add(new DEROctetString(rot.verifiedBootKey));
        v.add(rot.deviceLocked ? ASN1Boolean.TRUE : ASN1Boolean.FALSE);
        v.add(new ASN1Enumerated(rot.verifiedBootState)); // 0 = Verified
        v.add(new DEROctetString(rot.verifiedBootHash));
        return new DERSequence(v);
    }

    /** KeyDescription SEQUENCE, wrapped in the OCTET STRING that is the extension value. */
    private static ASN1OctetString getAsn1OctetString(org.bouncycastle.asn1.ASN1Encodable[] tee,
                                                      org.bouncycastle.asn1.ASN1Encodable[] sw,
                                                      KeyGenParameters p) throws Exception {
        ASN1EncodableVector kd = new ASN1EncodableVector();
        kd.add(new ASN1Integer(p.attestationVersion));
        kd.add(new ASN1Enumerated(SECURITY_LEVEL_TEE));
        kd.add(new ASN1Integer(p.keymasterVersion));
        kd.add(new ASN1Enumerated(SECURITY_LEVEL_TEE));
        kd.add(new DEROctetString(p.attestationChallenge));
        kd.add(new DEROctetString(new byte[0]));          // uniqueId
        kd.add(new DERSequence(sw));                        // softwareEnforced
        kd.add(new DERSequence(tee));                      // teeEnforced
        return new DEROctetString(new DERSequence(kd));
    }

    /** AttestationApplicationId built from the real caller's packages and signatures. */
    private static DEROctetString createApplicationId(Context ctx, int uid) throws Exception {
        PackageManager pm = ctx.getPackageManager();
        String[] pkgs = pm.getPackagesForUid(uid);
        if (pkgs == null || pkgs.length == 0) {
            pkgs = new String[]{ctx.getPackageName()};
        }

        ASN1EncodableVector packageInfos = new ASN1EncodableVector();
        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        List<byte[]> digests = new ArrayList<>();

        for (String pkg : pkgs) {
            PackageInfo pi = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES);
            ASN1EncodableVector info = new ASN1EncodableVector();
            info.add(new DEROctetString(pkg.getBytes("UTF-8")));
            info.add(new ASN1Integer(pi.getLongVersionCode()));
            packageInfos.add(new DERSequence(info));

            if (pi.signingInfo != null) {
                Signature[] sigs = pi.signingInfo.hasMultipleSigners()
                        ? pi.signingInfo.getApkContentsSigners()
                        : pi.signingInfo.getSigningCertificateHistory();
                if (sigs != null) {
                    for (Signature s : sigs) {
                        digests.add(sha.digest(s.toByteArray()));
                    }
                }
            }
        }

        ASN1EncodableVector digestSet = new ASN1EncodableVector();
        for (byte[] d : digests) {
            digestSet.add(new DEROctetString(d));
        }

        ASN1EncodableVector appId = new ASN1EncodableVector();
        appId.add(new DERSet(packageInfos));
        appId.add(new DERSet(digestSet));
        return new DEROctetString(new DERSequence(appId).getEncoded());
    }

    /** The parameters the fresh leaf attests to, derived from the caller's real key/cert. */
    static final class KeyGenParameters {
        byte[] attestationChallenge = new byte[0];
        int algorithm;
        int keySize;
        int ecCurve;
        long rsaExponent = 65537L;
        List<Integer> purposes;
        List<Integer> digests;
        BigInteger serial;
        java.util.Date notBefore;
        java.util.Date notAfter;
        int attestationVersion;
        int keymasterVersion;
        int osVersion;
        int osPatchLevel;
        int vendorPatchLevel;
        int bootPatchLevel;

        static KeyGenParameters from(X509Certificate realLeaf, PublicKey appKey, boolean isEc) {
            KeyGenParameters p = new KeyGenParameters();
            p.attestationChallenge = extractChallenge(realLeaf);
            p.algorithm = isEc ? ALG_EC : ALG_RSA;
            p.purposes = new ArrayList<>();
            p.purposes.add(PURPOSE_SIGN);
            p.purposes.add(PURPOSE_VERIFY);
            p.digests = Collections.singletonList(DIGEST_SHA_2_256);

            if (isEc) {
                int field = ((ECPublicKey) appKey).getParams().getCurve().getField().getFieldSize();
                p.keySize = field;
                p.ecCurve = (field <= 256) ? 1 : (field <= 384 ? 2 : 3); // P-256/384/521
            } else {
                RSAPublicKey rsa = (RSAPublicKey) appKey;
                p.keySize = rsa.getModulus().bitLength();
                p.rsaExponent = rsa.getPublicExponent().longValue();
            }

            p.serial = new BigInteger(64, new SecureRandom()).abs().add(BigInteger.ONE);
            p.notBefore = realLeaf.getNotBefore();
            p.notAfter = realLeaf.getNotAfter();

            int sdk = Build.VERSION.SDK_INT;
            int ver = (sdk >= 34) ? 400 : (sdk >= 33) ? 300 : (sdk >= 31) ? 200 : 100;
            p.attestationVersion = ver;
            p.keymasterVersion = ver;
            p.osVersion = osVersion();
            int patch = patchLevelYyyyMm();
            p.osPatchLevel = patch;
            p.vendorPatchLevel = patch * 100; // YYYYMMDD approximation
            p.bootPatchLevel = patch * 100;
            return p;
        }

        private static byte[] extractChallenge(X509Certificate cert) {
            try {
                byte[] ext = cert.getExtensionValue(ATTESTATION_OID);
                if (ext == null) {
                    return new byte[0];
                }
                ASN1OctetString wrapper = ASN1OctetString.getInstance(ext);
                ASN1Sequence kd = ASN1Sequence.getInstance(wrapper.getOctets());
                ASN1OctetString challenge = ASN1OctetString.getInstance(kd.getObjectAt(4));
                return challenge.getOctets();
            } catch (Throwable t) {
                PiLog.d("no attestation challenge in real cert: " + t);
                return new byte[0];
            }
        }

        private static int osVersion() {
            try {
                String[] parts = Build.VERSION.RELEASE.split("\\.");
                int maj = Integer.parseInt(parts[0]);
                int min = parts.length > 1 ? Integer.parseInt(parts[1]) : 0;
                int sub = parts.length > 2 ? Integer.parseInt(parts[2]) : 0;
                return maj * 10000 + min * 100 + sub;
            } catch (Throwable t) {
                return Build.VERSION.SDK_INT * 10000;
            }
        }

        private static int patchLevelYyyyMm() {
            try {
                String p = Build.VERSION.SECURITY_PATCH; // YYYY-MM-DD
                return Integer.parseInt(p.substring(0, 4) + p.substring(5, 7));
            } catch (Throwable t) {
                return 202401;
            }
        }
    }
}
