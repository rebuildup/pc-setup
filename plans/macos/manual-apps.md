# macOS candidate vendor-managed applications

This file is **planning state**. It does not assert that these applications are already part of the actual Mac environment.

## Adobe Creative Cloud

Candidate parent application:

```ruby
cask "adobe-creative-cloud"
```

If the creative workflow is moved to macOS, evaluate installing through Creative Cloud:

- Adobe After Effects
- Adobe Illustrator

These remain explicit child-product candidates. Installing Creative Cloud alone must not silently count as adopting them.

Also review:

- After Effects plugins/scripts
- fonts
- presets
- workspaces
- Adobe account/licensing state

Those are separate migration concerns.

## Steinberg / Cubase

Candidate parent application:

```ruby
cask "steinberg-download-assistant"
```

If Cubase is used on the Mac, install and license the actual Cubase edition through Steinberg Download Assistant.

Also evaluate:

- Steinberg Activation Manager
- Steinberg Library Manager
- audio interface drivers
- VST/VST3 plugins
- content/library storage location

Do not copy a Windows Cubase installation directory onto macOS.

## Logitech software

`logitech-g-hub` is represented as a mise Homebrew-cask candidate because Logitech G hardware is used on Windows.

Do not assume it is the final macOS choice. Evaluate the actual connected devices and whether:

- Logitech G HUB
- Logi Options+
- no Logitech background software

is the smallest sufficient setup.

## Keyboard remapping

kanata remains a candidate capability; if adopted on macOS it should be expressed through the mise-managed host/tool configuration rather than a standalone Brewfile.

Before promotion to active state, verify:

- macOS Input Monitoring / Accessibility permissions
- launch-at-login/service ownership
- actual keyboard config
- interaction with macOS modifier-key settings
- whether a lower-level Windows-only ChgKey responsibility is still needed at all

ChgKey itself is Windows-specific and is not a macOS candidate.

## Applications intentionally not carried over automatically

Windows-specific utilities such as these are not inherited merely because they exist in the Windows profile:

- PowerToys
- WizTree
- Microsoft PC Manager
- ChgKey

If an equivalent macOS capability is actually needed, select it based on the Mac workflow rather than manufacturing a one-to-one replacement list.
