# SPDX-License-Identifier: GPL-3.0-only
#
# my-avbroot-setup injection module for the rootless Play Integrity hook. It
# lands two kinds of change in the system image, both through the ordinary
# avbroot module mechanism (no Magisk, no modules, no init, no SELinux policy):
#
#   * replaces /system/framework/framework.jar with the hook-patched jar, and
#   * deletes the stale preopted boot image under /system/framework so the edited
#     bytecode is not shadowed by an ahead-of-time image compiled from the stock
#     jar, and
#   * drops the baked config under /system/etc/playintegrity.
#
# On the real GrapheneOS target the boot image is not the flat boot.art/oat/vdex
# the task premise assumed: it is a ~15-component, fs-verity-protected split
# image (boot.art, boot-framework.art, boot-bouncycastle.art, ..., each with
# .oat/.vdex/.fsv_meta), and framework.jar's AOT code lives in boot-framework.*,
# not boot.*. Its .fsv_meta cannot be re-signed without GrapheneOS's key, and
# the device regenerates the boot image into /data at runtime anyway, so an
# offline rebuild into /system is neither feasible nor where it is read from.
# The module therefore deletes every boot image artifact (and its .fsv_meta)
# under /system/framework; ART's odrefresh rebuilds a clean image from the
# patched boot classpath with the OTA's own dex2oat on first boot. See the
# rooted-ota.sh report for the deviation from the 4-file premise.
#
# Like the other system-image modules here, nothing is labelled by hand:
# framework.jar is overwritten in place so its stock entry (and SELinux label)
# is kept, and the new conf files are auto-labelled by the shared
# plat_file_contexts, as the other system modules here rely on.

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

# Any boot image artifact (and its fs-verity sidecar) under /system/framework:
# boot.art, boot-framework.oat, boot-core-icu4j.vdex, boot.art.fsv_meta, ...
BOOT_ARTIFACT = re.compile(r'^boot[^/]*\.(art|oat|vdex|bprof)(\.fsv_meta)?$')
CONF_FILES = ('keybox.xml', 'config.json', 'root_of_trust.json')
FRAMEWORK_DIR = PurePosixPath('/system/framework')
FRAMEWORK_JAR = FRAMEWORK_DIR / 'framework.jar'
PLAYINTEGRITY_DIR = PurePosixPath('/system/etc/playintegrity')


def _is_under(path: PurePosixPath, parent: PurePosixPath) -> bool:
    return path == parent or parent in path.parents


class IntegrityModule(Module):
    NAME: str = 'integrity'

    @classmethod
    @override
    def add_args(cls, parser: argparse.ArgumentParser):
        parser.add_argument(
            '--module-integrity-framework',
            type=Path,
            help='The hook-patched framework.jar (or a directory containing it)',
        )
        parser.add_argument(
            '--module-integrity-conf',
            type=Path,
            help='Directory holding keybox.xml, config.json and root_of_trust.json',
        )

    def __init__(self, args: argparse.Namespace) -> None:
        framework: Path | None = getattr(args, 'module_integrity_framework', None)
        conf: Path | None = getattr(args, 'module_integrity_conf', None)
        if framework is None or conf is None:
            raise MissingArgs()
        if framework.is_dir():
            framework = framework / 'framework.jar'
        self.framework: Path = framework
        self.conf: Path = conf

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
        logger.info('Injecting Play Integrity hook into the system image')
        system_fs = ext_fs['system']

        self._delete_stock_boot_image(system_fs)
        self._write_framework(system_fs)
        self._write_conf(system_fs)

    def _delete_stock_boot_image(self, system_fs: ExtFs) -> None:
        stale = [
            e for e in system_fs.info.entries
            if _is_under(e.path, FRAMEWORK_DIR) and BOOT_ARTIFACT.match(e.path.name)
        ]
        if not stale:
            raise RuntimeError(
                f'No boot image artifacts under {FRAMEWORK_DIR}: not the system '
                'layout this was built against'
            )
        removed = {e.path for e in stale}
        system_fs.info.entries[:] = [
            e for e in system_fs.info.entries if e.path not in removed
        ]
        logger.info(
            f'Deleted {len(stale)} stale boot image artifacts under {FRAMEWORK_DIR}; '
            'odrefresh rebuilds a clean image from the patched boot classpath on first boot'
        )

    def _write_framework(self, system_fs: ExtFs) -> None:
        if not self.framework.is_file():
            raise RuntimeError(f'patched framework.jar not found: {self.framework}')
        self._write_file(system_fs, self.framework, FRAMEWORK_JAR)

    def _write_conf(self, system_fs: ExtFs) -> None:
        system_fs.mkdir(PLAYINTEGRITY_DIR, mode=0o755, parents=True, exist_ok=True)
        for name in CONF_FILES:
            src = self.conf / name
            if not src.is_file():
                raise RuntimeError(f'Integrity conf is missing {name}: {self.conf}')
            self._write_file(system_fs, src, PLAYINTEGRITY_DIR / name)

    @staticmethod
    def _write_file(system_fs: ExtFs, src: Path, dest: PurePosixPath) -> None:
        system_fs.mkdir(dest.parent, mode=0o755, parents=True, exist_ok=True)
        with (
            open(src, 'rb') as f_in,
            system_fs.open(dest, 'wb', mode=0o644) as f_out,
        ):
            shutil.copyfileobj(f_in, f_out)
