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
      diskLayout = import ./disko.nix {
        device = "/dev/vda";
        imageName = hostName;
        imageSize = "8G";
      };
    in
    {
      diskoConfigurations.${hostName} = diskLayout;

      nixosConfigurations.${hostName} = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          diskLayout
          (
            { config, lib, ... }:
            {
              networking.hostName = hostName;

              documentation.enable = false;
              environment.defaultPackages = lib.mkForce [ ];
              services.udisks2.enable = false;
              services.printing.enable = false;
              services.pulseaudio.enable = false;
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
