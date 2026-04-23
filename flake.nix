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
        minimalDesktopConfigName = "${hostName}-minimal";
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
          imageSize = "30G";
          efiSize = "512M";
        };
        btrfs = {
          compression = "zstd";
        };

        luks = {
          name = "crypted";
          allowDiscards = true;
          password = lib.attrByPath [ "secrets" "luks_password" ] null rawSecrets;
        };
      };
      mkDeterministicUuid =
        seed:
        let
          hash = builtins.hashString "sha256" seed;
        in
        "${builtins.substring 0 8 hash}-${builtins.substring 8 4 hash}-4${builtins.substring 13 3 hash}-a${builtins.substring 17 3 hash}-${builtins.substring 20 12 hash}";
      mkDeterministicVfatId = seed: builtins.substring 0 8 (builtins.hashString "sha256" seed);
      mkDiskIdentity =
        name: {
          biosPartUuid = mkDeterministicUuid "${name}:gpt:bios";
          espPartUuid = mkDeterministicUuid "${name}:gpt:esp";
          rootPartUuid = mkDeterministicUuid "${name}:gpt:root";
          espVolumeId = mkDeterministicVfatId "${name}:vfat:boot";
          luksUuid = mkDeterministicUuid "${name}:luks:root";
          btrfsUuid = mkDeterministicUuid "${name}:btrfs:root";
        };
      sharedDiskIdentity = mkDiskIdentity cfg.hostName;
      etcNixosSource = builtins.path {
        path = ./.;
        name = "etc-nixos-source";
        filter =
          path: type:
          let
            baseName = builtins.baseNameOf path;
          in
          !(
            builtins.elem baseName [
              ".git"
              "result"
            ]
            || lib.hasSuffix ".raw" baseName
          );
      };
      luksPasswordFile =
        if cfg.luks.password == null then null else builtins.toFile "luks-password" cfg.luks.password;
      serverLuksKeyFile = "/crypto_keyfile.bin";
      diskLayout =
        {
          device ? cfg.disk.device,
          imageName ? cfg.disk.imageName,
          imageSize ? cfg.disk.imageSize,
          identity,
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
                    uuid = identity.biosPartUuid;
                  };
                  ESP = {
                    priority = 2;
                    size = cfg.disk.efiSize;
                    type = "EF00";
                    uuid = identity.espPartUuid;
                    content = {
                      type = "filesystem";
                      format = "vfat";
                      extraArgs = [
                        "-i"
                        identity.espVolumeId
                      ];
                      mountpoint = "/boot";
                      mountOptions = [ "umask=0077" ];
                    };
                  };
                  root = {
                    size = "100%";
                    uuid = identity.rootPartUuid;
                    content =
                      {
                        type = "luks";
                        name = cfg.luks.name;
                        extraFormatArgs = [ "--uuid=${identity.luksUuid}" ];
                        settings =
                          {
                            allowDiscards = cfg.luks.allowDiscards;
                          }
                          // lib.optionalAttrs (luksKeyFile != null) {
                            keyFile = luksKeyFile;
                          };
                        content = {
                          type = "btrfs";
                          extraArgs = [
                            "--uuid"
                            identity.btrfsUuid
                          ];
                          mountpoint = "/";
                          mountOptions = [ "compress=${cfg.btrfs.compression}" ];
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
      diskConfig = diskLayout {
        identity = sharedDiskIdentity;
      };
      minimalDiskConfig = diskLayout {
        imageName = cfg.minimalDesktopConfigName;
        identity = sharedDiskIdentity;
      };
      serverDiskConfig = diskLayout {
        imageName = cfg.serverConfigName;
        identity = sharedDiskIdentity;
        luksKeyFile = serverLuksKeyFile;
        imageSize = "5G";
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
      avrCrossCc = pkgsFor.pkgsCross.avr.stdenv.cc;
      avrPrefix = avrCrossCc.targetPrefix;
      rpiCrossCc = pkgsFor.pkgsCross.aarch64-multiplatform.stdenv.cc;
      rpiCrossPrefix = rpiCrossCc.targetPrefix;
      dosCrossCc = pkgsFor.djgpp;
      dosTriplet = "i586-pc-msdosdjgpp";
      dosPrefix = "${dosTriplet}-";
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
        export CC="${avrCrossCc}/bin/${avrPrefix}gcc"
        export CXX="${avrCrossCc}/bin/${avrPrefix}g++"
        export AS="${avrCrossCc}/bin/${avrPrefix}as"
        export AR="${avrCrossCc}/bin/${avrPrefix}ar"
        export LD="${avrCrossCc}/bin/${avrPrefix}ld"
        export OBJCOPY="${avrCrossCc}/bin/${avrPrefix}objcopy"
        export OBJDUMP="${avrCrossCc}/bin/${avrPrefix}objdump"
        export SIZE="${avrCrossCc}/bin/${avrPrefix}size"
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
        export DJDIR="${dosCrossCc}"
        export CROSS_COMPILE="${dosPrefix}"
        export CC="${dosCrossCc}/${dosTriplet}/bin/${dosPrefix}gcc"
        export CXX="${dosCrossCc}/${dosTriplet}/bin/${dosPrefix}g++"
        export AR="${dosCrossCc}/${dosTriplet}/bin/${dosPrefix}ar"
        export LD="${dosCrossCc}/${dosTriplet}/bin/${dosPrefix}ld"
        export OBJCOPY="${dosCrossCc}/${dosTriplet}/bin/${dosPrefix}objcopy"
        export OBJDUMP="${dosCrossCc}/${dosTriplet}/bin/${dosPrefix}objdump"
        export STRIP="${dosCrossCc}/${dosTriplet}/bin/${dosPrefix}strip"
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
        fltk
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
        avrCrossCc
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
      z80DevPackages = with pkgsFor; [
        python3
        sdcc
        sjasmplus
      ] ++ commonBuildTools;
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
        pkgsFor.meld
        pkgsFor.audacity
        pkgsFor.strawberry
        pkgsFor.gzdoom
        #pkgsFor.xonotic
        pkgsFor.hedgewars
        pkgsFor.brave
        pkgsFor.mgba
        pkgsFor.mesen
        pkgsFor."nestopia-ue"
        pkgsFor.scummvm
        pkgsFor.slade
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
        #pkgsFor.veracrypt
        pkgsFor.usbutils
        pkgsFor.pciutils
        pkgsFor.nmap
        pkgsFor.qemu_full
      ];
      workstationSystemPackages = lib.unique (
        offlineDevPackages
        ++ commonAppPackages
      );
      minimalDesktopSystemPackages = with pkgsFor; [
        brave
        curl
        git
        htop
        nano
        pciutils
        usbutils
        uv
      ];
      serverSystemPackages = with pkgsFor; [
        curl
        git
        htop
      ];
      baseCommonModule =
        {
          config,
          lib,
          ...
        }:
        {
          # This flake does not import a machine-specific hardware-configuration
          # file, so stage-1 needs an explicit baseline set of storage and input
          # drivers to make the encrypted-root prompt usable on common bare-metal
          # and VM targets.
          boot.initrd.availableKernelModules = [
            "ahci"
            "atkbd"
            "hid_generic"
            "nvme"
            "sd_mod"
            "sr_mod"
            "uas"
            "usbhid"
            "usb_storage"
            "virtio_blk"
            "virtio_input"
            "virtio_pci"
            "virtio_scsi"
            "xhci_pci"
          ];

          # Keep the baseline broadly portable across Intel and AMD machines
          # without pulling in any NVIDIA-specific configuration.
          hardware.enableRedistributableFirmware = true;
          hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
          hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

          networking.hostName = lib.mkDefault cfg.hostName;

          documentation.enable = false;
          i18n.defaultLocale = cfg.locale;
          i18n.supportedLocales = [ cfg.supportedLocale ];

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
          nix.settings.flake-registry = "";
          nix.channel.enable = false;
          nixpkgs.flake.setFlakeRegistry = true;
          nixpkgs.flake.setNixPath = true;
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
      embeddedEtcNixosModule =
        { ... }:
        {
          environment.etc."nixos".source = etcNixosSource;
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
          security.polkit.enable = true;
          security.rtkit.enable = true;
          networking.networkmanager.enable = true;
          programs.nm-applet.enable = true;
          services.blueman.enable = true;

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

          fonts.fontconfig.defaultFonts = {
            sansSerif = [ "Adwaita Sans" ];
            serif = [ "Adwaita Sans" ];
            monospace = [ "Adwaita Mono" ];
            emoji = [ "Noto Color Emoji" ];
          };

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
      minimalDesktopServicesModule =
        { pkgs, lib, ... }:
        {
          services.printing.enable = lib.mkForce false;
          services.pulseaudio.enable = lib.mkForce false;
          services.pipewire = {
            enable = true;
            alsa.enable = true;
            pulse.enable = true;
          };
          security.polkit.enable = true;
          security.rtkit.enable = true;
          networking.networkmanager.enable = true;
          programs.nm-applet.enable = true;
          programs.clash-verge = {
            enable = true;
            tunMode = true;
            serviceMode = true;
          };
          services.blueman.enable = true;

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

          fonts.packages = with pkgs; [
            adwaita-fonts
            noto-fonts
            noto-fonts-color-emoji
          ];

          fonts.fontconfig.defaultFonts = {
            sansSerif = [ "Adwaita Sans" ];
            serif = [ "Adwaita Sans" ];
            monospace = [ "Adwaita Mono" ];
            emoji = [ "Noto Color Emoji" ];
          };
        };
      minimalDesktopPackagesModule = mkSystemPackagesModule {
        systemPackages = minimalDesktopSystemPackages;
        extraDependencies = [
          nixpkgs
          disko
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
        { pkgs, ... }:
        {
          hardware.graphics.enable = true;

          services.xserver.enable = true;
          services.displayManager.defaultSession = "xfce";
          services.xserver.displayManager.lightdm.enable = true;
          services.xserver.displayManager.lightdm.greeters.gtk.enable = true;
          services.xserver.desktopManager.xfce.enable = true;

          environment.systemPackages = with pkgs; [
            xfce4-whiskermenu-plugin
            xfce4-xkb-plugin
          ];

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
      desktopFullModule =
        { lib, ... }:
        {
          hardware.graphics.enable32Bit = true;
          programs.throne = {
            enable = true;
            tunMode.enable = true;
          };
          programs.clash-verge = {
            enable = true;
            tunMode = true;
            serviceMode = true;
          };
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
            enable = true;
            name = "Bibata-Modern-Classic";
            package = pkgs.bibata-cursors;
            size = 24;

            gtk.enable = true;
            x11.enable = true;
          };

          home.sessionVariables = {
            EDITOR = lib.mkDefault "${pkgs.nano}/bin/nano";
            VISUAL = lib.mkDefault "${pkgs.nano}/bin/nano";
          };
        };
      homeManagerRootModule = { ... }: { };
      homeManagerUserModule =
        {
          pkgs,
          lib,
          ...
        }:
        let
          xfceXsettingsSeed = pkgs.writeText "xfce-xsettings.xml" ''
            <?xml version="1.0" encoding="UTF-8"?>

            <channel name="xsettings" version="1.0">
              <property name="Net" type="empty">
                <property name="ThemeName" type="string" value="adw-gtk3"/>
                <property name="IconThemeName" type="string" value="Adwaita"/>
              </property>
              <property name="Gtk" type="empty">
                <property name="CursorThemeName" type="string" value="Bibata-Modern-Classic"/>
                <property name="CursorThemeSize" type="int" value="24"/>
                <property name="FontName" type="string" value="Adwaita Sans 11"/>
                <property name="MonospaceFontName" type="string" value="Adwaita Mono 11"/>
              </property>
              <property name="Xft" type="empty">
                <property name="Antialias" type="int" value="1"/>
                <property name="Hinting" type="int" value="1"/>
                <property name="HintStyle" type="string" value="hintslight"/>
                <property name="RGBA" type="string" value="rgb"/>
              </property>
            </channel>
          '';
          xfceKeyboardShortcutsSeed = pkgs.writeText "xfce4-keyboard-shortcuts.xml" ''
            <?xml version="1.0" encoding="UTF-8"?>

            <channel name="xfce4-keyboard-shortcuts" version="1.0">
              <property name="commands" type="empty">
                <property name="custom" type="empty">
                  <property name="override" type="bool" value="true"/>
                  <property name="&lt;Primary&gt;&lt;Alt&gt;t" type="string" value="${pkgs.xfce4-terminal}/bin/xfce4-terminal"/>
                  <property name="Super_L" type="string" value="${pkgs.xfce4-whiskermenu-plugin}/bin/xfce4-popup-whiskermenu"/>
                  <property name="&lt;Super&gt;e" type="string" value="${pkgs.thunar}/bin/thunar"/>
                  <property name="&lt;Super&gt;r" type="string" value="${pkgs.xfce4-appfinder}/bin/xfce4-appfinder -c"/>
                  <property name="&lt;Super&gt;l" type="string" value="${pkgs.xfce4-session}/bin/xflock4"/>
                  <property name="Print" type="string" value="${pkgs.xfce4-screenshooter}/bin/xfce4-screenshooter"/>
                </property>
              </property>
              <property name="xfwm4" type="empty">
                <property name="custom" type="empty">
                  <property name="&lt;Super&gt;d" type="string" value="show_desktop_key"/>
                  <property name="&lt;Super&gt;Left" type="string" value="tile_left_key"/>
                  <property name="&lt;Super&gt;Right" type="string" value="tile_right_key"/>
                  <property name="&lt;Super&gt;Up" type="string" value="tile_up_key"/>
                  <property name="&lt;Super&gt;Down" type="string" value="tile_down_key"/>
                </property>
              </property>
            </channel>
          '';
          xfceXfwm4Seed = pkgs.writeText "xfwm4.xml" ''
            <?xml version="1.0" encoding="UTF-8"?>

            <channel name="xfwm4" version="1.0">
              <property name="general" type="empty">
                <property name="use_compositing" type="bool" value="false"/>
              </property>
            </channel>
          '';
          xfceThunarSeed = pkgs.writeText "thunar.xml" ''
            <?xml version="1.0" encoding="UTF-8"?>

            <channel name="thunar" version="1.0">
              <property name="last-view" type="string" value="ThunarDetailsView"/>
              <property name="last-side-pane" type="string" value="ThunarShortcutsPane"/>
              <property name="misc-single-click" type="bool" value="false"/>
              <property name="misc-folders-first" type="bool" value="true"/>
              <property name="misc-middle-click-in-tab" type="bool" value="true"/>
              <property name="misc-open-new-window-as-tab" type="bool" value="true"/>
              <property name="misc-remember-geometry" type="bool" value="true"/>
              <property name="misc-full-path-in-tab-title" type="bool" value="true"/>
              <property name="misc-window-title-style" type="string" value="full-path-without-suffix"/>
            </channel>
          '';
          xfcePanelSeed = pkgs.writeText "xfce4-panel.xml" ''
            <?xml version="1.0" encoding="UTF-8"?>

            <channel name="xfce4-panel" version="1.0">
              <property name="configver" type="int" value="2"/>
              <property name="panels" type="array">
                <value type="int" value="1"/>
                <property name="dark-mode" type="bool" value="false"/>
                <property name="panel-1" type="empty">
                  <property name="position" type="string" value="p=10;x=0;y=0"/>
                  <property name="length" type="uint" value="100"/>
                  <property name="position-locked" type="bool" value="true"/>
                  <property name="icon-size" type="uint" value="20"/>
                  <property name="size" type="uint" value="36"/>
                  <property name="plugin-ids" type="array">
                    <value type="int" value="1"/>
                    <value type="int" value="2"/>
                    <value type="int" value="3"/>
                    <value type="int" value="4"/>
                    <value type="int" value="5"/>
                    <value type="int" value="6"/>
                    <value type="int" value="7"/>
                    <value type="int" value="8"/>
                  </property>
                </property>
              </property>
              <property name="plugins" type="empty">
                <property name="plugin-1" type="string" value="whiskermenu"/>
                <property name="plugin-2" type="string" value="tasklist">
                  <property name="grouping" type="uint" value="0"/>
                </property>
                <property name="plugin-3" type="string" value="separator">
                  <property name="expand" type="bool" value="true"/>
                  <property name="style" type="uint" value="0"/>
                </property>
                <property name="plugin-4" type="string" value="pulseaudio"/>
                <property name="plugin-5" type="string" value="systray">
                  <property name="square-icons" type="bool" value="true"/>
                </property>
                <property name="plugin-6" type="string" value="xkb"/>
                <property name="plugin-7" type="string" value="clock"/>
                <property name="plugin-8" type="string" value="actions"/>
              </property>
            </channel>
          '';
          xfceKeyboardLayoutSeed = pkgs.writeText "keyboard-layout.xml" ''
            <?xml version="1.0" encoding="UTF-8"?>

            <channel name="keyboard-layout" version="1.0">
              <property name="Default" type="empty">
                <property name="XkbDisable" type="bool" value="false"/>
                <property name="XkbLayout" type="string" value="us"/>
                <property name="XkbVariant" type="string" value=""/>
                <property name="XkbOptions" type="empty">
                  <property name="Group" type="string" value="grp:alt_shift_toggle"/>
                </property>
              </property>
            </channel>
          '';
        in
        {
          gtk = {
            enable = true;

            font = {
              name = "Adwaita Sans";
              size = 11;
            };

            theme = {
              name = "adw-gtk3";
              package = pkgs.adw-gtk3;
            };

            iconTheme = {
              name = "Adwaita";
              package = pkgs.adwaita-icon-theme;
            };

            cursorTheme = {
              name = "Bibata-Modern-Classic";
              package = pkgs.bibata-cursors;
              size = 24;
            };
          };

          qt = {
            enable = true;
            platformTheme.name = "gtk3";
            style.name = "adwaita";
          };

          home.activation.seedMutableXfceConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            seed_mutable_xfce_file() {
              src="$1"
              dst="$2"

              mkdir -p "$(dirname "$dst")"

              if [ -L "$dst" ]; then
                rm -f "$dst"
              fi

              if [ ! -e "$dst" ]; then
                cp "$src" "$dst"
                chmod u+w "$dst"
              fi
            }

            xfce_config_dir="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"

            seed_mutable_xfce_file "${xfceXsettingsSeed}" "$xfce_config_dir/xsettings.xml"
            seed_mutable_xfce_file "${xfceKeyboardShortcutsSeed}" "$xfce_config_dir/xfce4-keyboard-shortcuts.xml"
            seed_mutable_xfce_file "${xfceXfwm4Seed}" "$xfce_config_dir/xfwm4.xml"
            seed_mutable_xfce_file "${xfceThunarSeed}" "$xfce_config_dir/thunar.xml"
            seed_mutable_xfce_file "${xfcePanelSeed}" "$xfce_config_dir/xfce4-panel.xml"
            seed_mutable_xfce_file "${xfceKeyboardLayoutSeed}" "$xfce_config_dir/keyboard-layout.xml"
          '';
        };
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
      autoGrowRootModule =
        { pkgs, lib, ... }:
        let
          stampPath = "/var/lib/root-auto-grow.done";
          growThresholdBytes = 4 * 1024 * 1024;
        in
        {
          systemd.services.root-auto-grow = {
            description = "Grow root partition, LUKS mapping, and Btrfs filesystem";
            wantedBy = [ "multi-user.target" ];
            after = [
              "local-fs.target"
              "systemd-udev-settle.service"
            ];
            wants = [ "systemd-udev-settle.service" ];
            unitConfig.ConditionPathExists = "!${stampPath}";
            path = with pkgs; [
              bash
              btrfs-progs
              coreutils
              cryptsetup
              gawk
              parted
              systemd
              util-linux
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            restartIfChanged = false;
            script = ''
              set -euo pipefail

              stamp_path=${lib.escapeShellArg stampPath}
              expected_root_source=/dev/mapper/${cfg.luks.name}
              root_part_by_partuuid=/dev/disk/by-partuuid/${sharedDiskIdentity.rootPartUuid}
              configured_luks_password=${if cfg.luks.password == null then "''" else lib.escapeShellArg cfg.luks.password}
              root_source=$(findmnt -n -o SOURCE /)

              if [ "$root_source" != "$expected_root_source" ]; then
                echo "root-auto-grow: unexpected root source $root_source, expected $expected_root_source" >&2
                exit 1
              fi

              if [ ! -e "$root_part_by_partuuid" ]; then
                echo "root-auto-grow: expected root partition symlink $root_part_by_partuuid does not exist" >&2
                exit 1
              fi

              root_part=$(readlink -f "$root_part_by_partuuid")
              if [ -z "$root_part" ] || [ ! -b "$root_part" ]; then
                echo "root-auto-grow: could not resolve encrypted root partition from $root_part_by_partuuid" >&2
                exit 1
              fi

              disk_kname=$(lsblk -n -o PKNAME "$root_part" | head -n1)
              if [ -z "$disk_kname" ]; then
                echo "root-auto-grow: could not determine parent disk for $root_part" >&2
                exit 1
              fi
              disk="/dev/$disk_kname"

              partnum=$(lsblk -n -o PARTN "$root_part" | head -n1)
              if [ -z "$partnum" ]; then
                echo "root-auto-grow: could not determine partition number for $root_part" >&2
                exit 1
              fi

              parted_output=$(parted -ms "$disk" unit B print)
              disk_bytes=$(printf '%s\n' "$parted_output" | awk -F: 'NR == 2 { sub(/B$/, "", $2); print $2 }')
              part_end_bytes=$(printf '%s\n' "$parted_output" | awk -F: -v part="$partnum" '$1 == part { sub(/B$/, "", $3); print $3 }')

              if [ -z "$disk_bytes" ] || [ -z "$part_end_bytes" ]; then
                echo "root-auto-grow: could not parse partition geometry for $disk partition $partnum" >&2
                exit 1
              fi

              if [ $((disk_bytes - part_end_bytes)) -le ${toString growThresholdBytes} ]; then
                mkdir -p "$(dirname "$stamp_path")"
                touch "$stamp_path"
                echo "root-auto-grow: no additional disk space detected"
                exit 0
              fi

              old_part_bytes=$(blockdev --getsize64 "$root_part")

              parted "$disk" --fix --script "resizepart $partnum 100%"

              for _ in $(seq 1 10); do
                blockdev --rereadpt "$disk" || true
                partprobe "$disk" || true
                ${pkgs.systemd}/bin/udevadm settle || true

                new_part_bytes=$(blockdev --getsize64 "$root_part")
                if [ "$new_part_bytes" -gt "$old_part_bytes" ]; then
                  break
                fi

                sleep 1
              done

              new_part_bytes=$(blockdev --getsize64 "$root_part")
              if [ "$new_part_bytes" -le "$old_part_bytes" ]; then
                echo "root-auto-grow: partition resize did not become visible to the running kernel" >&2
                exit 1
              fi

              if [ -n "$configured_luks_password" ]; then
                echo "root-auto-grow: using configured LUKS password for cryptsetup resize" >&2
                printf '%s' "$configured_luks_password" | cryptsetup resize --batch-mode --key-file - ${cfg.luks.name}
                unset configured_luks_password
              else
                echo "root-auto-grow: cryptsetup resize needs the LUKS passphrase; requesting it interactively" >&2
                luks_passphrase=$(${pkgs.systemd}/bin/systemd-ask-password --timeout=0 \
                  "root-auto-grow: enter LUKS passphrase for /dev/mapper/${cfg.luks.name}")
                if [ -z "$luks_passphrase" ]; then
                  echo "root-auto-grow: empty passphrase returned by systemd-ask-password" >&2
                  exit 1
                fi

                printf '%s' "$luks_passphrase" | cryptsetup resize --batch-mode --key-file - ${cfg.luks.name}
                unset luks_passphrase
              fi

              btrfs filesystem resize max /

              mkdir -p "$(dirname "$stamp_path")"
              touch "$stamp_path"
              echo "root-auto-grow: resized $root_part, /dev/mapper/${cfg.luks.name}, and /"
            '';
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
        { ... }:
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
      diskoConfigurations.${cfg.minimalDesktopConfigName} = minimalDiskConfig;
      diskoConfigurations.${cfg.serverConfigName} = serverDiskConfig;

      nixosConfigurations.${cfg.hostName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          disko.nixosModules.disko
          diskConfig
          baseCommonModule
          embeddedEtcNixosModule
          workstationServicesModule
          workstationPackagesModule
          desktopCommonModule
          desktopFullModule
          homeManagerModule
          autoGrowRootModule
          installedSystemModule
        ];
      };

      nixosConfigurations.${cfg.minimalDesktopConfigName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          disko.nixosModules.disko
          minimalDiskConfig
          baseCommonModule
          embeddedEtcNixosModule
          minimalDesktopServicesModule
          minimalDesktopPackagesModule
          desktopCommonModule
          homeManagerModule
          autoGrowRootModule
          installedSystemModule
        ];
      };

      nixosConfigurations.${cfg.serverConfigName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          disko.nixosModules.disko
          serverDiskConfig
          baseCommonModule
          embeddedEtcNixosModule
          serverCommonModule
          serverPackagesModule
          autoGrowRootModule
          serverInstalledSystemModule
        ];
      };

      nixosConfigurations.${cfg.isoConfigName} = nixpkgs.lib.nixosSystem {
        inherit (cfg) system;
        modules = [
          (nixpkgs + "/nixos/modules/installer/cd-dvd/installation-cd-minimal-new-kernel-no-zfs.nix")
          baseCommonModule
          embeddedEtcNixosModule
          workstationServicesModule
          workstationPackagesModule
          desktopCommonModule
          desktopFullModule
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

        z80 = pkgsFor.mkShell {
          packages = z80DevPackages;
        };

        nes = pkgsFor.mkShell {
          packages = nesDevPackages;
          shellHook = nesShellHook;
        };
      };
    };
}
