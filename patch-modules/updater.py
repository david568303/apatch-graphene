# SPDX-License-Identifier: GPL-3.0-only
#
# my-avbroot-setup injection module that replaces the preinstalled GrapheneOS
# Updater with the rooted-graphene patched build (updater-patch/), so the
# on-device System Updater tracks the rooted-graphene/ota releases per flavor.
# The APK is built and signed with the OTA key by rooted-ota.sh
# (buildPatchedUpdater) and passed with --module-updater-apk.
#
# It only replaces /system/priv-app/Updater/Updater.apk in place, keeping the
# file's existing SELinux label, mode and location. The package name
# (app.seamlessupdate.client) is unchanged, so the app keeps its SELinux domain
# (updater_app, keyed by package name in seapp_contexts) and its privileged
# permission allowlist entry. No new files, permissions or policy are added.
#
# A dexpreopt odex, if GrapheneOS ships one for the Updater, becomes stale after
# this replacement. That is safe: the odex records the APK's dex checksum, so
# PackageManager treats a mismatched odex as out-of-date and runs the app from
# the APK (re-dexopting later). The build verifies the replacement separately
# (verifyPatchedUpdater in rooted-ota.sh).

import argparse
from collections.abc import Iterable
import logging
from pathlib import Path, PurePosixPath
import re
import shutil
from typing import override

from lib.filesystem import CpioFs, ExtFs
from lib.modules import MissingArgs, Module, ModuleRequirements

logger = logging.getLogger(__name__)


class UpdaterModule(Module):
    NAME: str = 'updater'
    # Path relative to the system partition root (system-as-root).
    DEST: PurePosixPath = PurePosixPath('/system/priv-app/Updater/Updater.apk')

    @classmethod
    @override
    def add_args(cls, parser: argparse.ArgumentParser):
        parser.add_argument(
            '--module-updater-apk',
            type=Path,
            help='Patched Updater APK to replace the preinstalled one',
        )

    def __init__(self, args: argparse.Namespace) -> None:
        apk: Path | None = getattr(args, 'module_updater_apk', None)
        if apk is None:
            raise MissingArgs()
        self.apk: Path = apk

    @override
    def requirements(self) -> ModuleRequirements:
        return ModuleRequirements(
            boot_images=set(),
            ext_images={'system'},
            selinux_patching=False,
        )

    @override
    def inject(
        self,
        boot_fs: dict[str, CpioFs],
        ext_fs: dict[str, ExtFs],
        sepolicies: Iterable[Path],
    ) -> None:
        logger.info(f'Replacing preinstalled Updater with: {self.apk}')

        system_fs = ext_fs['system']

        # The stock Updater APK must already be there; replacing it in place is
        # the only supported layout. Its absence means this is not the image the
        # patch was verified against, so fail instead of creating a stray file.
        try:
            existing = next(e for e in system_fs.info.entries if e.path == self.DEST)
        except StopIteration:
            raise RuntimeError(f'No preinstalled Updater at system:{self.DEST}')
        if existing.file_type != 'RegularFile':
            raise RuntimeError(f'system:{self.DEST} is not a regular file')

        # Preserve the existing file's SELinux label; the shared file_contexts
        # are keyed on system-as-root device paths, not this fs view.
        selinux_label = existing.xattrs['security.selinux']
        system_fs.contexts = [(re.compile(r'.*'), 'placeholder')]

        with (
            open(self.apk, 'rb') as f_in,
            system_fs.open(self.DEST, 'wb', mode=0o644) as f_out,
        ):
            shutil.copyfileobj(f_in, f_out)

        entry = next(e for e in system_fs.info.entries if e.path == self.DEST)
        entry.xattrs['security.selinux'] = selinux_label

        # A stale dexpreopt artifact is harmless (see module docstring); warn so
        # it is visible in the build log.
        oat_dir = self.DEST.parent / 'oat'
        if any(e.path == oat_dir or oat_dir in e.path.parents
               for e in system_fs.info.entries):
            logger.warning(
                f'Stale dexpreopt artifacts remain under system:{oat_dir}; '
                'they will be ignored at boot (APK dex checksum mismatch).')
