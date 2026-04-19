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

Enter any development shell:

```bash
nix develop path:.#<shell-name>
```

See the dedicated Dev Shells section below for the available shell names and
their platform-specific workflows.

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

## Dev Shells

All shells are entered with `nix develop path:.#<shell-name>`. The desktop
profile and installer ISO also carry these toolchains in their system closure
so they remain available offline after installation. The `web` shell includes
`nodejs`, which already provides `npm`.

Before using any shell, make sure the local flake can evaluate:

```bash
cp secrets.toml.example secrets.toml
```

The dev shells read the same `secrets.toml`-backed flake inputs as the system
outputs, so they will fail to evaluate if `secrets.toml` is missing.

### `native`

Use this for ordinary Linux-hosted C, C++, Rust, Go, Zig, Python, and SDL3
development.

Start it with:

```bash
nix develop path:.#native
```

Typical development and test loop:

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

For language-specific projects, the same shell also covers common loops such
as `cargo test`, `go test ./...`, `meson test -C build`, or `python -m pytest`.

### `hello`

This shell is derived from `pkgs.hello` and is mainly a minimal example of an
input-driven shell. Use it when you want to inspect how package-provided shell
metadata behaves.

Start it with:

```bash
nix develop path:.#hello
```

Quick smoke test:

```bash
hello --version
```

### `web`

Use this for web stacks that need Bun, Deno, Go, Node.js, and `npm`.

Start it with:

```bash
nix develop path:.#web
```

Typical development loops:

```bash
npm install
npm test
```

```bash
bun install
bun test
```

```bash
deno task start
deno test
```

```bash
go test ./...
```

### `mingw`

Use this to cross-build Windows executables from Linux. The shell exports
`CC`, `CXX`, `AR`, `LD`, `OBJCOPY`, `STRIP`, and `WINE`.

Start it with:

```bash
nix develop path:.#mingw
```

Build and smoke-test a Windows executable:

```bash
$CC hello.c -o hello.exe
$WINE ./hello.exe
```

### `gba`

Use this for Game Boy Advance homebrew projects built around `devkitARM`.
The shell swaps the stdenv to the `devkitNix` ARM toolchain and exports
`MGBA` for emulator-based testing.

Start it with:

```bash
nix develop path:.#gba
```

Typical loop for existing devkitARM-style projects:

```bash
make
$MGBA ./build/game.gba
```

### `android`

Use this for offline Android command-line builds with a pinned SDK, NDK,
CMake, Gradle, and JDK 17. The shell exports `ANDROID_SDK_ROOT`,
`ANDROID_HOME`, `ANDROID_NDK_ROOT`, `ANDROID_NDK_HOME`,
`ANDROID_NDK_LATEST_HOME`, `ANDROID_BUILD_TOOLS_VERSION`,
`ANDROID_PLATFORM_VERSION`, and `JAVA_HOME`.

Start it with:

```bash
nix develop path:.#android
```

The bundled sample project builds entirely offline:

```bash
cd examples/android-minimal-gradle
gradle assembleDebug
gradle verifyDebug
```

For your own projects, keep Gradle dependencies vendored or pre-fetched if you
need truly offline builds.

### `embedded`

Use this for generic ARM Cortex-M style bare-metal bring-up, OpenOCD work, and
QEMU-based smoke tests. The shell exports `CC`, `CXX`, `AS`, `AR`, `LD`,
`OBJCOPY`, `OBJDUMP`, `SIZE`, `GDB`, `OPENOCD`, and `QEMU_SYSTEM_ARM`.

Start it with:

```bash
nix develop path:.#embedded
```

Minimal semihosted QEMU loop:

```c
#include <stdio.h>

int main(void) {
  puts("hello from cortex-m");
  return 0;
}
```

```bash
$CC -mcpu=cortex-m3 -mthumb --specs=rdimon.specs hello.c -o hello.elf -lc -lrdimon
$QEMU_SYSTEM_ARM -M lm3s6965evb -nographic -semihosting-config enable=on,target=native -kernel hello.elf
```

For hardware, replace the QEMU step with your board-specific OpenOCD flash and
GDB session.

### `firmware`

Use this shell for ESP flashing, BIOS-style freestanding experiments, and UEFI
bring-up. It includes `clang`, `ld.lld`, `nasm`, `OVMF`, `mtools`,
`dosfstools`, `esptool`, `espflash`, and QEMU. The shell exports `LLD`,
`QEMU_SYSTEM_X86_64`, `OVMF_CODE`, `OVMF_VARS_TEMPLATE`, `ESPTOOL`, and
`ESPFLASH`.

Start it with:

```bash
nix develop path:.#firmware
```

Quick freestanding BIOS test with a boot sector:

```asm
bits 16
org 0x7c00

start:
  mov ah, 0x0e
  mov si, msg

.loop:
  lodsb
  test al, al
  jz .done
  int 0x10
  jmp .loop

.done:
  cli
  hlt

msg db 'hello from firmware', 0
times 510-($-$$) db 0
dw 0xaa55
```

