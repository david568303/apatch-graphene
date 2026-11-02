# SPDX-License-Identifier: GPL-3.0-only
#
# my-avbroot-setup injection module that preinstalls a static runtime resource
# overlay relabeling the Updater's channel entries (Rootless / Pixincreate /
# Magisk). The overlay APK is built and signed by rooted-ota.sh
# (buildLabelsOverlay) and passed with --module-updater-labels-overlay.
#
# It goes next to the overlays GrapheneOS already ships in /product/overlay,
# which the OS scans (and enables, being static) with no config.xml involved.
# Resource-only: no code, no permissions, no SELinux policy. The stored channel
# values (stable/beta/alpha) are untouched; only their labels change.

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


class UpdaterLabelsOverlayModule(Module):
    NAME: str = 'updater-labels-overlay'
    DEST: PurePosixPath = PurePosixPath('/overlay/UpdaterLabelsOverlay.apk')

    @classmethod
    @override
    def add_args(cls, parser: argparse.ArgumentParser):
        parser.add_argument(
            '--module-updater-labels-overlay',
            type=Path,
            help='Channel-label overlay APK to preinstall into /product/overlay',
        )

    def __init__(self, args: argparse.Namespace) -> None:
        apk: Path | None = getattr(args, 'module_updater_labels_overlay', None)
        if apk is None:
            raise MissingArgs()
        self.apk: Path = apk

    @override
    def requirements(self) -> ModuleRequirements:
        return ModuleRequirements(
            boot_images=set(),
            ext_images={'product'},
            selinux_patching=False,
        )

    @override
    def inject(
        self,
        boot_fs: dict[str, CpioFs],
        ext_fs: dict[str, ExtFs],
        sepolicies: Iterable[Path],
    ) -> None:
        logger.info(f'Injecting Updater labels overlay: {self.apk}')

        product_fs = ext_fs['product']
        overlay_dir = self.DEST.parent

        # The shared file_contexts only know paths as seen from system-as-root,
        # not this partition's own root, so the label is copied verbatim from
        # the overlays already next to the new file instead. No overlays there
        # means this is not the layout the build was verified against.
        siblings = [
            e for e in product_fs.info.entries
            if e.path.parent == overlay_dir
            and e.file_type == 'RegularFile'
            and e.path.suffix == '.apk'
        ]
        if not siblings:
            raise RuntimeError(f'No existing overlays in product:{overlay_dir}')
        product_fs.contexts = [(re.compile(r'.*'), 'placeholder')]

        with (
            open(self.apk, 'rb') as f_in,
            product_fs.open(self.DEST, 'wb', mode=0o644) as f_out,
        ):
            shutil.copyfileobj(f_in, f_out)

        entry = next(e for e in product_fs.info.entries if e.path == self.DEST)
        entry.xattrs['security.selinux'] = siblings[0].xattrs['security.selinux']
