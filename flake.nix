{
  description = "Minimal NixOS flake with Disko, Limine, and LUKS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    devkitNix.url = "github:bandithedoge/devkitNix";
    devkitNix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      disko,
      nixpkgs,
      home-manager,
      devkitNix,
      ...
    }:
    let
      lib = nixpkgs.lib;
      makeIsoImagePath = nixpkgs + "/nixos/lib/make-iso9660-image.nix";
      pkgsFor = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ devkitNix.overlays.default ];
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };
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

              sudo nix build path:.#nixosConfigurations.myhost.config.system.build.toplevel
              sudo nixos-rebuild switch --flake path:.#myhost
          '';
      cfg = rec {
        system = "x86_64-linux";
        hostName = "myhost";
        serverConfigName = "${hostName}-server";
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
      serverLuksKeyFile = "/crypto_keyfile.bin";
      diskLayout =
        {
          device ? cfg.disk.device,
          imageName ? cfg.disk.imageName,
          imageSize ? cfg.disk.imageSize,
          luksKeyFile ? null,
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
                        settings =
                          {
                            allowDiscards = cfg.luks.allowDiscards;
                          }
                          // lib.optionalAttrs (luksKeyFile != null) {
                            keyFile = luksKeyFile;
                          };
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
      serverDiskConfig = diskLayout {
        luksKeyFile = serverLuksKeyFile;
      };
      isoGrubModules = [
        "fat"
        "iso9660"
        "part_gpt"
        "part_msdos"
        "normal"
        "boot"
        "linux"
        "configfile"
        "loopback"
        "chain"
        "halt"
        "efifwsetup"
        "efi_gop"
        "ls"
        "search"
        "search_label"
        "search_fs_uuid"
        "search_fs_file"
        "echo"
        "serial"
        "gfxmenu"
        "gfxterm"
        "gfxterm_background"
        "gfxterm_menu"
        "test"
        "loadenv"
        "all_video"
        "videoinfo"
        "png"
      ];
      commonBuildTools = with pkgsFor; [
        cmake
        meson
        xmake
        autoconf
        gnumake
        ninja
        pkg-config
      ];
      androidToolchain = rec {
        cmdLineTools = "20.0";
        platformTools = "37.0.0";
        buildTools = "37.0.0";
        platform = "37";
        ndk = "29.0.14206865";
        cmake = "4.1.2";
      };
      androidComposition = pkgsFor.androidenv.composeAndroidPackages {
        cmdLineToolsVersion = androidToolchain.cmdLineTools;
        platformToolsVersion = androidToolchain.platformTools;
        buildToolsVersions = [ androidToolchain.buildTools ];
        platformVersions = [ androidToolchain.platform ];
        includeCmake = true;
        cmakeVersions = [ androidToolchain.cmake ];
        includeNDK = true;
        ndkVersions = [ androidToolchain.ndk ];
        includeEmulator = false;
        includeSources = false;
        includeSystemImages = false;
      };
      androidSdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";
      androidBuildToolsPath = "${androidSdkRoot}/build-tools/${androidToolchain.buildTools}";
      androidNdkBundleRoot = "${androidSdkRoot}/ndk-bundle";
      androidNdkRoot = "${androidSdkRoot}/ndk/${androidToolchain.ndk}";
      mingwCrossCc = pkgsFor.pkgsCross.mingwW64.stdenv.cc;
      mingwPrefix = mingwCrossCc.targetPrefix;
      armEmbeddedPrefix = "arm-none-eabi-";
      avrPrefix = "avr-";
      dosTarget = "i586-pc-msdosdjgpp";
      rpiCrossCc = pkgsFor.pkgsCross.aarch64-multiplatform.stdenv.cc;
      rpiCrossPrefix = rpiCrossCc.targetPrefix;
      mingwShellHook = ''
        export CROSS_COMPILE="${mingwPrefix}"
        export CC="${mingwCrossCc}/bin/${mingwPrefix}gcc"
        export CXX="${mingwCrossCc}/bin/${mingwPrefix}g++"
        export AR="${mingwCrossCc}/bin/${mingwPrefix}ar"
        export LD="${mingwCrossCc}/bin/${mingwPrefix}ld"
        export OBJCOPY="${mingwCrossCc}/bin/${mingwPrefix}objcopy"
        export STRIP="${mingwCrossCc}/bin/${mingwPrefix}strip"
        export WINE="${pkgsFor.wine}/bin/wine"
      '';
      armEmbeddedShellHook = ''
        export CROSS_COMPILE="${armEmbeddedPrefix}"
        export CC="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}gcc"
        export CXX="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}g++"
        export AS="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}as"
        export AR="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}ar"
        export LD="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}ld"
        export OBJCOPY="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}objcopy"
        export OBJDUMP="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}objdump"
        export SIZE="${pkgsFor."gcc-arm-embedded"}/bin/${armEmbeddedPrefix}size"
        export GDB="${pkgsFor.gdb}/bin/gdb"
        export QEMU_SYSTEM_ARM="${pkgsFor.qemu_full}/bin/qemu-system-arm"
        export OPENOCD="${pkgsFor.openocd}/bin/openocd"
      '';
      gbaShellHook = ''
        export MGBA="${pkgsFor.mgba}/bin/mgba"
      '';
      firmwareShellHook = ''
        export LLD="${pkgsFor.llvmPackages.lld}/bin/ld.lld"
        export QEMU_SYSTEM_X86_64="${pkgsFor.qemu_full}/bin/qemu-system-x86_64"
        export OVMF_CODE="${pkgsFor.OVMF.fd}/FV/OVMF_CODE.fd"
        export OVMF_VARS_TEMPLATE="${pkgsFor.OVMF.fd}/FV/OVMF_VARS.fd"
        export ESPTOOL="${pkgsFor.esptool}/bin/esptool"
        export ESPFLASH="${pkgsFor.espflash}/bin/espflash"
      '';
      stm32ShellHook = armEmbeddedShellHook + ''
        export STFLASH="${pkgsFor.stlink}/bin/st-flash"
        export STM32FLASH="${pkgsFor.stm32flash}/bin/stm32flash"
      '';
      avrShellHook = ''
        export CROSS_COMPILE="${avrPrefix}"
        export CC="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}gcc"
        export CXX="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}g++"
        export AS="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}as"
        export AR="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}ar"
        export LD="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}ld"
        export OBJCOPY="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}objcopy"
        export OBJDUMP="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}objdump"
        export SIZE="${pkgsFor.pkgsCross.avr.buildPackages.gcc}/bin/${avrPrefix}size"
        export AVRDUDE="${pkgsFor.avrdude}/bin/avrdude"
        export SIMAVR="${pkgsFor.simavr}/bin/simavr"
      '';
      rpiShellHook = ''
        export CROSS_COMPILE="${rpiCrossPrefix}"
        export CC="${rpiCrossCc}/bin/${rpiCrossPrefix}gcc"
        export CXX="${rpiCrossCc}/bin/${rpiCrossPrefix}g++"
        export AS="${rpiCrossCc}/bin/${rpiCrossPrefix}as"
        export AR="${rpiCrossCc}/bin/${rpiCrossPrefix}ar"
        export LD="${rpiCrossCc}/bin/${rpiCrossPrefix}ld"
        export OBJCOPY="${rpiCrossCc}/bin/${rpiCrossPrefix}objcopy"
        export OBJDUMP="${rpiCrossCc}/bin/${rpiCrossPrefix}objdump"
        export STRIP="${rpiCrossCc}/bin/${rpiCrossPrefix}strip"
        export QEMU_AARCH64="${pkgsFor.qemu_full}/bin/qemu-aarch64"
        export QEMU_SYSTEM_AARCH64="${pkgsFor.qemu_full}/bin/qemu-system-aarch64"
      '';
      dosShellHook = ''
        export DJDIR="${pkgsFor.djgpp}"
        export DJGPP_TARGET="${dosTarget}"
        export CROSS_COMPILE="${dosTarget}-"
        export PATH="$DJDIR/${dosTarget}/bin:$PATH"
        export CC="$DJDIR/${dosTarget}/bin/${dosTarget}-gcc"
        export CXX="$DJDIR/${dosTarget}/bin/${dosTarget}-g++"
        export AR="$DJDIR/${dosTarget}/bin/${dosTarget}-ar"
        export LD="$DJDIR/${dosTarget}/bin/${dosTarget}-ld"
        export OBJCOPY="$DJDIR/${dosTarget}/bin/${dosTarget}-objcopy"
        export OBJDUMP="$DJDIR/${dosTarget}/bin/${dosTarget}-objdump"
        export DOSBOX="${pkgsFor."dosbox-staging"}/bin/dosbox"
      '';
      nativeDevPackages = with pkgsFor; [
        gcc
        clang
        clang-tools
        gdb
        lldb
        rustc
        cargo
        go
        zig
        uv
        (python3.withPackages (ps: [ ps.tkinter ]))
        sdl3
      ] ++ commonBuildTools;
      mingwDevPackages = commonBuildTools ++ [
        pkgsFor.pkgsCross.mingwW64.stdenv.cc
      ];
      gbaDevPackages = [
        pkgsFor.devkitNix.devkitARM
      ] ++ commonBuildTools;
      androidDevPackages = with pkgsFor; [
        androidComposition.androidsdk
        gradle
        jdk17
        zip
      ] ++ commonBuildTools;
      webDevPackages = with pkgsFor; [
        bun
        deno
        go
        nodejs
      ] ++ commonBuildTools;
      embeddedDevPackages = with pkgsFor; [
        pkgsFor."gcc-arm-embedded"
        gdb
        openocd
        python3
        qemu_full
      ] ++ commonBuildTools;
      firmwareDevPackages = with pkgsFor; [
        clang
        esptool
        espflash
        gdb
        llvmPackages.lld
        mtools
        dosfstools
        nasm
        OVMF
        python3
        qemu_full
      ] ++ commonBuildTools;
      stm32DevPackages = with pkgsFor; [
        pkgsFor."gcc-arm-embedded"
        gdb
        openocd
        python3
        qemu_full
        stlink
        stm32flash
      ] ++ commonBuildTools;
      avrDevPackages = with pkgsFor; [
        avrdude
        gdb
        pkgsCross.avr.buildPackages.gcc
        pkgsCross.avr.libc
        python3
        simavr
      ] ++ commonBuildTools;
      rpiDevPackages = with pkgsFor; [
        dtc
        python3
        qemu_full
        rpiCrossCc
      ] ++ commonBuildTools;
      dosDevPackages = with pkgsFor; [
        djgpp
        pkgsFor."dosbox-staging"
      ] ++ commonBuildTools;
      z88dkDevPackages = with pkgsFor; [
        python3
        z88dk
      ] ++ commonBuildTools;
      z88dkShellHook = ''
        export Z88DK_ROOT="${pkgsFor.z88dk}"
      '';
      nesDevPackages = with pkgsFor; [
        cc65
      ] ++ commonBuildTools;
      nesShellHook = ''
        export NES_EMULATOR="${pkgsFor.fceux}/bin/fceux"
      '';
      offlineDevPackages = lib.unique (
        nativeDevPackages
        ++ mingwDevPackages
        ++ gbaDevPackages
        ++ androidDevPackages
        ++ webDevPackages
        ++ embeddedDevPackages
        ++ firmwareDevPackages
        ++ stm32DevPackages
        ++ avrDevPackages
        ++ rpiDevPackages
        ++ dosDevPackages
        ++ z88dkDevPackages
        ++ nesDevPackages
      );
      commonAppPackages = [
        pkgsFor."adwaita-icon-theme"
        pkgsFor."steam-run"
        pkgsFor.love
        pkgsFor.godot
        pkgsFor."yt-dlp"
        pkgsFor.aria2
        pkgsFor."android-tools"
        pkgsFor.unrar
        pkgsFor.ncdu
        pkgsFor.rclone
        pkgsFor.restic
        pkgsFor.blender
        pkgsFor.gimp
        pkgsFor.inkscape
        pkgsFor.krita
        pkgsFor.tiled
        pkgsFor.qbittorrent
        pkgsFor.calibre
        pkgsFor.foliate
        pkgsFor."goldendict-ng"
        pkgsFor.unison
        pkgsFor.git
        pkgsFor.bun
        pkgsFor.deno
        pkgsFor."libreoffice-fresh"
        pkgsFor.vscode
        pkgsFor.fastfetch
        pkgsFor.btop
        pkgsFor.mgba
        pkgsFor.scummvm
        pkgsFor.wine
        pkgsFor."dosbox-staging"
        pkgsFor.obsidian
        pkgsFor.scrcpy
        pkgsFor.eza
        pkgsFor."zed-editor"
        pkgsFor.keepassxc
        pkgsFor."vokoscreen-ng"
        pkgsFor.kdePackages.kdenlive
        pkgsFor.kiwix
        pkgsFor."kiwix-tools"
        pkgsFor."ffmpeg-full"
        pkgsFor.mpv
        pkgsFor.gparted
        pkgsFor.parted
        pkgsFor.nmap
        pkgsFor.qemu_full
      ];
      workstationSystemPackages = lib.unique (
        offlineDevPackages
        ++ commonAppPackages
      );
      serverSystemPackages = with pkgsFor; [
        curl
        git
        htop
      ];
      baseCommonModule =
        {
          lib,
          ...
        }:
        {
          networking.hostName = lib.mkDefault cfg.hostName;

          documentation.enable = false;
          i18n.defaultLocale = cfg.locale;
          i18n.supportedLocales = [ cfg.supportedLocale ];

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
          nixpkgs.config.allowUnfree = true;
          nixpkgs.config.android_sdk.accept_license = true;
          nixpkgs.overlays = [ devkitNix.overlays.default ];

          system.switch.enable = true;

          zramSwap.enable = true;
          zramSwap.memoryPercent = 100;

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
      mkSystemPackagesModule =
        {
          systemPackages,
          extraDependencies ? [ ],
        }:
        {
          environment.systemPackages = systemPackages;
          system.extraDependencies = systemPackages ++ extraDependencies;
        };
      workstationServicesModule =
        {
          pkgs,
          lib,
          ...
        }:
        {
          services.udisks2.enable = lib.mkDefault false;
          services.printing.enable = true;
          services.pulseaudio.enable = false;
          security.polkit.enable = lib.mkDefault false;
          security.rtkit.enable = true;

          hardware.bluetooth = {
            enable = true;
            powerOnBoot = true;
            settings = {
              General = {
                Experimental = true;
                FastConnectable = false;
              };
              Policy = {
                AutoEnable = true;
              };
            };
          };

          programs.java.enable = true;
          programs.cdemu.enable = true;
          programs.appimage.binfmt = true;
          programs.nix-ld.enable = true;
          programs.wireshark.enable = true;

          fonts.packages =
            (with pkgs; [
              noto-fonts
              noto-fonts-cjk-sans
              noto-fonts-color-emoji
              liberation_ttf
              fira-code
              fira-code-symbols
              mplus-outline-fonts.githubRelease
              dina-font
              proggyfonts
              corefonts
              adwaita-fonts
            ])
            ++ [
              pkgs.nerd-fonts.hack
              pkgs.nerd-fonts.tinos
              pkgs.nerd-fonts.iosevka
              pkgs.nerd-fonts.monofur
              pkgs.nerd-fonts."zed-mono"
              pkgs.nerd-fonts.mononoki
              pkgs.nerd-fonts.profont
              pkgs.nerd-fonts."adwaita-mono"
            ];

          services.pipewire = {
            enable = true;
            alsa.enable = true;
            alsa.support32Bit = true;
            pulse.enable = true;
          };

          networking.stevenblack.enable = true;

          services.i2pd = {
            enable = true;

            proto.http = {
              enable = true;
              port = 7070;
            };

            proto.httpProxy = {
              enable = true;
              port = 4444;
            };

            proto.socksProxy = {
              enable = true;
              port = 4447;
            };

            addressbook.subscriptions = [
              "http://reg.i2p/hosts.txt"
              "http://notbob.i2p/hosts-all.txt"
              "http://identiguy.i2p/hosts.txt"
              "http://stats.i2p/cgi-bin/newhosts.txt"
              "http://i2p-projekt.i2p/hosts.txt"
            ];

            outTunnels = {
              "IRC-ILITA" = {
                address = "127.0.0.1";
                port = 6668;
                destination = "irc.ilita.i2p";
                destinationPort = 6667;
                keys = "irc-keys.dat";
              };

              "IRC-IRC2P" = {
                address = "127.0.0.1";
                port = 6669;
                destination = "irc.postman.i2p";
                destinationPort = 6667;
                keys = "irc2-keys.dat";
              };

              SMTP = {
                address = "127.0.0.1";
                port = 7659;
                destination = "smtp.postman.i2p";
                destinationPort = 25;
                keys = "smtp-keys.dat";
              };

              POP3 = {
                address = "127.0.0.1";
                port = 7660;
                destination = "pop.postman.i2p";
                destinationPort = 110;
                keys = "pop3-keys.dat";
              };
            };
          };
        };
      workstationPackagesModule = mkSystemPackagesModule {
        systemPackages = workstationSystemPackages;
        extraDependencies = [
          nixpkgs
          disko
          home-manager
          devkitNix
        ];
      };
      serverCommonModule =
        { lib, ... }:
        {
          services.openssh = {
            enable = true;
            openFirewall = true;
            settings = {
              PasswordAuthentication = true;
              KbdInteractiveAuthentication = false;
              PermitRootLogin = "no";
            };
          };

          services.qemuGuest.enable = lib.mkDefault true;
          services.spice-vdagentd.enable = lib.mkDefault false;
          services.printing.enable = lib.mkForce false;
          services.udisks2.enable = lib.mkForce false;
          services.pulseaudio.enable = lib.mkForce false;
          security.polkit.enable = lib.mkForce false;
          networking.useDHCP = lib.mkForce false;
          networking.useNetworkd = true;
          systemd.network.enable = true;
          systemd.network.networks."10-uplink" = {
            matchConfig.Name = "e*";
            networkConfig.DHCP = "yes";
          };
        };
      serverPackagesModule = mkSystemPackagesModule {
        systemPackages = serverSystemPackages;
        extraDependencies = [
          nixpkgs
          disko
        ];
      };
      desktopCommonModule =
        { lib, ... }:
        {
          services.xserver.enable = true;
          services.displayManager.defaultSession = "xfce";
          services.xserver.displayManager.lightdm.enable = true;
          services.xserver.displayManager.lightdm.greeters.gtk.enable = true;
          services.xserver.desktopManager.xfce.enable = true;
          programs.clash-verge = {
            enable = true;
            tunMode = true;
            serviceMode = true;
          };

          services.picom = {
            enable = true;
            backend = "xrender";
            vSync = false;
            shadow = false;
            fade = false;
          };

          # Xfce ships with xfwm4's compositor. Keep it disabled globally so
          # picom is the only compositor users run by default.
          environment.etc."xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml".text = ''
            <?xml version="1.0" encoding="UTF-8"?>

            <channel name="xfwm4" version="1.0">
              <property name="general" type="empty">
                <property name="use_compositing" type="bool" value="false"/>
              </property>
            </channel>
          '';
        };
      homeManagerCommonModule =
        {
          pkgs,
          lib,
          ...
        }:
        {
          home.stateVersion = cfg.stateVersion;
          programs.home-manager.enable = true;

          home.pointerCursor = {
            name = "Bibata-Modern-Classic";
            enable = true;
            package = pkgs.bibata-cursors;
          };

          home.sessionVariables = {
            EDITOR = lib.mkDefault "${pkgs.nano}/bin/nano";
            VISUAL = lib.mkDefault "${pkgs.nano}/bin/nano";
          };
        };
      homeManagerRootModule = { ... }: { };
      homeManagerUserModule = { ... }: { };
      mkHomeManagerModule =
        {
          userName,
          homeDirectory,
          extraModules ? [ ],
        }:
        {
          imports = [ homeManagerCommonModule ] ++ extraModules;
          home.username = userName;
          home.homeDirectory = homeDirectory;
        };
      homeManagerModule =
        { ... }:
        {
          imports = [ home-manager.nixosModules.home-manager ];

          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit cfg; };

          home-manager.users.root = mkHomeManagerModule {
            userName = "root";
            homeDirectory = "/root";
            extraModules = [ homeManagerRootModule ];
          };

          home-manager.users.${cfg.user.name} = mkHomeManagerModule {
            userName = cfg.user.name;
            homeDirectory = "/home/${cfg.user.name}";
            extraModules = [ homeManagerUserModule ];
          };
        };
      installedSystemModule =
        { config, lib, pkgs, ... }:
        let
          liminePackage = pkgs.limine.override {
            targets = [
              "x86_64"
              "i686"
            ];
          };
        in
        {
          boot.loader.grub.enable = false;
          boot.loader.systemd-boot.enable = lib.mkForce false;
          boot.loader.efi.canTouchEfiVariables = false;
          boot.loader.limine = {
            enable = true;
            package = liminePackage;
            efiSupport = true;
            efiInstallAsRemovable = true;
            biosSupport = true;
            biosDevice = config.disko.devices.disk.main.device;
            partitionIndex = 1;
            # Install an IA32 fallback loader next to the normal x86_64
            # removable-path binary so 32-bit UEFI firmware can boot too.
            additionalFiles."../efi/boot/BOOTIA32.EFI" =
              "${liminePackage}/share/limine/BOOTIA32.EFI";
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
      serverInstalledSystemModule =
        { config, lib, ... }:
        {
          assertions = [
            {
              assertion = cfg.luks.password != null;
              message = ''
                ${cfg.serverConfigName} requires [secrets].luks_password in secrets.toml
                because it embeds that value into the initrd for unattended boot.
              '';
            }
          ];

          boot.loader.limine.enable = lib.mkForce false;
          boot.loader.systemd-boot.enable = lib.mkForce false;
          boot.loader.efi.canTouchEfiVariables = false;
          boot.loader.grub = {
            enable = true;
            efiSupport = true;
            efiInstallAsRemovable = true;
            devices = [ config.disko.devices.disk.main.device ];
          };

          boot.initrd.secrets.${serverLuksKeyFile} = lib.mkForce luksPasswordFile;
          boot.initrd.luks.devices.${cfg.luks.name}.keyFile = lib.mkForce serverLuksKeyFile;
        };
      isoSystemModule =
        { config, lib, pkgs, ... }:
        let
          findIsoContentSource =
            target:
            let
              matches = builtins.filter (entry: entry.target == target) config.isoImage.contents;
            in
            if matches == [ ] then
              throw "Could not find ${target} in isoImage.contents while adding BOOTIA32.EFI support."
            else
              (builtins.head matches).source;

          originalEfiDir = findIsoContentSource "/EFI";
          ia32GrubPkgs = pkgs.pkgsi686Linux;
          ia32BootEfi =
            pkgs.runCommand "bootia32-efi"
              {
                nativeBuildInputs = [ ia32GrubPkgs.grub2_efi ];
                strictDeps = true;
              }
              ''
            mkdir -p $out

            MODULES=(${lib.concatStringsSep " " (map lib.escapeShellArg isoGrubModules)})

            for mod in efi_uga; do
              if [ -f ${ia32GrubPkgs.grub2_efi}/lib/grub/${ia32GrubPkgs.grub2_efi.grubTarget}/$mod.mod ]; then
                MODULES+=("$mod")
              fi
            done

            grub-mkimage \
              --directory=${ia32GrubPkgs.grub2_efi}/lib/grub/${ia32GrubPkgs.grub2_efi.grubTarget} \
              -o $out/BOOTIA32.EFI \
              -p /EFI/BOOT \
              -O ${ia32GrubPkgs.grub2_efi.grubTarget} \
              ''${MODULES[@]}
          '';
          augmentedEfiDir = pkgs.runCommand "efi-directory-with-bootia32" { } ''
            mkdir -p $out
            cp -rp ${originalEfiDir}/. $out/
            chmod -R u+w $out
            cp ${ia32BootEfi}/BOOTIA32.EFI $out/BOOT/BOOTIA32.EFI
          '';
          augmentedEfiImg =
            pkgs.runCommand "efi-image-eltorito-with-bootia32"
              {
                nativeBuildInputs = [
                  pkgs.buildPackages.mtools
                  pkgs.buildPackages.libfaketime
                  pkgs.buildPackages.dosfstools
                ];
                strictDeps = true;
              }
              ''
                mkdir ./contents && cd ./contents
                cp -rp ${augmentedEfiDir}/. ./EFI

                find . -exec touch --date=2000-01-01 {} +

                usage_size=$(( $(du -s --block-size=1M --apparent-size . | tr -cd '[:digit:]') * 1024 * 1024 ))
                image_size=$(( ($usage_size * 110) / 100 ))
                block_size=$((1024*1024))
                image_size=$(( ($image_size / $block_size + 1) * $block_size ))
                truncate --size=$image_size "$out"
                mkfs.vfat --invariant -i 12345678 -n EFIBOOT "$out"

                for d in $(find EFI -type d | sort); do
                  faketime "2000-01-01 00:00:00" mmd -i "$out" "::/$d"
                done

                for f in $(find EFI -type f | sort); do
                  mcopy -pvm -i "$out" "$f" "::/$f"
                done

                fsck.vfat -vn "$out"
              '';
          isoContentsWithoutDefaultEfi = builtins.filter (
            entry: !(builtins.elem entry.target [ "/EFI" "/boot/efi.img" ])
          ) config.isoImage.contents;
        in
        {
          networking.hostName = lib.mkForce cfg.isoConfigName;
          isoImage.configurationName = cfg.isoConfigName;
          isoImage.appendToMenuLabel = " ${cfg.hostName} installer";
          services.getty.autologinUser = lib.mkForce null;
          services.getty.helpLine = lib.mkForce ''
            This installer ISO does not auto-login.

            Log in with the configured local account or as root using the
            passwords from secrets.toml.

            To set up a wireless connection, run `nmtui`.
          '';

          # installation-device.nix seeds empty initial password hashes for the
          # live ISO accounts. That collides with our explicit plain-text
          # passwords and triggers noisy precedence warnings during evaluation.
          users.users = lib.mkMerge [
            {
              root.initialHashedPassword = lib.mkForce null;
              root.hashedPassword = lib.mkForce null;
            }
            (lib.mkIf (cfg.user.name == "nixos") {
              nixos.initialHashedPassword = lib.mkForce null;
              nixos.hashedPassword = lib.mkForce null;
            })
          ];

          system.build.isoImage = lib.mkForce (
            pkgs.callPackage makeIsoImagePath (
              {
                inherit (config.isoImage) compressImage volumeID;
                contents = isoContentsWithoutDefaultEfi ++ [
                  {
                    source = augmentedEfiDir;
                    target = "/EFI";
                  }
                  {
                    source = augmentedEfiImg;
                    target = "/boot/efi.img";
                  }
                ];
                isoName = "${config.image.baseName}.iso";
                bootable = config.isoImage.makeBiosBootable;
                bootImage = "/isolinux/isolinux.bin";
                syslinux = if config.isoImage.makeBiosBootable then pkgs.syslinux else null;
                squashfsContents = config.isoImage.storeContents;
                squashfsCompression = config.isoImage.squashfsCompression;
              }
              // lib.optionalAttrs (config.isoImage.makeUsbBootable && config.isoImage.makeBiosBootable) {
                usbBootable = true;
                isohybridMbrImage = "${pkgs.syslinux}/share/syslinux/isohdpfx.bin";
              }
              // lib.optionalAttrs config.isoImage.makeEfiBootable {
                efiBootable = true;
                efiBootImage = "boot/efi.img";
              }
            )
          );
        };
    in
    {
      diskoConfigurations.${cfg.hostName} = diskConfig;
      diskoConfigurations.${cfg.serverConfigName} = serverDiskConfig;

      nixosConfigurations.${cfg.hostName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          disko.nixosModules.disko
          diskConfig
          baseCommonModule
          workstationServicesModule
          workstationPackagesModule
          desktopCommonModule
          homeManagerModule
          installedSystemModule
        ];
      };

      nixosConfigurations.${cfg.serverConfigName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          disko.nixosModules.disko
          serverDiskConfig
          baseCommonModule
          serverCommonModule
          serverPackagesModule
          serverInstalledSystemModule
        ];
      };

      nixosConfigurations.${cfg.isoConfigName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          (nixpkgs + "/nixos/modules/installer/cd-dvd/installation-cd-minimal-new-kernel-no-zfs.nix")
          baseCommonModule
          workstationServicesModule
          workstationPackagesModule
          desktopCommonModule
          homeManagerModule
          isoSystemModule
        ];
      };

      devShells.${cfg.system} = {
        native = pkgsFor.mkShell {
          packages = nativeDevPackages;
        };

        hello = pkgsFor.mkShell {
          inputsFrom = [ pkgsFor.hello ];
        };

        mingw = pkgsFor.mkShell {
          packages = mingwDevPackages;
          shellHook = mingwShellHook;
        };

        android = pkgsFor.mkShell {
          packages = androidDevPackages;
          shellHook = ''
            export JAVA_HOME="${pkgsFor.jdk17}"
            export ANDROID_SDK_ROOT="${androidSdkRoot}"
            export ANDROID_HOME="$ANDROID_SDK_ROOT"
            export ANDROID_NDK_ROOT="${androidNdkBundleRoot}"
            export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
            export ANDROID_NDK_LATEST_HOME="${androidNdkRoot}"
            export ANDROID_BUILD_TOOLS_VERSION="${androidToolchain.buildTools}"
            export ANDROID_PLATFORM_VERSION="${androidToolchain.platform}"
            export PATH="$JAVA_HOME/bin:${androidBuildToolsPath}:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_NDK_ROOT:$PATH"
            export PATH="$(echo "$ANDROID_SDK_ROOT/cmake/${androidToolchain.cmake}".*/bin):$PATH"
            export ORG_GRADLE_PROJECT_android_aapt2FromMavenOverride="${androidBuildToolsPath}/aapt2"
            export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ORG_GRADLE_PROJECT_android_aapt2FromMavenOverride''${GRADLE_OPTS:+ $GRADLE_OPTS}"
          '';
        };

        gba = pkgsFor.mkShell {
          packages = gbaDevPackages;
          shellHook = gbaShellHook;
        };

        web = pkgsFor.mkShell {
          packages = webDevPackages;
        };

        embedded = pkgsFor.mkShell {
          packages = embeddedDevPackages;
          shellHook = armEmbeddedShellHook;
        };

        firmware = pkgsFor.mkShell {
          packages = firmwareDevPackages;
          shellHook = firmwareShellHook;
        };

        stm32 = pkgsFor.mkShell {
          packages = stm32DevPackages;
          shellHook = stm32ShellHook;
        };

        avr = pkgsFor.mkShell {
          packages = avrDevPackages;
          shellHook = avrShellHook;
        };

        rpi = pkgsFor.mkShell {
          packages = rpiDevPackages;
          shellHook = rpiShellHook;
        };

        dos = pkgsFor.mkShell {
          packages = dosDevPackages;
          shellHook = dosShellHook;
        };

        z88dk = pkgsFor.mkShell {
          packages = z88dkDevPackages;
          shellHook = z88dkShellHook;
        };

        nes = pkgsFor.mkShell {
          packages = nesDevPackages;
          shellHook = nesShellHook;
        };
      };
    };
}
