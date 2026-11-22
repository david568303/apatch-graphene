# SPDX-License-Identifier: GPL-3.0-only
#
# my-avbroot-setup injection module for the rootless Play Integrity hook. It
# lands three kinds of change in the system image, all through the ordinary
# avbroot module mechanism (no Magisk, no modules, no init, no SELinux policy):
#
#   * replaces /system/framework/framework.jar with the hook-patched jar,
#   * replaces the stock boot image artifacts (boot.art/oat/vdex/bprof) with
#     the ones rebuilt by rooted-ota.sh (rebuildBootImage) from that jar, so the
#     AOT image matches the edited bytecode, and
#   * drops the baked config under /system/etc/playintegrity.
#
# The patched jar and the rebuilt boot image arrive together as the
# --module-integrity-framework overlay (a mirror of /system/framework holding
# framework.jar plus the boot image at its arch-relative paths); the three conf
# files arrive as --module-integrity-conf. Both are produced by rooted-ota.sh
# (buildIntegrityHook / rebuildBootImage) and verified by verifyAPatchPartitions
# after patching.
#
# Like the other system-image modules here, nothing is labelled by hand: the
# shared plat_file_contexts already know these system-as-root paths, so ExtFs
# applies the right SELinux label on write. framework.jar is overwritten in
# place (its stock entry, and thus its label, is kept); the rebuilt boot
# artifacts replace deleted stock ones, so their stock label/ownership is
# restored explicitly.

import argparse
from collections.abc import Iterable
import logging
from pathlib import Path, PurePosixPath
import shutil
from typing import override

from lib.filesystem import CpioFs, ExtEntry, ExtFs
from lib.modules import MissingArgs, Module, ModuleRequirements

logger = logging.getLogger(__name__)

BOOT_IMAGE_NAMES = frozenset({'boot.art', 'boot.oat', 'boot.vdex', 'boot.bprof'})
CONF_FILES = ('keybox.xml', 'config.json', 'root_of_trust.json')
FRAMEWORK_DIR = PurePosixPath('/system/framework')
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
            help='Rebuilt /system/framework overlay: framework.jar plus the '
                 'boot image (boot.art/oat/vdex/bprof) at its arch-relative paths',
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
        # Accept either the overlay directory or framework.jar inside it.
        if framework.is_file() and framework.name == 'framework.jar':
            framework = framework.parent
        self.framework: Path = framework
        self.conf: Path = conf
        self._stock_boot: dict[PurePosixPath, ExtEntry] = {}

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
        self._write_framework_overlay(system_fs)
        self._write_conf(system_fs)

    def _delete_stock_boot_image(self, system_fs: ExtFs) -> None:
        stock = [
            e for e in system_fs.info.entries
            if e.file_type == 'RegularFile'
            and e.path.name in BOOT_IMAGE_NAMES
            and _is_under(e.path, FRAMEWORK_DIR)
        ]
        if not stock:
            raise RuntimeError(
                f'No boot image artifacts {sorted(BOOT_IMAGE_NAMES)} under '
                f'{FRAMEWORK_DIR}: not the system layout this was built against'
            )
        # Keep the stock label/ownership so the rebuilt artifacts inherit it.
        self._stock_boot = {e.path: e for e in stock}
        removed = set(self._stock_boot)
        system_fs.info.entries[:] = [
            e for e in system_fs.info.entries if e.path not in removed
        ]
        logger.info(f'Deleted {len(stock)} stock boot image artifacts under {FRAMEWORK_DIR}')

    def _write_framework_overlay(self, system_fs: ExtFs) -> None:
        root = self.framework
        if not (root / 'framework.jar').is_file():
            raise RuntimeError(f'framework.jar not found in integrity overlay: {root}')

        wrote_boot = 0
        for src in sorted(p for p in root.rglob('*') if p.is_file()):
            rel = src.relative_to(root).as_posix()
            dest = FRAMEWORK_DIR / rel
            self._write_file(system_fs, src, dest)
            if dest.name in BOOT_IMAGE_NAMES:
                wrote_boot += 1

        if wrote_boot == 0:
            raise RuntimeError(
                f'Integrity overlay has no rebuilt boot image: {root}; '
                'rebuildBootImage must run before the module'
            )
        # Every stock boot artifact we deleted must be replaced, or the patched
        # image would be missing it (and verifyAPatchPartitions would fail).
        missing = [p for p in self._stock_boot if self._find(system_fs, p) is None]
        if missing:
            raise RuntimeError(
                'Rebuilt boot image does not cover every stock artifact; missing: '
                + ', '.join(str(p) for p in missing)
            )

    def _write_conf(self, system_fs: ExtFs) -> None:
        system_fs.mkdir(PLAYINTEGRITY_DIR, mode=0o755, parents=True, exist_ok=True)
        for name in CONF_FILES:
            src = self.conf / name
            if not src.is_file():
                raise RuntimeError(f'Integrity conf is missing {name}: {self.conf}')
            self._write_file(system_fs, src, PLAYINTEGRITY_DIR / name)

    def _write_file(self, system_fs: ExtFs, src: Path, dest: PurePosixPath) -> None:
        system_fs.mkdir(dest.parent, mode=0o755, parents=True, exist_ok=True)
        with (
            open(src, 'rb') as f_in,
            system_fs.open(dest, 'wb', mode=0o644) as f_out,
        ):
            shutil.copyfileobj(f_in, f_out)

        # A rebuilt boot artifact replaces a deleted stock one: restore the
        # stock label/ownership/mode exactly (ExtFs would relabel a fresh entry
        # from file_contexts, which is right, but the stock values are exact).
        stock = self._stock_boot.get(dest)
        if stock is not None:
            entry = self._find(system_fs, dest)
            assert entry is not None
            entry.xattrs = dict(stock.xattrs)
            entry.uid = stock.uid
            entry.gid = stock.gid
            entry.file_mode = stock.file_mode

    @staticmethod
    def _find(system_fs: ExtFs, path: PurePosixPath) -> ExtEntry | None:
        return next((e for e in system_fs.info.entries if e.path == path), None)
