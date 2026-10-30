#! /usr/bin/env python3
# /// script
# requires-python = ">=3.15"
# dependencies = []
# ///
from __future__ import annotations

import argparse
import ipaddress
import socket
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from ftplib import FTP
from pathlib import Path
from typing import Any, BinaryIO

AUTODISCOVER_TIMEOUT = 1
FTP_TIMEOUT = 2
FTP_MAX_RETRY = 10

RetryCallback = Callable[[int, int], None]


class FritzFTP(FTP):
    """FTP client for the AVM EVA bootloader with retry and flash-timeout support."""

    class ConnectionTimeout(Exception):
        """Raised when the bootloader cannot be reached within the retry limit."""

    def __init__(
        self,
        ip: str,
        username: str = "adam2",
        password: str = "adam2",
        timeout: float = 1,
        max_retry: int = 0,
        retry_cb: RetryCallback | None = None,
    ) -> None:
        """Connect to the bootloader, retrying up to ``max_retry`` times."""
        i = 1
        while i <= max_retry:
            try:
                if retry_cb is not None:
                    retry_cb(i, max_retry)
                super().__init__(ip, user=username, passwd=password, timeout=timeout)
                break
            except TimeoutError:
                i += 1
            except OSError:
                time.sleep(1)
                i += 1
        if i > max_retry:
            raise FritzFTP.ConnectionTimeout()
        self.set_pasv(True)

    def getenv(self) -> dict[str, str]:
        """Read and parse the bootloader environment from the device."""
        env: list[bytes] = [b""]
        fritzenv: dict[str, str] = {}

        def storeenv(x: bytes) -> None:
            env[0] += x

        self.voidcmd("MEDIA SDRAM")
        try:
            self.retrbinary("RETR env", storeenv)
        except TimeoutError:
            pass

        for line in env[0].decode("ascii").splitlines():
            parts: list[str] = line.split()
            if len(parts) < 2:
                continue
            fritzenv[parts[0]] = parts[1]

        return fritzenv

    def setenv(self, key: str, value: str) -> None:
        """Set a bootloader environment variable."""
        self.voidcmd(f"SETENV {key} {value}")

    def set_flash_timeout(self) -> None:
        """Extend the socket timeout for the long-running flash operation."""
        if self.sock is not None:
            self.sock.settimeout(60 * 5)

    def upload_image(self, image: BinaryIO) -> None:
        """Write an image to the flash partition (mtd1) via EVA."""
        self.set_flash_timeout()
        self.voidcmd("MEDIA FLSH")
        self.storbinary("STOR mtd1", image)

    def reboot(self) -> None:
        """Reboot the device and close the FTP connection."""
        self.voidcmd("REBOOT")
        self.close()


class UnknownModel(Exception):
    """Raised when a device's HWRevision has no known image mapping."""


def connection_refused_message() -> None:
    print(
        "\nIt seems you have a booted-up AVM device running in your Network.\n"
        "This might be because you missed the 10 second window after powering on your AVM device.\n"
        "In this case: Powercycle your device and retry.\n"
        "If this problem persits, check if you might have connections to another AVM device, e.g. via WiFi/WLAN.\n\n"
    )


def start_message(ip_address: str) -> None:
    print(
        "This program will help you installing Gluon, a widely used Firmware for Freifunk networks, onto your AVM device.\n"
        "You can always find the most current version of this script at https://www.github.com/freifunk-darmstadt/fritz-tools\n\n"
        "It is strongly recommended to only connect your computer to the device you want to flash.\n"
        "Try to disable all other connections (Ethernet, WiFi/WLAN, VMs) if detection fails.\n\n"
        "Sometimes an unmanaged switch between your AVM device and your computer is helpfull.\n\n"
        "Before we start, make sure you have assigned your PC a static IP Address in the Subnet of the device you want to flash.\n"
        "The following example would be a completely fine option:\n"
    )
    print(f"IP-Address: {ipaddress.ip_address(ip_address) + 1}")
    print("Subnet: 255.255.255.0")
    print(f"Gateway: {ipaddress.ip_address(ip_address)}")
    print("DNS Servers: Leave blank\n")
    print(
        "Once you're ready to flash, press enter, disconnect power from your AVM device and reconnect the power-supply."
    )


def connect_message() -> None:
    print("We will now connect to your devices bootloader.")


def flash_message() -> None:
    print(
        "\nWriting Gluon image to your AVM device...\n"
        "This process may take a lot of time.\n\n"
        "First, the device will erase its current Operating System.\n"
        "Next, the device will write the Gluon image to its memory.\n"
        "The red Info LED will illuminate in this step. Don't worry, this is expected behavior.\n\n"
        "Do *not* turn off the device!\n\n"
        "We will tell you when your device has finished installing Gluon (this may take a while)."
    )


