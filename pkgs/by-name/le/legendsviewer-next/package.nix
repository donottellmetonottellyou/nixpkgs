{
  lib,
  buildDotnetModule,
  buildNpmPackage,
  dotnetCorePackages,
  fetchFromGitHub,
  makeDesktopItem,
  copyDesktopItems,
  nix-update-script,
  nodejs_22,
  writeShellScriptBin,

  legendsviewer-next,
}:
let
  dotnet-sdk = dotnetCorePackages.sdk_8_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_8_0;
  frontend = import ./frontend.nix {
    nodejs = nodejs_22;
    inherit buildNpmPackage legendsviewer-next;
  };
in
buildDotnetModule (finalAttrs: {
  pname = "legendsviewer-next";
  version = "1.2.0";

  desktopItems = [
    (makeDesktopItem {
      name = finalAttrs.pname;
      desktopName = "Legends Viewer";
      genericName = "DF Legends Export Browser";
      comment = finalAttrs.meta.description;
      icon = "${frontend}/dist/ceretelina.png";
      tryExec = "LegendsViewer";
      exec = "LegendsViewer";
      # Until (if) upstream supports multiple launches, we need a terminal to keep
      # track of if it's already launched.
      terminal = true;
      categories = [
        "Game"
        "RolePlaying"
        "Simulation"
      ];
      keywords = [
        "df"
        "dwarf"
        "fortress"
        "legends"
        "viewer"
      ];
    })
  ];

  nugetDeps = ./deps.json;

  src = fetchFromGitHub {
    owner = "Kromtec";
    repo = "LegendsViewer-Next";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Fi4KARGsgDmplH/oG9OIxY2XqhHNYgUB6OxwtoTaCt4=";
  };

  projectFile = "./LegendsViewer.Backend/LegendsViewer.Backend.csproj";
  testProjectFile = "./LegendsViewer.Backend.Tests/LegendsViewer.Backend.Tests.csproj";
  executables = [ "LegendsViewer" ];

  inherit dotnet-sdk dotnet-runtime;

  nativeBuildInputs = [
    # This fixes a build failure, we don't care about the frontend node build here
    (writeShellScriptBin "npm" "")
    copyDesktopItems
  ];

  installPhase = ''
    runHook preInstall

    lib=$out/lib/${finalAttrs.pname}

    mkdir -p $lib

    cp ./LegendsViewer.Backend/bin/Release/net8.0/linux-x64/* $lib
    ln -s ${frontend} $lib/${frontend.pname}

    runHook postInstall
  '';

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--subpackage frontend" ];
  };

  meta = {
    description = "Recreates Dwarf Fortress' Legends Mode from exported files";
    homepage = "https://github.com/${finalAttrs.src.owner}/${finalAttrs.src.repo}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ donottellmetonottellyou ];
  };
})
