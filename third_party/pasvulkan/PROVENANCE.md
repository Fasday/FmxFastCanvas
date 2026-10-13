# PasVulkan provenance

The Vulkan API header of PasVulkan (`Vulkan.pas`, generated from the Khronos `vk.xml` by PasVulkan's
`vkxml2pas`), vendored with a few local patches for Delphi 37 (Delphi 13) on Win64, Android64 and Linux64. Only the
header: the PasVulkan framework and engine units are not used.

- Upstream: https://github.com/BeRo1985/pasvulkan
- File: `src/Vulkan.pas` at revision `1467e9b27e0244b94162da630cc3c584bfb74e4b` (2026-10-08, the last change of the
  file when it was vendored), `VK_HEADER_VERSION` 346 (Vulkan 1.4).
- License: zlib (`LICENSE`) for the Pascal translation, Copyright (C) 2016-2024 Benjamin Rosseaux; the Khronos
  notice of the API registry is kept at the top of the unit.

## Local patches

Marked `FastCanvas patch` in the source; the generated declarations are untouched.

- `{$warnings off}` and `{$hints off}` after the `unit` line: W1012 subrange warnings of flag bits `$80000000` in
  `TVkInt32` enumerations in Delphi 37 (the bits are kept).
- `CPU64` is defined for Delphi from `CPU64BITS` (FPC defines `CPU64`): the X11 and XCB handle types are 64-bit on
  Linux64.
- `uses`: `Winapi.Windows` for Delphi (unit scope names need not be set), `Posix.Dlfcn` for Delphi on Android and
  Linux, which define `POSIX`, not FPC's `Unix`.
- `VK_DEFAULT_LIB_NAME`: `libvulkan.so.1` also for Delphi's `LINUX`.
- `vkLoadLibrary`, `vkGetProcAddress`, `vkFreeLibrary`: `dlopen`, `dlsym`, `dlclose` of `Posix.Dlfcn` for Delphi on
  POSIX (UTF-8 names; the upstream code returned nil there).
- `XLIB` is defined on Linux (not Android): the declarations of `VK_KHR_xlib_surface` (FastCanvas presents to X11
  windows there).

Checked: compiles with dcc64, dccaarm64 and dcclinux64; on Win64 the loader, an instance and the device features
(dynamic rendering, synchronization2, timeline semaphores, buffer device address, acceleration structures, ray query)
work on an AMD Radeon RX 9070 XT.
