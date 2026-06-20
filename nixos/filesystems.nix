{ config, lib, pkgs, ... }: {
  # Mount an external hard drive via sshfs (assuming it’s a remote system)
  # fileSystems."/mnt/storage" = {
  #   device = "your_wsl_username@nixos.local:/mnt/d"; # Change this to your remote system's location
  #   fsType = "fuse.sshfs";
  #   options = [
  #     "allow_other"
  #     "_netdev"
  #     "reconnect"
  #     "ServerAliveInterval=15"
  #     "x-systemd.automount"  # This will mount it on first access
  #     "x-systemd.idle-timeout=600"  # Unmount after 10 minutes of inactivity
  #   ];
  # };

  # If it's a local drive, you might need to specify the device path like /dev/sda1
  fileSystems."/mnt/storage" = {
    device = "/dev/sda1";
    fsType = "ntfs";
    # nofail: a missing data disk must not block boot
    # nosuid,nodev: data-only disk; no executable device files needed
    options = ["defaults" "nofail" "nosuid" "nodev"];
  };

  # Ensure SSHFS is available
  environment.systemPackages = with pkgs; [
    # sshfs
  ];
}

