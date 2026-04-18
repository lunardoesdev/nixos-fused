{
  description = "Minimal NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      hostName = "myhost";
      userName = "nixos";
      userPassword = "changeme";
      passwordHashFile = ./secrets/nixos-password.hash;
    in
    {
      nixosConfigurations.${hostName} = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          (
            { config, lib, ... }:
            {
              networking.hostName = hostName;

              documentation.enable = false;
              environment.defaultPackages = lib.mkForce [ ];
              services.udisks2.enable = false;
              services.printing.enable = false;
              sound.enable = false;
              hardware.pulseaudio.enable = false;
              virtualisation.diskSize = 1024;

              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];

              boot.loader.grub.enable = false;
              boot.loader.efi.canTouchEfiVariables = false;
              boot.loader.limine.enable = true;
              boot.loader.limine.efiSupport = true;
              boot.loader.limine.efiInstallAsRemovable = true;

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
