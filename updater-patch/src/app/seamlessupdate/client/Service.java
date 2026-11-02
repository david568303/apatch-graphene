package app.seamlessupdate.client;

import static android.os.Build.DEVICE;
import static android.os.Build.FINGERPRINT;
import static android.os.Build.VERSION.INCREMENTAL;

import android.app.IntentService;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Network;
import android.os.PowerManager;
import android.os.PowerManager.WakeLock;
import android.os.RecoverySystem;
import android.os.ServiceSpecificException;
import android.os.SystemProperties;
import android.os.UpdateEngine;
import android.os.UpdateEngine.ErrorCodeConstants;
import android.os.UpdateEngine.UpdateStatusConstants;
import android.os.UpdateEngineCallback;
import android.os.storage.StorageManager;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.nio.file.Files;
import java.security.GeneralSecurityException;
import java.util.concurrent.CountDownLatch;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import javax.net.ssl.HttpsURLConnection;

import org.grapheneos.tls.ModernTLSSocketFactory;

/**
 * rooted-graphene variant of the GrapheneOS Updater Service.
 *
 * Differences from stock (all behavior; see updater-patch/README.md):
 *   - The selected channel is a build flavor, resolved via OtaFeed against the
 *     rooted-graphene/ota releases instead of fetching a "<device>-<channel>"
 *     metadata file from a single server.
 *   - Full OTAs only (the rooted feed publishes no incrementals and no
 *     streaming assets), so the incremental/streaming paths are removed.
 *   - A same-version install is allowed exactly once right after the user
 *     changes flavor (the one-shot KEY_FLAVOR_SWITCH_PENDING flag); otherwise
 *     the install is gated on a strictly newer build, as stock.
 *
 * Unchanged: RecoverySystem.verifyPackage + the package metadata checks + AVB
 * via update_engine remain the trust anchors. OtaFeed output only selects the
 * file; it is never trusted.
 */
public class Service extends IntentService {
    private static final String TAG = "Service";
    static final String INTENT_EXTRA_NETWORK = "network";
    static final String INTENT_EXTRA_IS_USER_INITIATED = "is_user_initiated";
    private static final File CARE_MAP_PATH = new File("/data/ota_package/care_map.pb");
    private static final File UPDATE_PATH = new File("/data/ota_package/update.zip");
    private static final String PREFERENCE_DOWNLOAD_URL = "download_url";
    private static final int HTTP_RANGE_NOT_SATISFIABLE = 416;

    private final ModernTLSSocketFactory tlsSocketFactory = new ModernTLSSocketFactory();

    private NotificationHandler notificationHandler;
    private boolean mUpdating = false;

    public Service() {
        super(TAG);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        notificationHandler = new NotificationHandler(this);
    }

    private void applyUpdate(final long payloadOffset, final String[] headerKeyValuePairs)
            throws IOException {
        notificationHandler.showInstallNotification(0);

        final CountDownLatch monitor = new CountDownLatch(1);
        final UpdateEngine engine = new UpdateEngine();
        final var callback = new UpdateEngineCallback() {
            Integer errorCode = null;

            @Override
            public void onStatusUpdate(int status, float percent) {
                Log.d(TAG, "onStatusUpdate: " + status + ", " + percent * 100 + "%");
                if (status == UpdateStatusConstants.DOWNLOADING) {
                    notificationHandler.showInstallNotification(Math.round(percent * 100));
                } else if (status == UpdateStatusConstants.VERIFYING) {
                    notificationHandler.showValidateNotification(Math.round(percent * 100));
                } else if (status == UpdateStatusConstants.FINALIZING) {
                    notificationHandler.showFinalizeNotification(Math.round(percent * 100));
                }
            }

            @Override
            public void onPayloadApplicationComplete(final int errorCode) {
                Log.d(TAG, "onPayloadApplicationComplete: " + errorCode);
                this.errorCode = errorCode;
                UPDATE_PATH.delete();
                if (errorCode == ErrorCodeConstants.SUCCESS) {
                    annoyUser();
                }
                monitor.countDown();
            }
        };
        engine.bind(callback);
        UPDATE_PATH.setReadable(true, false);
        engine.applyPayload("file://" + UPDATE_PATH, payloadOffset, 0, headerKeyValuePairs);
        try {
            monitor.await();
        } catch (InterruptedException e) {}

        if (!engine.unbind()) {
            Log.e(TAG, "unable to unbind update_engine");
        }

        if (callback.errorCode != null && callback.errorCode != ErrorCodeConstants.SUCCESS) {
            throw new IOException("update_engine error code: " + callback.errorCode);
        }
    }

