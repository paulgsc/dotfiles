{
  config,
  pkgs,
  ...
}: {
  # Additional development packages beyond the vanilla set
  environment.systemPackages = with pkgs; [
    # Add more development tools here as you customize
    # Example: nodejs, python3, vscode, etc.
    alejandra
  ];

  # Development-specific services or configurations
  # Example: Enable additional services for development
  # services.postgresql.enable = true;
  # services.redis.enable = true;
}