def finish_message() -> None:
    print(
        "\n== Congratulations! ==\n\n"
        "Your device is now running Gluon.\n"
        "It will restart and in 2-5 minutes you will be able to visit its config-mode.\n"
        "Remember to reconfigure your interface to automatically obtain an IP-address!\n"
        "You can reach config-mode by typing in http://192.168.1.1/ in your preferred Webbrowser.\n"
    )
    print("Press any key to exit.")
    input()


def retry_status(current_try: int, max_try: int) -> None:
    print(f"--> Try {current_try} of {max_try}")


def bind_or_exit(sock: socket.socket, address: tuple[str, int]) -> None:
    """Bind a socket, exiting with a helpful message on common errors."""
    try:
        sock.bind(address)
    except OSError as e:
        winerror: Any | None = getattr(e, "winerror", None)
        if e.errno in (99, 10049) or winerror == 10049:
            print(
                f"\rIP address {address[0]} is not configured on any interface.\n"
                "Connect your LAN adapter and assign it that static IP "
                "(see toggle_lan.ps1)."
            )
        elif e.errno in (98, 10048) or winerror == 10048:
            print(f"\rPort {address[1]} is already in use.")
        else:
            print(f"\rCould not bind {address[0]}:{address[1]}: {e}")
        sys.exit(1)


def autodiscover_avm_ip() -> str | None:
    """Find an AVM bootloader via UDP broadcast, returning its IP or ``None``."""
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    bind_or_exit(sender, ("192.168.178.2", 0))
    sender.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sender.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sender.settimeout(AUTODISCOVER_TIMEOUT)

    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.settimeout(AUTODISCOVER_TIMEOUT)
    bind_or_exit(receiver, ("192.168.178.2", 5035))

    i = 1
    while True:
        try:
            print(f"\rTry {i}...", end="")
            # Dirty hack to add conntrack entry
            receiver.sendto(b"aa", ("192.168.178.1", 5035))
            sender.sendto(
                bytearray.fromhex("0000120101000000c0a8b20100000000"),
                ("255.255.255.255", 5035),
            )
            while True:
                _, addr = receiver.recvfrom(64)
                if addr[0] == "192.168.178.1":
                    print(f"\rFritzBox found at {addr[0]}")
                    return addr[0]
        except TimeoutError:
            i += 1
        except OSError:
            i += 1
            time.sleep(0.1)
        except KeyboardInterrupt:
            print("\rAborting...\n")
            return None


def determine_image_name(env_string: str) -> list[str]:
    """Return candidate image filenames for a device's HWRevision.

    Raises ``UnknownModel`` if the revision is not in the known model list.
    """
    models: dict[str, dict[str, list[str]]] = {
        "172": {
            "gluon": ["avm-fritz-box-7320-sysupgrade.bin"],
            "openwrt": ["avm_fritz7320-squashfs-sysupgrade.bin"],
        },
        "173": {
            "gluon": ["avm-fritz-wlan-repeater-300e-sysupgrade.bin"],
            "openwrt": ["fritz300e-squashfs-sysupgrade.bin"],
        },
        "179": {
            "gluon": ["avm-fritz-box-7330-sysupgrade.bin"],
            "openwrt": ["avm_fritz7320-squashfs-sysupgrade.bin"],
        },
        "181": {
            "gluon": ["avm-fritz-box-7360-sl-sysupgrade.bin"],
            "openwrt": ["avm_fritz7360sl-squashfs-sysupgrade.bin"],
        },
        "183": {
            "gluon": ["avm-fritz-box-7360-v1-sysupgrade.bin"],
            "openwrt": ["avm_fritz7360sl-squashfs-sysupgrade.bin"],
        },
        "188": {
            "gluon": ["avm-fritz-box-7330-sl-sysupgrade.bin"],
            "openwrt": ["avm_fritz7320-squashfs-sysupgrade.bin"],
        },
        "189": {
            "gluon": ["avm-fritz-box-7312-sysupgrade.bin"],
            "openwrt": ["avm_fritz7312-squashfs-sysupgrade.bin"],
        },
        "196": {
            "gluon": ["avm-fritz-box-7360-v2-sysupgrade.bin"],
            "openwrt": ["avm_fritz7360sl-squashfs-sysupgrade.bin"],
        },
        "200": {
            "gluon": ["avm-fritz-wlan-repeater-450e-sysupgrade.bin"],
            "openwrt": ["fritz450e-squashfs-sysupgrade.bin"],
        },
        "219": {
            "gluon": ["avm-fritz-box-4020-sysupgrade.bin"],
            "openwrt": [
                "fritz4020-squashfs-sysupgrade.bin",
                "avm_fritz4020-squashfs-sysupgrade.bin",
            ],
        },
        "227": {
            "gluon": ["avm-fritz-box-4040-bootloader.bin"],
            "openwrt": ["avm_fritzbox-4040-squashfs-eva.bin"],
        },
    }
    if env_string not in models:
        raise UnknownModel(env_string)

    image_names: list[str] = []
    if "gluon" in models[env_string]:
        image_names += models[env_string]["gluon"]
    if "openwrt" in models[env_string]:
        image_names += models[env_string]["openwrt"]
    return image_names


