# raa

Very minimal NixOS flake with Disko, a hybrid EFI/BIOS Limine bootloader layout, a LUKS-encrypted Btrfs root, and one normal user.

## Setup

Before building, copy the example secrets file and set real passwords:

```bash
cp secrets.toml.example secrets.toml
```

Edit `secrets.toml` and set:

- `user_name`
- `user_password`
- `root_password`
- `luks_password`

The file format is:

```toml
[secrets]
user_name = "..."
user_password = "..."
root_password = "..."
luks_password = "..."

[install]
disk_device = "/dev/vda"
```

You generally do not need to think about `install.disk_device` at all.
Only change it when you are formatting a disk with Disko, for example via
`nixos-anywhere`, `disko-install`, or another Disko-based install flow.
For normal day-to-day `nixos-rebuild` usage on an already installed system,
leave it alone.

## Commands

Nix must be started with `sudo` on this machine.

Build the system:

```bash
sudo nix build path:.#system
```

Build the installer ISO image:

```bash
sudo nix build path:.#iso
```

The `result` symlink will point directly to the generated `.iso` file.

Build the Disko image builder script:

```bash
sudo nix build path:.#image-script
```

Run the Disko image builder and write the raw image in the current directory:

```bash
sudo ./result
```

Build the Disko raw image directly inside the Nix store:

```bash
sudo nix build path:.#image
```

If you are on NixOS and want to switch to this configuration immediately:

```bash
sudo nixos-rebuild switch --flake path:.#myhost
```

If you want to make it the next boot target without switching the running system:

```bash
sudo nixos-rebuild boot --flake path:.#myhost
```

Install to a real disk with `disko-install`:

```bash
sudo nix run github:nix-community/disko/latest#disko-install -- --flake path:.#myhost --disk main /dev/sdX
```

## Notes

- The main tunables live near the top of `flake.nix` in the `cfg` attrset: host name, disk/image settings, locale, LUKS name, swap size, and default user settings.
- `secrets.toml.example` is the template. Copy it to `secrets.toml` before building.
- `secrets.toml` is intentionally gitignored.
- The Disko layout is defined directly in `flake.nix`.
- The layout is GPT with a 1 MiB BIOS partition, a 512 MiB EFI system partition mounted at `/boot`, and a LUKS-encrypted Btrfs root partition.
- Limine is configured for both EFI and BIOS installs.
- The installed system writes both `BOOTX64.EFI` and `BOOTIA32.EFI` to the removable EFI boot path, so x86_64 and IA32 UEFI firmware can both find Limine.
- `path:.#iso` builds installer/live media using the same base settings from this flake, with installer-specific overrides layered on top. It is not your installed target filesystem image.
- The ISO also carries both `BOOTX64.EFI` and `BOOTIA32.EFI` in its EFI payload.
- `/boot` stays unencrypted so Limine can load the kernel and initrd, and the initrd then prompts for the LUKS passphrase to unlock `/`.
- The Disko image output is named `myhost.raw` and defaults to `10G`.
- The Disko image is a fixed-size raw disk image. If it still feels too large, reduce `imageSize` in `flake.nix`, or switch Disko's image builder to `qcow2` if you only need a VM image.
- The standard `system.build.images.qemu-efi` path is not compatible with this layout because that image module expects an `ext4` root filesystem, while this configuration uses Disko-managed `btrfs`.
- The config is intentionally small: docs are disabled, audio/printing/udisks are disabled, polkit is off, and locales are limited to `en_US.UTF-8`.
- Nix remains enabled inside the installed image, so the system is rebuildable with `nixos-rebuild`.
- A 1 MiB swapfile is declared via `swapDevices`, not via Disko.
- `flake.nix` includes commented examples for initrd keyfile-based auto-unlock, but the default boot behavior is still interactive passphrase entry.
- The normal username comes from `secrets.toml` as `user_name` and defaults to `nixos` if you omit it.
- `secrets.toml` uses a `[secrets]` table for credentials and an `[install]` table for deploy-time disk settings.
- The normal user and `root` both use the plain-text NixOS `password` option, so there is no separate password hashing step.
- `flake.nix` reads `secrets.toml` with `builtins.fromTOML`, so there is no custom config parser left in the flake.
- The LUKS password from `secrets.toml` is converted into a temporary Nix store file and passed to Disko as `passwordFile` for formatting and image/install creation.
- The LUKS password in `secrets.toml` does not enable boot-time auto-unlock by itself. The initrd still prompts unless you uncomment the keyfile example in `flake.nix`.
- `install.disk_device` controls the target device used by Disko and Limine's BIOS install path. You usually only change it for nixos-anywhere, disko-install, or other formatting workflows.
- Because `secrets.toml` is gitignored, use `path:.#...` for `nix build` and `path:.#myhost` for `nixos-rebuild`. That makes Nix read the local directory directly instead of the Git-indexed flake snapshot.
- Reproducibility comes from `flake.lock`. Commit it, and update inputs explicitly when you want to change versions.

Update pinned inputs:

```bash
sudo nix flake lock --update-input nixpkgs --update-input disko
```

Review pinned versions:

```bash
sed -n '1,220p' flake.lock
```
