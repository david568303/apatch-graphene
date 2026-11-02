package app.seamlessupdate.client;

import android.net.Network;
import android.os.Build;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLSocketFactory;

/**
 * Resolves the correct rooted-graphene OTA for the flavor the user selected,
 * WITHOUT the upstream release assets being renamed. The channel picked in
 * Settings is reinterpreted as a build flavor:
 *
 *   stable -> rootless, beta -> pixincreate, alpha -> magisk
 *
 * The stock Updater derives the download file name in code from device + version
 * only, so the channel can never steer it to a different build and a resource
 * overlay cannot change that. That mapping lives here instead.
 *
 * SECURITY MODEL: everything this class returns is UNTRUSTED. It only decides
 * which file to download. The downloaded zip is still verified by
 * RecoverySystem.verifyPackage against the device OTA certificate and by
 * update_engine (AVB) before anything is installed (see Service), so a wrong or
 * hostile answer here can at worst cause a declined or skipped update, never an
 * untrusted install. Keep it that way: do not move any trust decision into this
 * class, and do not fetch a server-supplied absolute URL without the host/path
 * validation in targetFromUrl().
 */
final class OtaFeed {
    private static final String TAG = "OtaFeed";
    private static final int CONNECT_TIMEOUT = 30000;
    private static final int READ_TIMEOUT = 30000;

    // Upstream rooted-graphene OTA repository, its Custota feed (GitHub Pages),
    // and the only download prefix an asset is ever allowed to come from.
    static final String REPO = "rooted-graphene/ota";
    private static final String PAGES_BASE = "https://rooted-graphene.github.io/ota/";
    private static final String API_LATEST =
            "https://api.github.com/repos/" + REPO + "/releases/latest";
    private static final String RELEASE_DOWNLOAD_PREFIX =
            "https://github.com/" + REPO + "/releases/download/";

    private OtaFeed() {}

    /** Channel -> flavor directory used by both the Custota feed and asset names. */
    static String flavorForChannel(final String channel) throws GeneralSecurityException {
        // Ignore any "-security-preview" suffix: the rooted feed has no such builds.
        final String base = channel.endsWith("-security-preview")
                ? channel.substring(0, channel.length() - "-security-preview".length())
                : channel;
        switch (base) {
            case "stable": return "rootless";
            case "beta":   return "pixincreate";
            case "alpha":  return "magisk";
            default: throw new GeneralSecurityException("unknown channel: " + channel);
        }
    }

    /**
     * Strict, anchored asset-name pattern per flavor. The anchoring excludes the
     * -minimal / -test / -dirty variants by construction, and group(1) is the
     * build version (YYYYMMDDNN).
     */
    private static Pattern assetPattern(final String device, final String flavor)
            throws GeneralSecurityException {
        final String d = Pattern.quote(device);
        switch (flavor) {
            case "rootless":
                return Pattern.compile("^" + d + "-(\\d{1,18})-[0-9a-f]+-rootless\\.zip$");
            case "magisk":
                return Pattern.compile("^" + d + "-(\\d{1,18})-[0-9a-f]+-magisk-v[0-9.]+\\.zip$");
            case "pixincreate":
                return Pattern.compile("^" + d + "-(\\d{1,18})-[0-9a-f]+-pixincreate-v[0-9.]+\\.zip$");
            default:
                throw new GeneralSecurityException("unknown flavor: " + flavor);
        }
    }

    static final class Target {
        final String version;     // e.g. "2026102101"; equals the zip's post-build-incremental
        final String fileName;    // validated asset file name
        final String downloadUrl; // https://github.com/<REPO>/releases/download/<version>/<fileName>
        final String flavor;

        Target(final String version, final String fileName,
                final String downloadUrl, final String flavor) {
            this.version = version;
            this.fileName = fileName;
            this.downloadUrl = downloadUrl;
            this.flavor = flavor;
        }
    }

    /**
     * The newest OTA for the selected flavor, or null when the device is already
     * on it (and allowEqual is false) or nothing valid was found. Never throws
     * for a merely-absent build: callers treat null as "nothing to do".
     */
    static Target resolve(final Network network, final SSLSocketFactory tls,
            final String channel, final boolean allowEqual)
            throws GeneralSecurityException {
        final String device = Build.DEVICE;
        final String flavor = flavorForChannel(channel);
        final Pattern pattern = assetPattern(device, flavor);

        // Primary: the Custota feed (stable per-device-per-flavor URL, no API
        // rate limit, always points at the latest release). Fallback: the
        // GitHub "latest release" API. Either way the result is validated.
        Target target = resolveFromFeed(network, tls, device, flavor, pattern);
        if (target == null) {
            target = resolveFromApi(network, tls, device, flavor, pattern);
        }
        if (target == null) {
            Log.d(TAG, "no OTA found for " + device + " flavor " + flavor);
            return null;
        }

        final long installed = parseVersion(Build.VERSION.INCREMENTAL);
        final long found = parseVersion(target.version);
        if (found < installed || (found == installed && !allowEqual)) {
            Log.d(TAG, "version " + found + " not newer than installed " + installed
                    + " (allowEqual=" + allowEqual + ")");
            return null;
        }
        return target;
    }

