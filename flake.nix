{
  description = "Model Context Protocol SDK for Elixir";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05-small";
    elixir-overlay.url = "github:zoedsoupe/elixir-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    elixir-overlay,
  }: let
    inherit (nixpkgs.lib) genAttrs;
    inherit (nixpkgs.lib.systems) flakeExposed;

    forAllSystems = f:
      genAttrs flakeExposed (
        system: let
          overlays = [elixir-overlay.overlays.default];
          pkgs = import nixpkgs {inherit system overlays;};
        in
          f pkgs
      );
  in {
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        name = "anubis-mcp-dev";
        packages = with pkgs; [
          (elixir-with-otp erlang_28)."1.18.4"
          erlang_28
          redis
          uv
          just
          go
          zig
          _7zz
          xz
          nodejs
          k6
        ];
      };
    });

    packages = forAllSystems (pkgs: {
      default = pkgs.stdenv.mkDerivation {
        pname = "anubis-mcp";
        version = "0.17.0"; # x-release-please-version
        src = ./.;

        buildInputs = with pkgs; [
          elixir-bin.latest
          erlang
          zig
          _7zz
          xz
          git
        ];

        buildPhase = ''
          export MIX_ENV=prod
          export ANUBIS_MCP_COMPILE_CLI=true
          export HOME=$TMPDIR

          mix do deps.get, compile
          mix release anubis_mcp --overwrite
        '';

        installPhase = ''
          mkdir -p $out/bin

          echo "=== Build output structure ==="
          find _build -type f -name "*anubis*" 2>/dev/null || true

          if [ -d "_build/prod/rel/anubis_mcp/burrito_out" ]; then
            echo "Found burrito_out directory"
            cp -r _build/prod/rel/anubis_mcp/burrito_out/* $out/bin/ || true
          elif [ -d "_build/prod/rel/anubis_mcp/bin" ]; then
            echo "Found standard release bin directory"
            cp -r _build/prod/rel/anubis_mcp/bin/* $out/bin/ || true
          else
            echo "No bin directory found, checking for other release outputs"
            find _build/prod/rel -name "*" -type f -executable | head -5
          fi

          if [ -n "$(ls -A $out/bin 2>/dev/null)" ]; then
            chmod +x $out/bin/* || true
            echo "=== Installed binaries ==="
            ls -la $out/bin/
          else
            echo "ERROR: No binaries were installed!"
            exit 1
          fi
        '';

        meta = with pkgs.lib; {
          description = "Model Context Protocol (MCP) implementation in Elixir";
          homepage = "https://github.com/zoedsoupe/anubis-mcp";
          license = licenses.mit;
          maintainers = with maintainers; [zoedsoupe];
          platforms = platforms.unix ++ platforms.darwin;
        };
      };
    });

    apps = forAllSystems (pkgs: {
      default = {
        type = "app";
        program = "${self.packages.${pkgs.system}.default}/bin/anubis_mcp";
      };
    });
  };
}