def open_ftp(ip: str) -> FritzFTP:
    """Connect to the bootloader, exiting with a helpful message on failure."""
    try:
        return FritzFTP(
            ip, timeout=FTP_TIMEOUT, max_retry=FTP_MAX_RETRY, retry_cb=retry_status
        )
    except FritzFTP.ConnectionTimeout:
        print("-> Max retries exceeded! Check connection and try again.")
        sys.exit(1)
    except ConnectionRefusedError:
        connection_refused_message()
        sys.exit(1)


def connect_only(ftp: FritzFTP) -> None:
    """Connect to the bootloader and report the server banner."""
    _connect_message(ftp.host)
    welcome = ftp.getwelcome()
    if welcome:
        print(f"-> {welcome}")


def show_status(ftp: FritzFTP) -> None:
    """Connect to the bootloader and print its FTP environment."""
    _connect_message(ftp.host)
    env: dict[str, str] = ftp.getenv()

    if not env:
        print("-> Bootloader returned an empty environment.")
        return

    print(f"-> Bootloader environment ({len(env)} entries):")
    for key in sorted(env):
        print(f"   {key} = {env[key]}")


def setenv_value(ftp: FritzFTP, key: str, value: str) -> None:
    """Set a bootloader environment variable."""
    ftp.setenv(key, value)
    print(f"-> Set env {key} = {value}")


def autoload_image(ftp: FritzFTP) -> Path:
    """Detect the device model and return a matching image path from the CWD."""
    print("\nStarting automatic image-selection!")
    print("-> Establishing connection to device!")

    env: dict[str, str] = ftp.getenv()

    if "HWRevision" not in env:
        print("\nAutomatic image-selection unsuccessful!")
        print("-> No model saved on device!")
        sys.exit(1)

    try:
        image_names: list[str] = determine_image_name(env["HWRevision"])
    except UnknownModel:
        print("\nAutomatic image-selection unsuccessful!")
        print(f"-> Unknown Model {env['HWRevision']}!")
        print("Press any key to exit.")
        input()
        sys.exit(1)

    cwd = Path.cwd()
    files: list[Path] = []
    for filepath in cwd.iterdir():
        if not filepath.is_file():
            continue
        for image_name in image_names:
            if image_name in filepath.name:
                files.append(filepath)

    if len(files) > 1:
        print("\nAutomatic image-selection unsuccessful!")
        print("-> Multiple potential image files found!")
        for file in files:
            print(f"--> {file}")
        print("\nPlease specify the image via `--image` parameter.")
        print("Press any key to exit.")
        input()
        sys.exit(1)

    if not files:
        print("\nAutomatic image-selection unsuccessful!")
        print("--> No potential image file found!")
        print("\nPlease download and specify the image via `--image` parameter.")
        print("Press any key to exit.")
        input()
        sys.exit(1)

    print("-> Automatic image-selection successful!")
    print(f"--> Will flash {files[0]}")

    return files[0]


def perform_flash(ftp: FritzFTP, image_path: Path) -> None:
    """Flash the given image to the device and reboot it."""
    print("-> Flash image")
    flash_message()
    with open(image_path, "rb") as image:
        ftp.upload_image(image)
    print("-> Image write successful")
    print("-> Performing reboot")
    ftp.reboot()
    finish_message()



def build_parser() -> argparse.ArgumentParser:
    """Build the argument parser."""
    parser = argparse.ArgumentParser(
        description="Connect to and flash AVM devices using their EVA bootloader.",
        epilog="Run 'fritzflash.py --help' for options.",
    )
    parser.add_argument(
        "--ip",
        type=str,
        help="IP address of device. Autodiscovery if not specified.",
    )
    parser.add_argument(
        "verbs",
        nargs="+",
        help="One or more verbs to execute in order, sharing one FTP connection.",
    )
    parser.add_argument(
        "--image",
        type=str,
        help="Image file to transfer (used by 'flash').",
    )
    parser.add_argument(
        "--yes",
        "-y",
        action="store_true",
        help="Skip the initial confirmation prompt (used by 'flash').",
    )
    return parser


