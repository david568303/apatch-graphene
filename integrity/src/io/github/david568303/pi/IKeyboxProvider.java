// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from UN1CA's io.mesalabs.unica.IKeyboxProvider
// (salvogiangri/UN1CA, GPL-3.0). Re-implemented, not copied: the methods hand
// back parsed PrivateKey / X509Certificate objects (UN1CA returns PEM strings)
// and drop the Samsung-specific keybox availability property.
package io.github.david568303.pi;

import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.util.List;

/** Supplies the keybox's own batch key and its certificate chain, per algorithm. */
interface IKeyboxProvider {
    boolean hasKeybox();

    PrivateKey getEcPrivateKey();

    List<X509Certificate> getEcCertificateChain();

    PrivateKey getRsaPrivateKey();

    List<X509Certificate> getRsaCertificateChain();
}
