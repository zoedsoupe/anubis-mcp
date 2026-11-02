{
  description = "Model Context Protocol SDK for Elixir";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";
    beam-overlay.url = "github:zeeetech/beam-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    beam-overlay,
  }: let
    inherit (nixpkgs.lib) genAttrs;
    inherit (nixpkgs.lib.systems) flakeExposed;

    forAllSystems = f:
      genAttrs flakeExposed (
        system: let
          overlays = [beam-overlay.overlays.default];
          pkgs = import nixpkgs {inherit system overlays;};
        in
          f pkgs
      );
  in {
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        name = "anubis-mcp-dev";
        packages = with pkgs; [
          (pkgs.beam-overlay.mkToolchain {
            elixir.version = "1.20.2";
          })
          erlang_28
          redis
          uv
          just
          go
          _7zz
          xz
          nodejs
          k6
        ];
      };
    });
  };
}
