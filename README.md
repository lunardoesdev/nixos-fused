# Nixos-fused

Minimal NixOS flake with Disko, a desktop install built around Limine, and a separate minimal server output for VPS-style deployment.

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
sudo nix build path:.#nixosConfigurations.myhost.config.system.build.toplevel
```

Build the minimal server system:

```bash
sudo nix build path:.#nixosConfigurations.myhost-server.config.system.build.toplevel
```

Enter the native development shell with GCC, Clang, Rust, Go, Zig, Python,
SDL3, and the common build/debug tools:

```bash
nix develop path:.#native
```

Enter the Android development shell with a pinned Android SDK, NDK, CMake,
Gradle, JDK 17, and the environment variables needed for command-line builds:

```bash
nix develop path:.#android
```

Enter the `hello` package development shell derived from the package itself:

```bash
nix develop path:.#hello
```

Enter the MinGW cross-compilation shell:

```bash
nix develop path:.#mingw
```

Enter the Game Boy Advance shell with `devkitARM`:

```bash
nix develop path:.#gba
```

Build the bundled minimal offline Android example APK:

```bash
cd examples/android-minimal-gradle
gradle assembleDebug
```

Verify the APK signature:

```bash
cd examples/android-minimal-gradle
gradle verifyDebug
```

Build the installer ISO image:

```bash
sudo nix build path:.#nixosConfigurations.myhost-installer.config.system.build.isoImage
```

The `result` symlink will point directly to the generated `.iso` file.

Build the Disko image builder script:

```bash
sudo nix build path:.#nixosConfigurations.myhost.config.system.build.diskoImagesScript
```

Run the Disko image builder and write the raw image in the current directory:

```bash
sudo ./result
```

Build the Disko raw image directly inside the Nix store:

```bash
sudo nix build path:.#nixosConfigurations.myhost.config.system.build.diskoImages
```

Build the server Disko raw image directly inside the Nix store:

```bash
sudo nix build path:.#nixosConfigurations.myhost-server.config.system.build.diskoImages
```

If you are on NixOS and want to switch to this configuration immediately:

```bash
sudo nixos-rebuild switch --flake path:.#myhost
```

Switch to the minimal server configuration instead:

```bash
sudo nixos-rebuild switch --flake path:.#myhost-server
```

If you want to make it the next boot target without switching the running system:

```bash
sudo nixos-rebuild boot --flake path:.#myhost
```

Deploy the minimal server configuration to a VPS with `nixos-anywhere`:

```bash
sudo nix run github:nix-community/nixos-anywhere -- --flake path:.#myhost-server root@your-vps
```

Install to a real disk with `disko-install`:

```bash
sudo nix run github:nix-community/disko/latest#disko-install -- --flake path:.#myhost --disk main /dev/sdX
```

## Notes

- The main tunables live near the top of `flake.nix` in the `cfg` attrset: host name, disk/image settings, locale, LUKS name, swap size, and default user settings.
- Home Manager is wired in through the NixOS module, so `nixos-rebuild` builds the system and both home configurations together.
- `flake.nix` now has one shared Home Manager module plus separate root-only and user-only Home Manager modules layered on top of it.
- All systems now use X11 + LightDM + Xfce, with `picom` enabled as the session compositor.
- The flake now exposes two installed-system fragments: `myhost` for the desktop profile and `myhost-server` for the minimal server profile.
- The flake now exposes four toolchain-oriented dev shells: `native`, `mingw`, `gba`, and `android`. It also exposes `hello`, which is derived from `pkgs.hello`.
- Their toolchains are also installed into the system closure and added to `system.extraDependencies`, so they stay available offline on the installed system and the ISO.
- The Android shell exports `ANDROID_SDK_ROOT`, `ANDROID_HOME`, `ANDROID_NDK_ROOT`, `ANDROID_NDK_HOME`, `ANDROID_NDK_LATEST_HOME`, `ANDROID_BUILD_TOOLS_VERSION`, `ANDROID_PLATFORM_VERSION`, and `JAVA_HOME`.
- `examples/android-minimal-gradle` is a deliberately tiny Gradle project that builds an APK offline with the SDK command-line tools already present in the shell instead of downloading the Android Gradle Plugin.
- `myhost-server` reuses the same `secrets.toml` values for the hostname, users, passwords, target disk, and LUKS settings, but drops the desktop/audio/Bluetooth/app stack and skips Home Manager.
- `myhost-server` uses GRUB instead of Limine, enables OpenSSH, opens port 22 in the firewall, keeps DHCP on by default, and adds `qemu-guest` support for more typical VPS environments.
- `myhost-server` also enables unattended root unlock by embedding the existing `luks_password` value into the initrd as `/crypto_keyfile.bin`.
- `secrets.toml.example` is the template. Copy it to `secrets.toml` before building.
- `secrets.toml` is intentionally gitignored.
- The Disko layout is defined directly in `flake.nix`.
- The layout is GPT with a 1 MiB BIOS partition, a 512 MiB EFI system partition mounted at `/boot`, and a LUKS-encrypted Btrfs root partition.
- Limine is configured for both EFI and BIOS installs.
- The installed system writes both `BOOTX64.EFI` and `BOOTIA32.EFI` to the removable EFI boot path, so x86_64 and IA32 UEFI firmware can both find Limine.
- `path:.#nixosConfigurations.myhost-installer.config.system.build.isoImage` builds installer/live media using the same base settings from this flake, with installer-specific overrides layered on top. It is not your installed target filesystem image.
- The ISO also carries both `BOOTX64.EFI` and `BOOTIA32.EFI` in its EFI payload.
- Xfce's own `xfwm4` compositor is disabled globally through `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml`, so only `picom` is active by default.
- To disable compositing altogether, set `services.picom.enable = false;` in `flake.nix` and rebuild. `xfwm4` compositing is already forced off by default, so disabling picom leaves you with no compositor at all.
- For a one-session runtime test without rebuilding, run `systemctl --user stop picom.service` after login.
- `/boot` stays unencrypted so Limine can load the kernel and initrd, and the initrd then prompts for the LUKS passphrase to unlock `/`.
- The Disko image output is named `myhost.raw` and defaults to `10G`.
- The Disko image is a fixed-size raw disk image. If it still feels too large, reduce `imageSize` in `flake.nix`, or switch Disko's image builder to `qcow2` if you only need a VM image.
- The standard `system.build.images.qemu-efi` path is not compatible with this layout because that image module expects an `ext4` root filesystem, while this configuration uses Disko-managed `btrfs`.
- The config is still intentionally restrained: docs are disabled, printing and audio are off, locales are limited to `en_US.UTF-8`, and the desktop stack is Xfce with the LightDM GTK greeter plus `picom`.
- Nix remains enabled inside the installed image, so the system is rebuildable with `nixos-rebuild`.
- A 1 MiB swapfile is declared via `swapDevices`, not via Disko.
- The desktop profile still uses interactive LUKS passphrase entry at boot.
- The normal username comes from `secrets.toml` as `user_name` and defaults to `nixos` if you omit it.
- `secrets.toml` uses a `[secrets]` table for credentials and an `[install]` table for deploy-time disk settings.
- The normal user and `root` both use the plain-text NixOS `password` option, so there is no separate password hashing step.
- `flake.nix` reads `secrets.toml` with `builtins.fromTOML`, so there is no custom config parser left in the flake.
- The LUKS password from `secrets.toml` is converted into a temporary Nix store file and passed to Disko as `passwordFile` for formatting and image/install creation.
- The server profile uses that same `luks_password` for unattended initrd unlock, while the desktop profile still prompts interactively.
- `install.disk_device` controls the target device used by Disko and Limine's BIOS install path. You usually only change it for nixos-anywhere, disko-install, or other formatting workflows.
- Because `secrets.toml` is gitignored, use `path:.#...` for `nix build` and `path:.#myhost` or `path:.#myhost-server` for `nixos-rebuild`. That makes Nix read the local directory directly instead of the Git-indexed flake snapshot.
- Reproducibility comes from `flake.lock`. Commit it, and update inputs explicitly when you want to change versions.

Update pinned inputs:

```bash
sudo nix flake lock --update-input nixpkgs --update-input disko --update-input home-manager --update-input devkitNix
```

Review pinned versions:

```bash
sed -n '1,220p' flake.lock
```

Run the resulting raw image in QEMU with 1.5 GiB RAM:

```bash
qemu-system-x86_64 \
  -m 1536 \
  -machine q35,accel=kvm:tcg \
  -cpu max \
  -drive if=virtio,format=raw,file=./myhost.raw \
  -nic user,model=virtio-net-pci \
  -serial mon:stdio
```

## Donations

https://lunardoesdev.github.io/donate/
