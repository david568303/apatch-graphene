# Patched System Updater for rooted-graphene

This makes the **stock GrapheneOS System Updater** install rooted-graphene OTAs,
with the channel picker choosing a build flavor:

| Channel (stored value) | Shown as    | Flavor it installs |
| ---------------------- | ----------- | ------------------ |
| `stable`               | Rootless    | rootless           |
| `beta`                 | Pixincreate | pixincreate (Magisk fork) |
| `alpha`                | Magisk      | magisk             |

The upstream `rooted-graphene/ota` releases are **not changed in any way** — not
renamed, no assets added, no new storage. All of the work is on the Updater side.

> **Status: untested.** The Java and resources are the reviewable core and are
> written against the real GrapheneOS Updater sources, but the APK build
> (`build.sh`) has not been run against a real APK or device here. Build it, then
> work through the on-device checklist at the bottom before relying on it.

This is **off by default**. Nothing here runs unless `PATCH_UPDATER=true` is set
for the build; otherwise this branch behaves exactly like upstream.

---

## Why the Updater has to change (an overlay can't do it)

A runtime resource overlay (RRO) can only replace *resources*. It is enough for
the **labels** (`channel_stable/beta/alpha`), and that part is still done with an
overlay (`labels-overlay/`). It is **not** enough for the mapping:

- The stock Updater builds the download file name in code as
  `<device>-ota_update-<version>.zip`; the channel never appears in it.
- There is a single `string/url`; it can't vary per channel.
- The metadata line carries no filename, so it can't redirect either.

So all three channels would resolve to the same zip URL — the flavor mapping and
the release discovery can only live in code. That code is `OtaFeed.java`, plus
the edits to `Service.java` and `Settings.java`.

## How a flavor is discovered (upstream naming untouched)

`OtaFeed` treats discovery as **untrusted** — it only picks *which file* to
download. For the selected flavor it tries, in order:

1. **Custota feed** (primary): `https://rooted-graphene.github.io/ota/<flavor>/<device>.json`.
   Upstream already publishes and maintains this; it is a stable per-flavor URL
   that always points at the newest release, with no API rate limit. The exact
   zip URL comes from its `full.location_ota`.
2. **GitHub "latest release" API** (fallback): `releases/latest`, matching the
   flavor's asset by a strict anchored name pattern.
3. **Recovery sideload** (ultimate fallback): always works regardless of the
   app; see the top-level README.

No new "specific name" asset is needed on the release — the Custota feed already
provides the stable pointer, so upstream's layout and storage are left alone.

## Trust model (unchanged from stock)

Discovery output is never trusted. The downloaded zip is still verified by:

- `RecoverySystem.verifyPackage` against the device OTA certificate, and
- `update_engine` / AVB,

exactly as stock. A wrong or hostile discovery answer can at worst cause a
**declined or skipped** update, never an untrusted install. Do not move any
trust decision into `OtaFeed`.

## Behavior changes and their hardening

- **Untrusted input validation.** `OtaFeed.targetFromUrl` requires the download
  URL to start with `https://github.com/rooted-graphene/ota/releases/download/`,
  rejects `..`, `\`, `?`, `#`, `@`, enforces a `<tag>/<file>` layout, requires
  the asset name to match a strict per-flavor regex, and requires the tag
  directory to equal the version embedded in the file name. Response bodies are
  size-capped.
- **Same-version flavor switch is one-shot and tightly gated.** Changing the
  channel sets `KEY_FLAVOR_SWITCH_PENDING`. `Service` reads **and clears** it on
  the next check, so a failed attempt can't loop on an equal-version build. It
  relaxes only the "strictly newer timestamp" rule; device, A/B, serialno,
  `post-build-incremental == selected version`, and signature checks all still
  run. No system property can trigger it.
- **Fail safe.** Any ambiguity (no match, malformed feed) → nothing installs and
  the device reports "up to date"/retry; it never installs a guess. Existing
  retry/backoff is preserved.
