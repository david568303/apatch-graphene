#### 2026-11-10: Pixel 10 family rebuilt (Pixel 10, 10 Pro, 10 Pro XL, 10 Pro Fold)
The first 2026110801 files for these four phones, published on 2026-11-09, did not boot: the phone showed a kernel panic three times and then returned to the previous version. Nothing was damaged and nothing needs to be done by hand. Those files were replaced on 2026-11-10 (a first replacement that day fixed the early kernel panic but still failed later in boot, on a second kernel difference in SELinux; the files now on this page include both fixes); the phone's updater will download the fixed build and install it normally.

- **Cause.** GrapheneOS 2026110800 moved these phones from the 6.6 kernel to 6.18. That kernel enforces branch protection (BTI) on KernelPatch's first hook and keeps the current-task pointer in a different CPU register (`TPIDRRO_EL0` instead of `SP_EL0`), and KernelPatch handled neither.
- **Fix.** KernelPatch is now built from [`72822ec`](https://github.com/david568303/KernelPatch/commit/72822ec500e8b9bc9e7fef7a18ed6b4db714b941): current upstream, which already includes this project's two earlier fixes and the BTI fix, plus support for the new register and for the changed SELinux `avc_denied` arguments of kernels 6.13 and later. It was boot-tested on the 6.18 kernel and on the 6.1 kernel of the other phones before release.
- **Other phones** (Pixel 6 to 9a, Pixel 10a, Fold, Tablet) were not affected and their files are unchanged.
- **Safeguard.** The build now refuses to publish an image that fails the check which flagged these four.

Phones still using the old update address (`ota-test`) keep receiving updates from it; installing this build moves them to this page's address automatically.
