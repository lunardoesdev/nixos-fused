{
  device ? "/dev/vda",
  imageName ? "myhost",
  imageSize ? "8G",
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
}