```bash
nasm -f bin boot.asm -o boot.img
$QEMU_SYSTEM_X86_64 -m 256 -drive format=raw,file=boot.img
```

Quick UEFI test if you already have a `BOOTX64.EFI` binary:

```bash
truncate -s 64M esp.img
mkfs.vfat esp.img
mmd -i esp.img ::/EFI ::/EFI/BOOT
mcopy -i esp.img BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
cp "$OVMF_VARS_TEMPLATE" OVMF_VARS.fd
$QEMU_SYSTEM_X86_64 \
  -m 256 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive format=raw,file=esp.img
```

For ESP hardware, flash directly from the shell:

```bash
$ESPFLASH flash --monitor /dev/ttyUSB0 build/firmware.bin
```

### `stm32`

Use this shell for STM32-family Cortex-M work. It layers STM32 flashing tools
on top of the generic ARM embedded shell and exports `STFLASH` and
`STM32FLASH` in addition to the generic embedded variables.

Start it with:

```bash
nix develop path:.#stm32
```

Build and smoke-test a semihosted STM32-targeted binary in QEMU:

```bash
$CC -mcpu=cortex-m3 -mthumb --specs=rdimon.specs hello.c -o hello.elf -lc -lrdimon
$QEMU_SYSTEM_ARM -M stm32vldiscovery -nographic -semihosting-config enable=on,target=native -kernel hello.elf
```

For hardware flashing:

```bash
$STFLASH write build/firmware.bin 0x8000000
```

or:

```bash
$STM32FLASH /dev/ttyUSB0 -w build/firmware.bin
```

### `avr`

Use this shell for AVR microcontrollers such as ATmega328P. The shell exports
the usual AVR binutils plus `AVRDUDE` and `SIMAVR`.

Start it with:

```bash
nix develop path:.#avr
```

Build and simulate a simple AVR program:

```bash
$CC -mmcu=atmega328p -Os blink.c -o blink.elf
$OBJCOPY -O ihex blink.elf blink.hex
$SIMAVR -m atmega328p -f 16000000 blink.elf
```

For hardware flashing:

```bash
$AVRDUDE -p m328p -c usbasp -U flash:w:blink.hex
```

### `rpi`

Use this shell to cross-build AArch64 Linux binaries for Raspberry Pi class
targets. The shell exports a complete cross toolchain along with
`QEMU_AARCH64` and `QEMU_SYSTEM_AARCH64`.

Start it with:

```bash
nix develop path:.#rpi
```

Build and smoke-test a static userspace binary before moving it to actual Pi
hardware:

```bash
$CC -static hello.c -o hello-aarch64
$QEMU_AARCH64 ./hello-aarch64
```

For full-device testing, deploy the binary or image to a Raspberry Pi and keep
QEMU user-mode as the fast local sanity check.

### `dos`

Use this shell for DOS development with DJGPP. It exports `DJDIR`,
`DJGPP_TARGET`, the DOS cross-toolchain variables, and `DOSBOX`.

Start it with:

```bash
nix develop path:.#dos
```

Build and run a DOS executable:

```bash
$CC hello.c -o HELLO.EXE
$DOSBOX -c "mount c ." -c "c:" -c "HELLO.EXE" -c "exit"
```

### `z88dk`

Use this shell for Z80 and 8-bit homebrew projects that target the `z88dk`
toolchain. It exports `Z88DK_ROOT` and is primarily build-focused.

Start it with:

```bash
nix develop path:.#z88dk
```

Example build loop for ZX Spectrum:

```bash
zcc +zx -vn -startup=31 hello.c -o hello -create-app
```

The resulting tape, snapshot, or binary image should then be opened in your
target emulator or on real hardware. This shell focuses on the compiler and
packaging toolchain rather than bundling a single preferred emulator.

### `nes`

Use this shell for Nintendo Entertainment System homebrew with `cc65`. The
shell exports `NES_EMULATOR` for a quick FCEUX-based test loop.

Start it with:

```bash
nix develop path:.#nes
```

Build and test a ROM:

```bash
cl65 -t nes hello.c -o hello.nes
$NES_EMULATOR ./hello.nes
```

## Notes

- The main tunables live near the top of `flake.nix` in the `cfg` attrset: host name, disk/image settings, locale, LUKS name, swap size, and default user settings.
- Home Manager is wired in through the NixOS module, so `nixos-rebuild` builds the system and both home configurations together.
- `flake.nix` now has one shared Home Manager module plus separate root-only and user-only Home Manager modules layered on top of it.
- All systems now use X11 + LightDM + Xfce, with `picom` enabled as the session compositor.
- The flake now exposes two installed-system fragments: `myhost` for the desktop profile and `myhost-server` for the minimal server profile.
- The flake now exposes `native`, `hello`, `web`, `mingw`, `gba`, `android`, `embedded`, `firmware`, `stm32`, `avr`, `rpi`, `dos`, `z88dk`, and `nes` dev shells.
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