    private static ZipEntry getEntry(final ZipFile zipFile, final String name) throws GeneralSecurityException {
        final ZipEntry entry = zipFile.getEntry(name);
        if (entry == null) {
            throw new GeneralSecurityException("missing zip entry: " + name);
        }
        return entry;
    }

    private void onDownloadFinished(final OtaFeed.Target target, final boolean allowEqual)
            throws IOException, GeneralSecurityException {
        try {
            notificationHandler.showVerifyNotification(0);
            RecoverySystem.verifyPackage(UPDATE_PATH, (int progress) -> {
                Log.d(TAG, "verifyPackage: " + progress + "%");
                notificationHandler.showVerifyNotification(progress);
            }, null);
        } catch (final GeneralSecurityException e) {
            UPDATE_PATH.delete();
            throw e;
        }

        try (final ZipFile zipFile = new ZipFile(UPDATE_PATH)) {
            final ZipEntry metadata = getEntry(zipFile, "META-INF/com/android/metadata");
            long timestamp = 0;
            String incremental = null;
            String device = null;
            String serialno = null;
            String type = null;
            String streamingPropertyFiles[] = null;
            String sourceIncremental = null;
            String sourceFingerprint = null;
            try (final var reader = new BufferedReader(new InputStreamReader(zipFile.getInputStream(metadata)))) {
                for (String line; (line = reader.readLine()) != null; ) {
                    final String[] pair = line.split("=");
                    if ("post-timestamp".equals(pair[0])) {
                        timestamp = Long.parseLong(pair[1]);
                    } else if ("post-build-incremental".equals(pair[0])) {
                        incremental = pair[1];
                    } else if ("pre-device".equals(pair[0])) {
                        device = pair[1];
                    } else if ("serialno".equals(pair[0])) {
                        serialno = pair[1];
                    } else if ("ota-type".equals(pair[0])) {
                        type = pair[1];
                    } else if ("ota-streaming-property-files".equals(pair[0])) {
                        streamingPropertyFiles = pair[1].trim().split(",");
                    } else if ("pre-build-incremental".equals(pair[0])) {
                        sourceIncremental = pair[1];
                    } else if ("pre-build".equals(pair[0])) {
                        sourceFingerprint = pair[1];
                    }
                }
            }
            // The selected build's version must match what discovery pointed at.
            if (!target.version.equals(incremental)) {
                throw new GeneralSecurityException("post-build-incremental " + incremental
                        + " does not match selected version " + target.version);
            }
            // Monotonic install gate: strictly newer, except for the one-shot
            // same-version flavor switch, which still passes every other check.
            final long sourceBuildDate = SystemProperties.getLong("ro.build.date.utc", 0);
            if (timestamp < sourceBuildDate || (timestamp == sourceBuildDate && !allowEqual)) {
                throw new GeneralSecurityException("post-timestamp " + timestamp
                        + " not newer than installed " + sourceBuildDate);
            }
            if (!DEVICE.equals(device)) {
                throw new GeneralSecurityException("device mismatch");
            }
            if (serialno != null) {
                throw new GeneralSecurityException("serialno constraint not permitted");
            }
            if (!"AB".equals(type)) {
                throw new GeneralSecurityException("package is not an A/B update");
            }
            // Full OTAs carry no pre-build fields; if present (incremental), they
            // must match the installed build. The rooted feed ships full OTAs.
            if (sourceIncremental != null && !sourceIncremental.equals(INCREMENTAL)) {
                throw new GeneralSecurityException("source incremental mismatch");
            }
            if (sourceFingerprint != null && !sourceFingerprint.equals(FINGERPRINT)) {
                throw new GeneralSecurityException("source fingerprint mismatch");
            }

            if (streamingPropertyFiles == null) {
                throw new GeneralSecurityException("ota-streaming-property-files missing");
            }
            Long payloadOffset = null;
            for (final String streamingPropertyFile : streamingPropertyFiles) {
                final String properties[] = streamingPropertyFile.split(":");
                if ("payload.bin".equals(properties[0])) {
                    payloadOffset = Long.parseLong(properties[1]);
                    break;
                }
            }
            if (payloadOffset == null) {
                throw new GeneralSecurityException("payload offset missing");
            }

            Files.deleteIfExists(CARE_MAP_PATH.toPath());
            final ZipEntry careMapEntry = zipFile.getEntry("care_map.pb");
            if (careMapEntry == null) {
                Log.w(TAG, "care_map.pb missing");
            } else {
                Files.copy(zipFile.getInputStream(careMapEntry), CARE_MAP_PATH.toPath());
                CARE_MAP_PATH.setReadable(true, false);
            }

            final String[] headerKeyValuePairs;
            final ZipEntry payloadProperties = getEntry(zipFile, "payload_properties.txt");
            try (final var propertiesReader = new BufferedReader(new InputStreamReader(zipFile.getInputStream(payloadProperties)))) {
                headerKeyValuePairs = propertiesReader.lines().toArray(String[]::new);
            }
            applyUpdate(payloadOffset, headerKeyValuePairs);
        } catch (final GeneralSecurityException e) {
            UPDATE_PATH.delete();
            throw e;
        }
    }

