{
  description = "KanadeApp — native iOS & macOS client for kanade";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        # mkShellNoCC: avoid pulling in apple-sdk which conflicts with Xcode Swift
        devShells.default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            tuist
          ];

          shellHook = ''
            # Clear Nix SDK env vars so Xcode's toolchain is used
            unset DEVELOPER_DIR
            unset SDKROOT
            unset MACOSX_DEPLOYMENT_TARGET
            # Remove Nix's xcrun wrapper from PATH
            export PATH=$(echo "$PATH" | sed "s,${pkgs.xcbuild.xcrun}/bin,,")

            echo "🎹 KanadeApp dev shell"
            echo "  tuist $(tuist version)"
            echo "  swift $(swift --version 2>&1 | head -1)"
          '';
        };
      }
    );
}