- **No new attack surface.** No new permissions, `Service` stays non-exported,
  no new IPC, no new SELinux policy. TLS 1.3 only and `cleartext=false` are kept
  (the stock `network_security_config` pins only `releases.grapheneos.org`, which
  is no longer contacted; github.com / api.github.com / the Pages host validate
  against the system CA store, so the config needs no change).
- **Package name kept** (`app.seamlessupdate.client`), so the SELinux `updater_app`
  domain and the privileged-permission allowlist (both keyed on the package name)
  are unchanged. Signer changes to the OTA key; nothing keys on the Updater's
  signature (the `OPEN_SETTINGS` permission is satisfied via `system`).

## How it is built (no AOSP tree, no hand-written smali)

The Updater is a platform app (`platform_apis` + SettingsLib static libs) and
can't be built from the public SDK. `build.sh` instead:

1. Extracts the stock `Updater.apk` + `framework.jar` from the stock OTA.
2. Runs the **integrity gates** below.
3. `dex2jar`s the framework + stock APK to form a compile classpath, so
   `javac` type-checks `src/*.java` against the app's *real* classes (a patch
   that calls something that no longer exists fails to compile).
4. `d8` → smali for our classes, then swaps them into the stock dex via
   `baksmali`/`smali` (multidex preserved), leaving all other classes and all
   resources byte-for-byte.
5. `zipalign` + `apksigner` sign with the OTA key.
6. **Verifies** the result (below).

Then the my-avbroot-setup modules inject it: `patch-modules/updater.py` replaces
`/system/priv-app/Updater/Updater.apk`; `patch-modules/updater_labels.py` adds
the label overlay to `/product/overlay`.

### Integrity gates (all fail closed — a bad input never ships)

- `check_updater_target.py`: stock APK really is `app.seamlessupdate.client`,
  contains the `Service`/`Settings` classes and the label resources.
- **Signer pin**: stock APK must match `STOCK_UPDATER_SIGNER_SHA256` in
  `UPSTREAM` once set (records-and-warns until you pin it).
- **Source-drift gate**: the upstream `Service.java`/`Settings.java` at the
  pinned tag must still hash to the baselines in `UPSTREAM`. If GrapheneOS
  changes either file, the build **fails** so a human re-reviews `src/` and bumps
  the pins — this is what stops the patch silently breaking across releases.
- **Post-build verification**: signer is the OTA key, package unchanged,
  components/permissions identical to stock, our classes present in the dex.

### Build-tool requirements (CI)

`openjdk`, Android build-tools (`d8`, `zipalign`, `apksigner`, `aapt`, `aapt2`),
`dex2jar` (`d2j-dex2jar`), `baksmali`/`smali`, plus `avbroot` and `afsr` (already
downloaded into `.tmp` by `rooted-ota.sh`). `apt-get update` before installing,
as the CI already does for the overlay tools. Override tool names with the
`DEX2JAR`, `BAKSMALI`, `SMALI`, `D8` env vars if they differ.

## Enabling it

Set in the `rooted-graphene/ota` workflow (second PR, separate from this branch):

```
PATCH_UPDATER=true
```

Builds remain fully functional with it unset.

## On-device test checklist (do this before trusting it)

1. **Signer-change survives.** Flash a build, change a setting, take the next
   OTA, confirm the Updater's settings persisted (Android keeps a system app's
   data across a signature change in an OTA — verify it actually does here).
2. **Normal update.** With a newer GrapheneOS version published upstream for the
   flavor, confirm the Updater finds, downloads, verifies and installs it, and
   that the channel label reads Rootless/Pixincreate/Magisk.
3. **Flavor switch.** On the current version, switch channel once; confirm it
   installs the other flavor (same-version), and that switching back needs
   another toggle (one-shot).
4. **Feed fallback.** Temporarily make the Pages feed unreachable; confirm the
   GitHub API path still resolves the right asset.
5. **Bad input is declined.** Point the feed at a wrong/garbage asset; confirm
   nothing installs (signature/validation decline), no crash, retry scheduled.
6. **Rate limit.** Confirm the 6-hourly check stays well under the unauthenticated
   GitHub API limit (the feed path makes no API call at all).
