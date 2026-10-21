# SPDX-License-Identifier: GPL-3.0-only
#
# my-avbroot-setup injection module that preinstalls a static runtime resource
# overlay for the GrapheneOS Updater, pointing its update server at this
# repo's GitHub releases. The overlay APK is built and signed by rooted-ota.sh
# (buildUpdaterOverlay) and passed with --module-updater-overlay.
#
# It goes next to the overlays GrapheneOS already ships in /product/overlay,
# which the OS scans (and enables, being static) with no config.xml involved.
# Nothing else is written: no code, no SELinux policy, no system files.

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


class UpdaterOverlayModule(Module):
    NAME: str = 'updater-overlay'
    DEST: PurePosixPath = PurePosixPath('/overlay/UpdaterOverlay.apk')

    @classmethod
    @override
    def add_args(cls, parser: argparse.ArgumentParser):
        parser.add_argument(
            '--module-updater-overlay',
            type=Path,
            help='Overlay APK to preinstall into /product/overlay',
        )

    def __init__(self, args: argparse.Namespace) -> None:
        apk: Path | None = getattr(args, 'module_updater_overlay', None)
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
        logger.info(f'Injecting Updater overlay: {self.apk}')

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
