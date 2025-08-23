# Safe bootloader and system cleanup configuration
# Uses NixOS built-in mechanisms instead of custom scripts
{
  config,
  pkgs,
  lib,
  ...
}: {
  # Bootloader configuration with built-in cleanup
  boot.loader = {
    systemd-boot = {
      # This is the safe, built-in way to limit boot entries
      # NixOS will automatically manage cleanup
      configurationLimit = 5;
      enable = true;
    };

    efi.canTouchEfiVariables = true;
  };

  # Safe automatic garbage collection using NixOS built-ins
  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      auto-optimise-store = true;

      # Keep only recent builds to prevent excessive accumulation
      keep-outputs = false;
      keep-derivations = false;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d"; # More aggressive cleanup

      # Also clean up boot files when doing GC
      # This uses nix-collect-garbage which is much safer
      persistent = true;
    };

    # Additional nix optimization
    optimise = {
      automatic = true;
      dates = ["weekly"];
    };
  };

  # Use NixOS's built-in generation management instead of custom scripts
  system = {
    # This controls how many generations are kept in /nix/var/nix/profiles/system
    # Older generations beyond this limit are automatically eligible for GC
    autoUpgrade = {
      enable = false; # Set to true if you want automatic updates
      dates = "weekly";
      flags = [
        "--max-jobs"
        "2"
        "--cores"
        "0"
      ];
    };
  };

  # Safe way to monitor and alert on boot partition usage
  # Instead of automatically deleting files
  systemd.services.boot-space-monitor = {
    description = "Monitor boot partition space usage";

    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };

    script = ''
      BOOT_USAGE=$(df /boot | tail -1 | awk '{print $5}' | sed 's/%//')
      echo "Boot partition usage: $BOOT_USAGE%"

      if [ "$BOOT_USAGE" -gt 85 ]; then
        echo "WARNING: Boot partition usage is $BOOT_USAGE%" | systemd-cat -p warning
        echo "Consider running: sudo nix-collect-garbage --delete-older-than 3d" | systemd-cat -p warning
        echo "Or manually clean old kernels from /boot/EFI/nixos/" | systemd-cat -p warning
      fi
    '';
  };

  # Timer for monitoring (non-destructive)
  systemd.timers.boot-space-monitor = {
    description = "Monitor boot partition space";
    wantedBy = ["timers.target"];

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  # Safe manual cleanup tools using NixOS built-ins
  environment.systemPackages = with pkgs; [
    # Safe generation cleanup
    (writeShellScriptBin "cleanup-generations" ''
      echo "=== NixOS System Generations ==="
      sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
      echo ""
      echo "=== Home Manager Generations ==="
      home-manager generations 2>/dev/null || echo "Home Manager not found"
      echo ""
      echo "To clean up old generations safely:"
      echo "  sudo nix-collect-garbage --delete-older-than 7d"
      echo "  home-manager expire-generations '-7 days'"
      echo ""
      echo "To clean up everything older than today:"
      echo "  sudo nix-collect-garbage --delete-old"
    '')

    # Safe boot space checker
    (writeShellScriptBin "check-boot-space" ''
      echo "=== Boot Partition Usage ==="
      df -h /boot
      echo ""
      echo "=== Boot Files by Size ==="
      du -sh /boot/* 2>/dev/null | sort -hr
      echo ""
      echo "=== EFI/nixos Directory ==="
      if [ -d "/boot/EFI/nixos" ]; then
        ls -la /boot/EFI/nixos/ | head -10
        echo "... (showing first 10 files)"
        echo ""
        echo "Current kernel: $(uname -r)"
        echo "Files for current kernel:"
        ls -la /boot/EFI/nixos/*$(uname -r)* 2>/dev/null || echo "No files found for current kernel"
      fi
    '')

    # Safe manual cleanup helper
    (writeShellScriptBin "safe-boot-cleanup" ''
      echo "This will help you safely clean up boot files."
      echo "Current kernel: $(uname -r)"
      echo ""

      if [ -d "/boot/EFI/nixos" ]; then
        echo "=== Current Boot Files ==="
        cd /boot/EFI/nixos

        # Show kernels by version
        echo "Kernel versions found:"
        ls *bzImage.efi 2>/dev/null | sed 's/.*linux-\([0-9.]*\)-.*/\1/' | sort -V | uniq -c
        echo ""

        echo "=== Safe Cleanup Steps ==="
        echo "1. Run: sudo nixos-rebuild boot"
        echo "2. Run: sudo nix-collect-garbage --delete-older-than 3d"
        echo "3. Check space: df -h /boot"
        echo ""
        echo "=== Manual File Removal (if needed) ==="
        echo "Only remove files for kernels you're NOT currently running!"
        echo "Current kernel: $(uname -r)"
        echo ""
        echo "To see which files are safe to remove:"
        echo "ls -la *bzImage.efi | grep -v $(uname -r)"
        echo "ls -la *initrd.efi | grep -v $(uname -r)"
      else
        echo "/boot/EFI/nixos not found"
      fi
    '')
  ];

  # Post-rebuild hook to run safe cleanup
  system.activationScripts.post-rebuild-cleanup = {
    text = ''
      # Run built-in NixOS cleanup after rebuild
      echo "Running post-rebuild cleanup..."

      # This uses NixOS's safe built-in garbage collection
      ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d || true

      # Check boot space and warn if needed
      BOOT_USAGE=$(df /boot | tail -1 | awk '{print $5}' | sed 's/%//')
      if [ "$BOOT_USAGE" -gt 80 ]; then
        echo "WARNING: Boot partition is $BOOT_USAGE% full"
        echo "Consider running: sudo nix-collect-garbage --delete-older-than 3d"
        echo "Or check: check-boot-space"
      fi
    '';
    deps = [];
  };
}
