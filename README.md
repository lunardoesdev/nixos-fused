# raa

Very minimal NixOS flake with Disko, a hybrid EFI/BIOS Limine bootloader layout, Btrfs root, and one normal user.

## Commands

Nix must be started with `sudo` on this machine.

Build the system:

```bash
sudo nix build .#nixosConfigurations.myhost.config.system.build.toplevel
```

Build the standard NixOS image output:

```bash
sudo nix build .#nixosConfigurations.myhost.config.system.build.images.qemu-efi
```

Build the Disko image builder script:

```bash
sudo nix build .#nixosConfigurations.myhost.config.system.build.diskoImagesScript
```

Run the Disko image builder and write the raw image in the current directory:

```bash
sudo ./result
```

Build the Disko raw image directly inside the Nix store:

```bash
sudo nix build .#nixosConfigurations.myhost.config.system.build.diskoImages
```

If you are on NixOS and want to switch to it:

```bash
sudo nixos-rebuild switch --flake .#myhost
```

Install to a real disk with `disko-install`:

```bash
sudo nix run github:nix-community/disko/latest#disko-install -- --flake .#myhost --disk main /dev/sdX
```

## Notes

- The Disko layout lives in `./disko.nix`.
- The layout is GPT with a 1 MiB BIOS partition, a 512 MiB EFI system partition mounted at `/boot`, and a Btrfs root partition.
- Limine is configured for both EFI and BIOS installs.
- The Disko image output is named `myhost.raw` and defaults to `8G`.
- The config is intentionally small: docs are disabled, default packages are empty, and audio/printing/udisks are disabled.
- A 1 MiB swapfile is declared via `swapDevices`, not via Disko.
- The default user is `nixos`.
- If `./secrets/nixos-password.hash` exists, it is used via `hashedPasswordFile`.
- Otherwise the fallback password is `changeme`.
