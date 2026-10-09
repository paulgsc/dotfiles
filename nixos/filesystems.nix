_: {
  # Local NTFS data disk.
  fileSystems."/mnt/storage" = {
    device = "/dev/sda1";
    fsType = "ntfs";
    # nofail: a missing data disk must not block boot
    # nosuid,nodev: data-only disk; no executable device files needed
    options = ["defaults" "nofail" "nosuid" "nodev"];
  };
}