    private void annoyUser() {
        PeriodicJob.cancel(this);
        final SharedPreferences preferences = Settings.getPreferences(this);
        preferences.edit().putBoolean(Settings.KEY_WAITING_FOR_REBOOT, true).apply();
        if (Settings.getIdleReboot(this)) {
            IdleReboot.schedule(this);
        }
        notificationHandler.showRebootNotification();
    }

    @Override
    protected void onHandleIntent(final Intent intent) {
        Log.d(TAG, "onHandleIntent");

        final Network network = intent.getParcelableExtra(INTENT_EXTRA_NETWORK, Network.class);
        final var serviceIsUserInitiated = intent.getBooleanExtra(INTENT_EXTRA_IS_USER_INITIATED, false);
        if (serviceIsUserInitiated) Log.d(TAG, "onHandleIntent() – service is user-initiated");

        final PowerManager pm = getSystemService(PowerManager.class);
        final WakeLock wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Updater:" + TAG);
        HttpsURLConnection connection = null;
        InputStream input = null;
        try {
            wakeLock.acquire();

            if (mUpdating) {
                Log.d(TAG, "updating already, returning early");
                return;
            }
            final SharedPreferences preferences = Settings.getPreferences(this);
            if (preferences.getBoolean(Settings.KEY_WAITING_FOR_REBOOT, false)) {
                Log.d(TAG, "updated already, waiting for reboot");
                return;
            }
            mUpdating = true;
            notificationHandler.start();

            if (network == null) {
                throw new IOException("Network is unavailable");
            }

            final String channel = Settings.getChannel(this);

            // Consume the one-shot flavor-switch flag: a same-version install is
            // allowed only right after the user changed flavor, and only once.
            // Reading-and-clearing here means a failed attempt does not loop on
            // an equal-version build; the user must toggle again.
            final boolean allowEqual = preferences.getBoolean(Settings.KEY_FLAVOR_SWITCH_PENDING, false);
            if (allowEqual) {
                preferences.edit().putBoolean(Settings.KEY_FLAVOR_SWITCH_PENDING, false).commit();
            }

            Log.d(TAG, "resolving OTA for " + DEVICE + " channel " + channel + " allowEqual=" + allowEqual);
            final OtaFeed.Target target = OtaFeed.resolve(network, tlsSocketFactory, channel, allowEqual);
            if (target == null) {
                notificationHandler.showUpdatedNotification(channel);
                Log.d(TAG, "no newer update available");
                mUpdating = false;
                return;
            }
            Log.d(TAG, "selected " + target.fileName + " (" + target.downloadUrl + ")");

            notificationHandler.showDownloadNotification(0, 100);

            final String downloadUrl = target.downloadUrl;
            final String savedUrl = preferences.getString(PREFERENCE_DOWNLOAD_URL, null);
            long downloaded;
            if (downloadUrl.equals(savedUrl)) {
                downloaded = UPDATE_PATH.length();
            } else {
                downloaded = 0;
            }

            long contentLength;
            if (downloaded > 0) {
                Log.d(TAG, "resume fetch of " + downloadUrl + " from " + downloaded + " bytes");
                connection = OtaFeed.open(network, tlsSocketFactory, downloadUrl);
                connection.setRequestProperty("Range", "bytes=" + downloaded + "-");
                final int responseCode = connection.getResponseCode();
                if (responseCode == HTTP_RANGE_NOT_SATISFIABLE) {
                    Log.d(TAG, "download completed previously");
                    onDownloadFinished(target, allowEqual);
                    return;
                }
                if (responseCode == HttpURLConnection.HTTP_OK) {
                    // Server ignored the Range request; restart from the top.
                    Log.d(TAG, "range ignored, restarting download");
                    downloaded = 0;
                    Files.deleteIfExists(UPDATE_PATH.toPath());
                    contentLength = connection.getContentLengthLong();
                } else if (responseCode == HttpURLConnection.HTTP_PARTIAL) {
                    contentLength = connection.getContentLengthLong() + downloaded;
                } else {
                    throw new IOException("unexpected response resuming download: " + responseCode);
                }
                input = connection.getInputStream();
            } else {
                Files.deleteIfExists(UPDATE_PATH.toPath());
                connection = OtaFeed.open(network, tlsSocketFactory, downloadUrl);
                final int responseCode = connection.getResponseCode();
                if (responseCode != HttpURLConnection.HTTP_OK) {
                    throw new IOException("unexpected response: " + responseCode);
                }
                contentLength = connection.getContentLengthLong();
                input = connection.getInputStream();
            }

            notificationHandler.showDownloadNotification(downloaded, contentLength);

            final long requiredBytes = contentLength - downloaded;
            try {
                StorageManager sm = getSystemService(StorageManager.class);
                // TODO: allocating bytes for file descriptor is more reliable, but it breaks the current
                //  download resume code
                sm.allocateBytes(sm.getUuidForPath(UPDATE_PATH), requiredBytes, StorageManager.FLAG_ALLOCATE_AGGRESSIVE);
            } catch (IOException e) {
                // storage space is likely to become available later
                Log.d(TAG, "unable to allocate " + requiredBytes + " bytes, proceeding anyway", e);
            }

            try (final OutputStream output = new FileOutputStream(UPDATE_PATH, downloaded != 0)) {
                preferences.edit().putString(PREFERENCE_DOWNLOAD_URL, downloadUrl).commit();

                int bytesRead;
                long last = System.nanoTime();
                final byte[] buffer = new byte[16384];
                while ((bytesRead = input.read(buffer)) != -1) {
                    output.write(buffer, 0, bytesRead);
                    downloaded += bytesRead;
                    final long now = System.nanoTime();
                    if (now - last > 1000 * 1000 * 1000) {
                        Log.d(TAG, "downloaded " + downloaded + " from " + contentLength + " bytes");
                        notificationHandler.showDownloadNotification(downloaded, contentLength);
                        last = now;
                    }
                }
            }

            Log.d(TAG, "download completed");
            onDownloadFinished(target, allowEqual);
        } catch (GeneralSecurityException | IOException | ServiceSpecificException e) {
            Log.e(TAG, "failed to download and install update", e);
            notificationHandler.showFailureNotification(e.getMessage());
            mUpdating = false;
            if (serviceIsUserInitiated) {
                // Either the user will try again immediately or the already scheduled periodic
                // job will pick it up under constraints (which will retry on failure)
                Log.w(TAG, "onHandleIntent() – service failed but failure is ignored because it was user-initiated");
            } else {
                PeriodicJob.scheduleRetry(this);
                Log.w(TAG, "onHandleIntent() – service failed but has been scheduled for retry");
            }
        } finally {
            if (input != null) {
                try {
                    input.close();
                } catch (final IOException e) {
                    Log.d(TAG, "closing input failed", e);
                }
            }
            if (connection != null) {
                connection.disconnect();
            }
            notificationHandler.cancelProgressNotification();
            Log.d(TAG, "release wake lock");
            wakeLock.release();
        }
    }
}
