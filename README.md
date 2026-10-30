# Fritzbox scripts

A collection of scripts for using on routers from the German company Fritz (former AVM)

- a lan toggle script for windows
- original fritzflash.py from <https://github.com/freifunk-gluon/fritz-tools/blob/master/fritzflash.py> modernized

## fritzflash.py

The script uses PEP723 header. To run it you do **NOT** need Python on your machine. Jou just need an environment manager which can understand this header. I recommend [uv](https://astral.sh/uv/). With this you just run `uv run fritzflash.py` (being in the dir) or even directly from the repo `uv run <https://path-to-the-raw-file>`.

>[!WARNING]
> Never run scripts directly from the web without trust!

Tasks are selected with verbs; a verb is always required. Running the script
without arguments prints the help and does nothing else. Run
`uv run fritzflash.py VERB --help` for verb-specific options.

```bash
uv run fritzflash.py --help                       # show available verbs
uv run fritzflash.py connect --ip 192.168.178.1   # connect and print the FTP banner
uv run fritzflash.py status  --ip 192.168.178.1   # connect and print the bootloader env
uv run fritzflash.py discover                     # find the bootloader via UDP broadcast
uv run fritzflash.py flash --image image.bin      # flash an image
uv run fritzflash.py flash --image image.bin -y   # flash without the start prompt
```

If `--ip` is omitted, all device verbs attempt autodiscovery.

## toggle_lan.ps1

Switches the wired Ethernet adapter between normal DHCP operation and the
FRITZ!Box flash mode (static `192.168.178.2/24`, no gateway, Wi-Fi disabled).
It pairs with `fritzflash.py`, which expects the box on `192.168.178.1` and
binds to `192.168.178.2`.

Requirements and safety notes:

- Windows PowerShell 5.1+ with the `NetAdapter` module and administrator
  rights (the script re-launches itself elevated).
- Adapter selection is limited to physical adapters. The LAN adapter must be
  connected (`Status -eq 'Up'`) unless `-Force` is used.
- Wi-Fi is disabled only after the static LAN address was applied successfully.
- The previous IP/DNS/route/Wi-Fi state is restored automatically if a change
  fails.
- Do not run it over RDP/SSH/WinRM on the adapter being changed; the script
  aborts in that case unless `-Force` is given.
- Only IPv4 is changed; existing IPv6 connectivity is left untouched.
- Use `-WhatIf` for a dry run; confirmation is requested before changes.
- `-Force` skips the confirmation prompt and the safety checks. Use it only
  deliberately, for example in unattended runs.

Examples:

```powershell
.\toggle_lan.ps1                     # toggle mode
.\toggle_lan.ps1 -Mode Static        # force flash mode
.\toggle_lan.ps1 -Mode Dhcp          # force normal mode
.\toggle_lan.ps1 -LanName "Ethernet 2" -WifiName "WLAN"
```
