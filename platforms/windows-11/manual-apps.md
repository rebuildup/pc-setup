# Windows manual / vendor-managed applications

These applications are part of the desired environment even though their final product install is not represented by a single canonical WinGet package.

## Adobe

### Adobe Creative Cloud

The Creative Cloud desktop application itself is declared in root `mise.toml` and installed through mise's WinGet backend:

```toml
"winget:Adobe.CreativeCloud" = { os = "windows" }
```

After signing in, install these products from Creative Cloud:

- Adobe After Effects
- Adobe Illustrator

Do not treat Creative Cloud being present as proof that After Effects or Illustrator is installed.

Authentication, subscription/licensing state, plugins, fonts, presets, scripts, workspaces, and application preferences are separate migration concerns.

## Steinberg / Cubase

Install the current **Steinberg Download Assistant** from Steinberg.

Canonical source:

- https://www.steinberg.net/sda

The Download Assistant also manages/installs current Steinberg support utilities such as Activation Manager and Library Manager.

After signing in, install:

- Cubase

Cubase version/edition follows the user's license. Do not hard-code a product edition that is not confirmed by the license.

Sound libraries and large content packs are intentionally not auto-downloaded by `bootstrap.ps1`.

## ChgKey / Change Key

ChgKey is a legacy, portable keyboard-remapping utility that writes Windows keyboard scan-code mappings.

Current desired state:

- keep ChgKey available
- launch it as Administrator when changing mappings
- do not run it persistently
- do not silently replace its role with kanata

Trusted historical distribution/reference:

- 窓の杜 Change Key page: https://forest.watch.impress.co.jp/library/software/changekey/

The upstream application is old and does not declare Windows 11 support. Therefore `bootstrap.ps1` does **not** download or execute it automatically.

When rebuilding a machine:

1. Download from a trusted source.
2. Verify the downloaded archive/source before execution.
3. Extract to a stable utilities directory.
4. Run `ChgKey.exe` as Administrator.
5. Apply the intended scan-code mapping.
6. Restart Windows and verify the result.

Do not infer the actual key mapping from this installer inventory. Capture the mapping itself separately once the current machine configuration has been observed.

## Visual Studio workloads

`Microsoft.VisualStudio.2022.Community` installs the Visual Studio product shell.

For the current Windows development use cases, review Visual Studio Installer and ensure the actual workloads/components required by active projects are present, especially:

- Desktop development with C++
- .NET desktop development
- Windows App SDK / WinUI tooling when needed by desktop projects

Do not install every optional workload merely to make the machine look "complete".

## Android Studio

Android Studio is declared in root `mise.toml` and installed through the WinGet backend. Android SDK/NDK/JDK versions required by an individual repository should remain project-controlled where possible.

Avoid accumulating multiple unrelated global JDK installations. Android Studio's bundled runtime and project-specific requirements should be preferred over an untracked collection of system JDKs.
