# raa

Very minimal NixOS flake with a Limine UEFI bootloader and one normal user.

## Commands

Nix must be started with `sudo` on this machine.

Build the system:

```bash
sudo nix build .#nixosConfigurations.myhost.config.system.build.toplevel
```

Build the standard NixOS QEMU EFI image:

```bash
sudo nix build .#nixosConfigurations.myhost.config.system.build.images.qemu-efi
```

If you are on NixOS and want to switch to it:

```bash
sudo nixos-rebuild switch --flake .#myhost
```

## Notes

- `disko` has been removed.
- A standard NixOS image is available at `system.build.images.qemu-efi`.
- The config is intentionally small: docs are disabled, default packages are empty, and audio/printing/udisks are disabled.
- `virtualisation.diskSize = 1024`, so the standard image target is capped at 1 GiB.
- The default user is `nixos`.
- If `./secrets/nixos-password.hash` exists, it is used via `hashedPasswordFile`.
- Otherwise the fallback password is `changeme`.
