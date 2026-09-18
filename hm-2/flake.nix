{
  inputs = {
    librelane.url = "github:librelane/librelane/e73adbd885e0a33efe131f4ea40f4f93efeb4247";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { librelane, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ librelane.devShells.${system}.default ];

        packages = with pkgs; [
          fastfetch
          graphviz
          xdot
	  ruff
	  basedpyright
          (python3.withPackages (
            ps: with ps; [
              cocotb
              pytest
            ]
          ))
        ];

        shellHook = ''
          echo "Welcome to the Layr Challenge Dev Shell!"
        '';
      };
    };
}