def resolve_ip(ip: str | None) -> str:
    """Return the given IP or autodiscover one, exiting on failure."""
    if ip is not None:
        return ip

    print("Trying to autodiscover! Abort via Ctrl-c.")
    discovered = autodiscover_avm_ip()

    if discovered is None:
        print("\nAutodiscovery failed!")
        sys.exit(1)

    print("\nAutodiscovery successful!")
    print(f"-> Device detected at {discovered}.")
    return discovered


def _connect_message(ip: str) -> None:
    """Print connection status messages."""
    print(f"-> Connecting to {ip} ...")
    print(f"-> FTP connection to {ip} established.")


# ── Verb handler registry ──────────────────────────────────────────────
# Each verb handler receives a VerbContext and executes the verb.
# New verbs are added by registering a handler here (open/closed principle).

@dataclass
class VerbContext:
    ftp: FritzFTP | None
    ip: str
    verb_args: list[str]
    image_path_arg: str | None
    yes: bool


def _dispatch_connect(ctx: VerbContext) -> None:
    if ctx.ftp is None:
        return
    connect_only(ctx.ftp)


def _dispatch_status(ctx: VerbContext) -> None:
    if ctx.ftp is None:
        return
    show_status(ctx.ftp)


def _dispatch_flash(ctx: VerbContext) -> None:
    if ctx.ftp is None:
        return
    image_path: Path | None = None
    if ctx.image_path_arg:
        image_path = Path(ctx.image_path_arg)
        if not image_path.is_file():
            print(f'Image file "{image_path.resolve()}" does not exist!')
            sys.exit(1)
    if image_path is None:
        image_path = autoload_image(ctx.ftp)
    perform_flash(ctx.ftp, image_path)


def _dispatch_setenv(ctx: VerbContext) -> None:
    if ctx.ftp is None:
        return
    if len(ctx.verb_args) < 2:
        print("setenv requires KEY and VALUE arguments.")
        sys.exit(1)
    setenv_value(ctx.ftp, ctx.verb_args[0], ctx.verb_args[1])


def _dispatch_discover(ctx: VerbContext) -> None:
    resolve_ip(None)


VERB_HANDLERS: dict[str, Callable[[VerbContext], None]] = {
    "connect": _dispatch_connect,
    "status": _dispatch_status,
    "flash": _dispatch_flash,
    "setenv": _dispatch_setenv,
    "discover": _dispatch_discover,
}


def main(argv: list[str] | None = None) -> None:
    """Parse arguments and dispatch to the requested verb(s)."""
    parser: argparse.ArgumentParser = build_parser()
    args_list: list[str] = list(sys.argv[1:] if argv is None else argv)

    if not args_list:
        parser.print_help()
        return

    args: argparse.Namespace = parser.parse_args(args_list)

    # Walk the positional verbs and their arguments.
    verbs: list[tuple[str, list[str]]] = []
    pos: list[str] = args.verbs
    i = 0
    while i < len(pos):
        verb = pos[i]
        i += 1
        if verb == "setenv":
            if i + 1 >= len(pos):
                print("setenv requires KEY and VALUE arguments.")
                sys.exit(1)
            verbs.append((verb, [pos[i], pos[i + 1]]))
            i += 2
        else:
            verbs.append((verb, []))

    # IP validation / autodiscovery.
    ip: str | None = None
    for verb, _ in verbs:
        if verb == "discover":
            ip: str | None = resolve_ip(None)  # exits on failure
            continue
        if args.ip:
            try:
                socket.inet_aton(args.ip)
            except OSError:
                print(f"{args.ip} is not a valid IPv4 address!")
                sys.exit(1)
            ip = args.ip
        else:
            ip = resolve_ip(None)  # exits on failure
        break

    # ip is guaranteed to be a non-None str after the loop
    assert ip is not None, "IP should not be None after validation loop"

    # flash confirmation prompt.
    for verb, _ in verbs:
        if verb == "flash":
            if not args.yes:
                start_message(ip_address="192.168.178.1")
                input()
            break

    ftp: FritzFTP | None = None
    try:
        for verb, verb_args in verbs:
            handler = VERB_HANDLERS.get(verb)
            if handler is None:
                print(f"Unknown verb: {verb}")
                sys.exit(1)
            if verb == "discover":
                handler(VerbContext(ftp=ftp, ip=ip or "", verb_args=verb_args, image_path_arg=args.image or "", yes=args.yes))
                continue
            if ftp is None:
                ftp = open_ftp(ip)
            handler(VerbContext(ftp=ftp, ip=ip, verb_args=verb_args, image_path_arg=args.image or "", yes=args.yes))
    finally:
        if ftp is not None:
            try:
                ftp.close()
            except OSError as e:
                print(f"-> Warning: error closing FTP connection: {e}")


if __name__ == "__main__":
    main()
