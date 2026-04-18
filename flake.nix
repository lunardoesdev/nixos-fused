{
  description = "Minimal NixOS configuration with Disko and Limine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { disko, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      hostName = "myhost";
      userName = "nixos";
      userPassword = "changeme";
      passwordHashFile = ./secrets/nixos-password.hash;
      diskLayout =
        {
          device ? "/dev/vda",
          imageName ? hostName,
          imageSize ? "3G",
        }:
        {
          disko.devices = {
            disk.main = {
              inherit device imageName imageSize;
              type = "disk";
              content = {
                type = "gpt";
                partitions = {
                  bios = {
                    priority = 1;
                    size = "1M";
                    type = "EF02";
                  };
                  ESP = {
                    priority = 2;
                    size = "512M";
                    type = "EF00";
                    content = {
                      type = "filesystem";
                      format = "vfat";
                      mountpoint = "/boot";
                      mountOptions = [ "umask=0077" ];
                    };
                  };
                  root = {
                    size = "100%";
                    content = {
                      type = "btrfs";
                      mountpoint = "/";
                    };
                  };
                };
              };
            };
          };
        };
      diskConfig = diskLayout {
        device = "/dev/vda";
        imageName = hostName;
        imageSize = "3G";
      };
    in
    {
      diskoConfigurations.${hostName} = diskConfig;

      nixosConfigurations.${hostName} = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          diskConfig
          (
            { config, lib, ... }:
            {
              networking.hostName = hostName;

              documentation.enable = false;
              services.udisks2.enable = false;
              services.printing.enable = false;
              services.pulseaudio.enable = false;
              security.polkit.enable = lib.mkForce false;

              i18n.defaultLocale = "en_US.UTF-8";
              i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" ];

              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];

              boot.loader.grub.enable = false;
              boot.loader.systemd-boot.enable = lib.mkForce false;
              boot.loader.efi.canTouchEfiVariables = false;
              boot.loader.limine = {
                enable = true;
                efiSupport = true;
                efiInstallAsRemovable = true;
                biosSupport = true;
                biosDevice = config.disko.devices.disk.main.device;
                partitionIndex = 1;
              };
              system.switch.enable = true;

              swapDevices = [
                {
                  device = "/swapfile";
                  size = 1;
                }
              ];

              users.mutableUsers = false;
              users.users.${userName} =
                {
                  isNormalUser = true;
                  extraGroups = [ "wheel" ];
                }
                // lib.optionalAttrs (builtins.pathExists passwordHashFile) {
                  hashedPasswordFile = passwordHashFile;
                }
                // lib.optionalAttrs (!(builtins.pathExists passwordHashFile)) {
                  initialPassword = userPassword;
                };

              system.stateVersion = config.system.nixos.release;
            }
          )
        ];
      };
    };
}
