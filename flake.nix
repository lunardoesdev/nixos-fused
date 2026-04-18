{
  description = "Minimal NixOS flake with Disko, Limine, and LUKS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, disko, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      secretsFile = builtins.toString ./. + "/secrets.toml";
      rawSecrets =
        if builtins.pathExists secretsFile then
          builtins.fromTOML (builtins.readFile secretsFile)
        else
          throw ''
            Missing secrets.toml.

            This configuration requires a local secrets file before it can be evaluated.

            Create it by copying the example file in the repository root:

              cp secrets.toml.example secrets.toml

            Then edit secrets.toml and set your real values in:

              [secrets]
              user_name = "..."
              user_password = "..."
              root_password = "..."
              luks_password = "..."

              [install]
              disk_device = "/dev/..."

            After that, build or rebuild using the local path flake reference, for example:

              sudo nix build path:.#system
              sudo nixos-rebuild switch --flake path:.#myhost
          '';
      cfg = rec {
        system = "x86_64-linux";
        hostName = "myhost";
        isoConfigName = "${hostName}-installer";
        locale = "en_US.UTF-8";
        supportedLocale = "en_US.UTF-8/UTF-8";
        stateVersion = "26.05";
        swapMiB = 1;

        user = {
          name = lib.attrByPath [ "secrets" "user_name" ] "nixos" rawSecrets;
          password = lib.attrByPath [ "secrets" "user_password" ] "changeme" rawSecrets;
        };

        root = {
          password = lib.attrByPath [ "secrets" "root_password" ] "changeme-root" rawSecrets;
        };

        disk = {
          # Only matters for Disko actions such as image creation, disko-install,
          # or nixos-anywhere deployments. Normal rebuilds do not repartition.
          device = lib.attrByPath [ "install" "disk_device" ] "/dev/vda" rawSecrets;
          imageName = hostName;
          imageSize = "10G";
          efiSize = "512M";
        };

        luks = {
          name = "crypted";
          allowDiscards = true;
          password = lib.attrByPath [ "secrets" "luks_password" ] null rawSecrets;
        };
      };
      luksPasswordFile =
        if cfg.luks.password == null then null else builtins.toFile "luks-password" cfg.luks.password;
      diskLayout =
        {
          device ? cfg.disk.device,
          imageName ? cfg.disk.imageName,
          imageSize ? cfg.disk.imageSize,
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
                    size = cfg.disk.efiSize;
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
                    content =
                      {
                        type = "luks";
                        name = cfg.luks.name;
                        settings.allowDiscards = cfg.luks.allowDiscards;
                        content = {
                          type = "btrfs";
                          mountpoint = "/";
                        };
                      }
                      // lib.optionalAttrs (luksPasswordFile != null) {
                        passwordFile = luksPasswordFile;
                      };
                  };
                };
              };
            };
          };
        };
      diskConfig = diskLayout { };
      commonModule =
        { lib, ... }:
        {
          networking.hostName = lib.mkDefault cfg.hostName;

          documentation.enable = false;
          services.udisks2.enable = false;
          services.printing.enable = false;
          services.pulseaudio.enable = false;
          security.polkit.enable = lib.mkForce false;

          i18n.defaultLocale = cfg.locale;
          i18n.supportedLocales = [ cfg.supportedLocale ];

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];

          system.switch.enable = true;

          swapDevices = [
            {
              device = "/swapfile";
              size = cfg.swapMiB;
            }
          ];

          users.mutableUsers = false;
          users.users.root.password = cfg.root.password;
          users.users.${cfg.user.name} =
            {
              isNormalUser = true;
              extraGroups = [ "wheel" ];
              password = cfg.user.password;
            };

          system.stateVersion = cfg.stateVersion;
        };
      installedSystemModule =
        { config, lib, ... }:
        {
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
          # Interactive passphrase entry is the default because the Disko
          # LUKS device above does not define an initrd key file.
          #
          # For unattended unlock, embed a key into the initrd and point
          # the generated boot.initrd.luks.devices.crypted entry at it:
          #
          # boot.initrd.secrets."/crypto_keyfile.bin" = ./crypto_keyfile.bin;
          # disko.devices.disk.main.content.partitions.root.content.settings.keyFile =
          #   "/crypto_keyfile.bin";
        };
      isoSystemModule =
        { lib, ... }:
        {
          networking.hostName = lib.mkForce cfg.isoConfigName;
          isoImage.configurationName = cfg.isoConfigName;
          isoImage.appendToMenuLabel = " ${cfg.hostName} installer";
        };
    in
    {
      diskoConfigurations.${cfg.hostName} = diskConfig;

      nixosConfigurations.${cfg.hostName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          disko.nixosModules.disko
          diskConfig
          commonModule
          installedSystemModule
        ];
      };

      nixosConfigurations.${cfg.isoConfigName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          (nixpkgs + "/nixos/modules/installer/cd-dvd/installation-cd-minimal-new-kernel-no-zfs.nix")
          commonModule
          isoSystemModule
        ];
      };

      packages.${cfg.system} =
        let
          build = self.nixosConfigurations.${cfg.hostName}.config.system.build;
          isoBuild = self.nixosConfigurations.${cfg.isoConfigName}.config.system.build;
        in
        {
          default = build.toplevel;
          system = build.toplevel;
          image = build.diskoImages;
          "image-script" = build.diskoImagesScript;
          iso = isoBuild.isoImage;
        };
    };
}