    private static Target resolveFromFeed(final Network network, final SSLSocketFactory tls,
            final String device, final String flavor, final Pattern pattern)
            throws GeneralSecurityException {
        final String url = PAGES_BASE + flavor + "/" + device + ".json";
        final String body;
        try {
            body = readBody(network, tls, url, null, 1 << 20);
        } catch (final IOException e) {
            Log.d(TAG, "feed unavailable, will try API: " + e.getMessage());
            return null;
        }
        try {
            final JSONObject full = new JSONObject(body).getJSONObject("full");
            return targetFromUrl(full.getString("location_ota"), device, flavor, pattern);
        } catch (final JSONException e) {
            // Malformed feed is a validation failure, not a transient miss.
            throw new GeneralSecurityException("malformed Custota feed for " + device, e);
        }
    }

    private static Target resolveFromApi(final Network network, final SSLSocketFactory tls,
            final String device, final String flavor, final Pattern pattern)
            throws GeneralSecurityException {
        final String body;
        try {
            body = readBody(network, tls, API_LATEST, "application/vnd.github+json", 8 << 20);
        } catch (final IOException e) {
            Log.d(TAG, "latest-release API unavailable: " + e.getMessage());
            return null;
        }
        try {
            final JSONObject root = new JSONObject(body);
            final String tag = root.getString("tag_name");
            final JSONArray assets = root.getJSONArray("assets");
            String bestFile = null;
            long bestVer = -1;
            for (int i = 0; i < assets.length(); i++) {
                final String name = assets.getJSONObject(i).getString("name");
                final Matcher m = pattern.matcher(name);
                if (!m.matches()) {
                    continue;
                }
                final long v = parseVersion(m.group(1));
                if (v > bestVer) {
                    bestVer = v;
                    bestFile = name;
                }
            }
            if (bestFile == null) {
                // The inline asset list can be truncated for a release with many
                // devices; the feed is the authoritative path and has priority.
                return null;
            }
            return targetFromUrl(RELEASE_DOWNLOAD_PREFIX + tag + "/" + bestFile,
                    device, flavor, pattern);
        } catch (final JSONException e) {
            throw new GeneralSecurityException("malformed releases API response", e);
        }
    }

    /** Validate an untrusted download URL + asset name and build a Target. */
    private static Target targetFromUrl(final String location, final String device,
            final String flavor, final Pattern pattern) throws GeneralSecurityException {
        if (location == null || !location.startsWith(RELEASE_DOWNLOAD_PREFIX)) {
            throw new GeneralSecurityException("OTA location outside allowed prefix: " + location);
        }
        if (location.indexOf("..") >= 0 || location.indexOf('\\') >= 0
                || location.indexOf('?') >= 0 || location.indexOf('#') >= 0
                || location.indexOf('@') >= 0) {
            throw new GeneralSecurityException("illegal characters in OTA location");
        }
        final String rest = location.substring(RELEASE_DOWNLOAD_PREFIX.length()); // <tag>/<file>
        final int slash = rest.indexOf('/');
        if (slash <= 0 || rest.indexOf('/', slash + 1) >= 0) {
            throw new GeneralSecurityException("unexpected OTA location layout: " + location);
        }
        final String tag = rest.substring(0, slash);
        final String file = rest.substring(slash + 1);
        final Matcher m = pattern.matcher(file);
        if (!m.matches()) {
            throw new GeneralSecurityException(
                    "asset name does not match " + device + "/" + flavor + ": " + file);
        }
        final String version = m.group(1);
        if (!tag.equals(version)) {
            throw new GeneralSecurityException("tag " + tag + " != asset version " + version);
        }
        return new Target(version, file, location, flavor);
    }

    static long parseVersion(final String s) throws GeneralSecurityException {
        if (s == null || !s.matches("\\d{1,18}")) {
            throw new GeneralSecurityException("unparseable version: " + s);
        }
        return Long.parseLong(s);
    }

    /** Open an HTTPS connection over the given Network with the modern TLS factory. */
    static HttpsURLConnection open(final Network network, final SSLSocketFactory tls,
            final String urlString) throws IOException, GeneralSecurityException {
        if (!urlString.startsWith("https://")) {
            throw new GeneralSecurityException("refusing non-https URL: " + urlString);
        }
        final URL url = new URL(urlString);
        final HttpsURLConnection c = (HttpsURLConnection) network.openConnection(url);
        c.setSSLSocketFactory(tls);
        c.setConnectTimeout(CONNECT_TIMEOUT);
        c.setReadTimeout(READ_TIMEOUT);
        c.setRequestProperty("User-Agent", "rooted-graphene-updater");
        return c;
    }

    private static String readBody(final Network network, final SSLSocketFactory tls,
            final String url, final String accept, final int maxBytes)
            throws IOException, GeneralSecurityException {
        HttpsURLConnection c = null;
        try {
            c = open(network, tls, url);
            if (accept != null) {
                c.setRequestProperty("Accept", accept);
            }
            final int code = c.getResponseCode();
            if (code != HttpURLConnection.HTTP_OK) {
                throw new IOException("HTTP " + code + " for " + url);
            }
            try (final InputStream in = c.getInputStream();
                    final BufferedReader r = new BufferedReader(
                            new InputStreamReader(in, StandardCharsets.UTF_8))) {
                final StringBuilder sb = new StringBuilder();
                final char[] buf = new char[8192];
                int n;
                int total = 0;
                while ((n = r.read(buf)) != -1) {
                    total += n;
                    if (total > maxBytes) {
                        throw new IOException("response too large: " + url);
                    }
                    sb.append(buf, 0, n);
                }
                return sb.toString();
            }
        } finally {
            if (c != null) {
                c.disconnect();
            }
        }
    }
}
