#### SukiSU-Ultra + KPM(Optional) + susfs patched 5.10 / 6.1 / 6.6 GKI kernel for Pixel

#### Github Actions
>[!TIP]
>Do it yourself  
>Create a new fork, click on Actions tab then select Buildkernel click Run workflow (kernel customization)  
>When complete, kernel is available for download.

#### Local Script
>[!TIP]
>If create a new fork, remember to change github username in the link below.
```
git clone https://github.com/jimmy947788/PxGKI.git
```
```
cd PxGKI
```
```
chmod +x Buildkernel.sh
```
```
./Buildkernel.sh
```

>[!TIP]
>The script is safe to re-run. It resets `common/` and `build/kernel/` back to pristine before
>re-applying the patches, reuses the existing `susfs4ksu` / `SukiSU_patch` clones, and skips apt
>and the repo installer when they are already in place. To rebuild after changing a setting, edit
>the variables at the top and run it again — only the `repo sync` delta is fetched, and a full
>kernel build is about 5 minutes on 24 cores.
>
>Non-interactive (CI, or a single command):
>```
>KERNEL_KPM=y SKIP_APT=1 ./Buildkernel.sh
>```

---

#### Pick the right version first

>[!IMPORTANT]
>The **KMI generation** must match your device, and the kernel version must be **>= stock**.
>GKI guarantees module compatibility within one KMI generation (e.g. `android13-4`), which is
>why a generic kernel can replace the stock one at all. Downgrading below stock can break vendor
>modules, because newer GKI releases keep adding symbols to the KMI.
>
>Matching stock **exactly** is the best option: vendor modules stay in their tested range, and
>`uname -r` keeps looking stock, which matters if you use susfs to hide root.

Read the real values straight out of your stock `boot.img` instead of guessing:

```
python3 Buildkernel/tools/mkbootimg/unpack_bootimg.py --boot_img boot.img --out stock
lz4 -d stock/kernel stock/kernel.raw          # Pixel kernels are LZ4 (legacy frame)
strings stock/kernel.raw | grep -m1 'Linux version'
```

Example output from a Pixel 6 Pro (raven, TQ3A.230901.001):

```
Linux version 5.10.157-android13-4-00003-g776d0a76f6aa-ab10208116 (...) #1 SMP PREEMPT Thu May 25 12:11:12 UTC 2023
```

Map it onto the settings at the top of `Buildkernel.sh`:

| Setting | Value from the example | Notes |
|---|---|---|
| `Android_Release` | `13` | from `android13-4` |
| `Kernel_Version` | `5.10` | |
| `Security_Patch` | `2023-03` | the branch whose `SUBLEVEL` is `157`; `lts` = newest |
| `Kernel_Suffix` | `android13-4-00003-g776d0a76f6aa-ab10208116` | everything after `5.10.157-` |
| `Kernel_Time` | `Thu May 25 12:11:12 UTC 2023` | from the `#1 SMP PREEMPT` stamp |

>[!NOTE]
>The firmware build id (`TQ3A.230901.001`, Sep 2023) is **not** the kernel version. That firmware
>ships a GKI kernel built in May 2023. Always read the kernel string, never infer it from the
>security patch date.

To find which branch carries a given `SUBLEVEL`:

```
curl -s "https://android.googlesource.com/kernel/common/+/refs/heads/android13-5.10-2023-03/Makefile?format=TEXT" \
  | base64 -d | head -4
```

Also see [GKI release builds](https://source.android.com/docs/core/architecture/kernel/gki-release-builds#release-builds)
— note that page only lists the most recent ~12 months; older branches are gone from it.

---

#### How to flash

>[!WARNING]
>**Back up your stock `boot.img` before anything else.** Keep it reachable from fastboot.

>[!IMPORTANT]
>On Pixel, verified boot **must** be disabled or the device will bootloop no matter how good the
>kernel is:
>```
>fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
>```

**[Flashkernel.sh]** — the checked path. Verifies the image is a real Android boot image, that
its header version and ramdisk layout match stock, prints the kernel release and whether KPM is
embedded, checks the bootloader is unlocked, and only writes after you type `FLASH`. It touches the
active slot only, so the other slot keeps its stock kernel.

```
chmod +x Flashkernel.sh
./Flashkernel.sh                                  # newest image in Buildkernel/patched/
./Flashkernel.sh Buildkernel/patched/boot_x.img   # or a specific one
```

Edit `Stock_Dir` at the top to point at your own firmware directory.

**[fastboot]** — the same thing by hand; repack stock `boot.img` with the new kernel, so every other
field stays untouched:

```
python3 Buildkernel/tools/mkbootimg/unpack_bootimg.py --boot_img boot.img --out stock --format=mkbootimg
lz4 -l -12 --favor-decSpeed dist/Image kernel.lz4        # match stock compression
python3 Buildkernel/tools/mkbootimg/mkbootimg.py \
    --header_version 4 --kernel kernel.lz4 --ramdisk stock/ramdisk --cmdline '' \
    --output boot_new.img
fastboot flash boot boot_new.img
```

>[!NOTE]
>Do **not** flash `dist/boot.img` directly. It is a generic AOSP GKI image and does not carry your
>device's header fields. Check the layout first — on Pixel 6 / 6 Pro the ramdisk lives in
>`vendor_boot`, so stock `boot.img` legitimately reports `ramdisk size: 0`; other devices keep the
>ramdisk in `boot` and would lose it.

**[Repackboot.sh]** — the manual repack above, packaged. `Buildkernel.sh` only emits `dist/Image`
and an AnyKernel3 zip, not a `fastboot`-flashable boot image; this script builds one. It reads the
release / KSU version / KPM state straight out of the Image, lz4-compresses it (legacy frame, the
format the raven bootloader decompresses), and packs a header-v4, ramdisk-less image with the stock
layout, into `Buildkernel/patched/` where `Flashkernel.sh` finds it:

```
./Repackboot.sh                 # repack Buildkernel/dist/Image
./Repackboot.sh path/to/Image   # or a specific Image
# -> Buildkernel/patched/boot_sukisu_<release>_<ksu-tag>[_kpm].img, then:
./Flashkernel.sh
```

Recovery, if it bootloops:

```
fastboot flash boot <stock boot.img>
```

**[AnyKernel3]** (requires an already-rooted device) — uses
[HorizonKernelFlasher](https://github.com/libxzr/HorizonKernelFlasher). It swaps only the kernel
inside the existing `boot.img` and keeps the ramdisk. Note `do.devicecheck=0` in `anykernel.sh`:
it will not refuse a wrong device.

---

#### KPM

KPM needs **two** steps, and the script does both when `KERNEL_KPM=y`:

1. `CONFIG_KPM=y` compiled into the kernel
2. `patch_linux` applied to `dist/Image` afterwards (embeds KernelPatch / kpimg, ~180 KB larger)

`patch_linux` is pinned to a tagged [SukiSU_KernelPatch_patch](https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch)
release via `KPM_Patch_Ver` (default `0.13.0`) instead of a moving branch tip, so the injected kpimg
is a known-good build. It is cached as `Buildkernel/patch_linux-<ver>` and re-downloaded only if
missing — a version bump is just editing `KPM_Patch_Ver`.

Step 2 is offline post-processing on the raw `Image` and is kernel-version agnostic, so it can be
applied to an already-built kernel without recompiling. Verify it landed:

```
strings -n 6 dist/Image | grep -c KernelPatch      # 0 before, >0 after
```

>[!WARNING]
>The `0.13.0` `patch_linux` embeds kpimg with its default KernelPatch **superkey `123`** (confirmed
>in its output: `superkey: 123`). A custom superkey requires driving upstream KernelPatch
>`kptools` + `kpimg` yourself instead of this one-shot `patch_linux`.

>[!CAUTION]
>**Do not edit `Buildkernel.sh` while a build is running.** `bash` reads the script from disk
>line-by-line as it executes; saving the file mid-run shifts byte offsets and the parser desyncs,
>which shows up as a bogus `syntax error near ... then`. If a run dies that way *after* the dist
>step but *before* the KPM patch, don't recompile — finish by hand and repackage:
>```
>cd Buildkernel/dist
>cp ../patch_linux-0.13.0 patch_linux && chmod 755 patch_linux && ./patch_linux
>mv Image Image.orig && mv oImage Image && cp Image kernel
>cd ../.. && ./Repackboot.sh          # -> patched/boot_sukisu_*_kpm.img
>```

---

#### susfs: why the driver ref matters

>[!IMPORTANT]
>`CONFIG_KSU_SUSFS*` is defined by the **SukiSU driver's** `kernel/Kconfig`, not by the susfs
>kernel patch. Kconfig drops symbols it does not know **without a warning**, and the build still
>succeeds — so pointing `SukiSU_Src` at a ref with no susfs produces a kernel where root and KPM
>work, the manager looks healthy, and susfs is simply not there. That is exactly what the susfs
>module hitting a wall looks like: it reports `unsupport` and none of its rules apply.

Only the **`builtin`** branch of SukiSU-Ultra carries kernel-side susfs. `main`, `susfs_new` and
every `v3.x` / `v4.x` tag ship a driver with zero susfs code — the `susfs-main` / `susfs-test`
branches the SukiSU docs still mention no longer exist.

Two refs on that branch must be kept in step, both pinned at the top of `Buildkernel.sh`:

| Setting | Value | Why |
|---|---|---|
| `SukiSU_Src` | `6c13a06` | `builtin`, 2026-05-30 — the last commit before `b8279c3` "implement uapi version (#3455)" |
| `Susfs_Src` | `ee023e3` | susfs4ksu `gki-android13-5.10`, 2026-05-30, SUSFS **v2.1.0** — same generation as the driver |

`b8279c3` and `adcea94` after it move the supercall ABI to a new generation: they add
`KERNEL_SU_UAPI_VERSION = 2` and bump `KSU_APP_PROFILE_VER` from 3 to 4 (new `__u64 flags`).
The v4.1.3 Manager APK speaks version 3, so anything at or after `b8279c3` gives "Failed to
update App Profile" even though root works. `6c13a06` is the newest ref where susfs, KPM and the
v4.1.3 manager all agree — **moving to `builtin` tip requires a post-uapi manager build**, and
4.1.2 / 4.1.3 ship no APK asset at all.

The script now fails loudly rather than shipping a susfs-less kernel:

- after `setup.sh`, `HEAD` is compared against the pinned ref (`setup.sh` swallows a failed
  `git checkout` and silently leaves you on `main`)
- `config KSU_SUSFS` must exist in `KernelSU/kernel/Kconfig`
- every `CONFIG_KSU_SUSFS*` line is checked against that Kconfig *before* it is appended
- after the build, the generated `.config` must contain `CONFIG_KSU_SUSFS=y` and `dist/Image`
  must contain susfs strings

Only the ten options this driver actually defines are enabled. The older
`AUTO_ADD_SUS_KSU_DEFAULT_MOUNT`, `AUTO_ADD_SUS_BIND_MOUNT`, `TRY_UMOUNT` and
`AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT` symbols do not exist on this generation (SukiSU does its own
umount handling) and were four more silently-dropped lines.

>[!WARNING]
>The module and the kernel are one matched set. Install the `ksu_module_susfs` built from the
>**same** susfs4ksu commit — `Buildkernel/patched/ksu_module_susfs_v2.1.0.zip`, or rebuild it with
>`cd Buildkernel/susfs4ksu && ./build_ksu_module.sh`. A module carrying a different `ksu_susfs`
>binary talks a different supercall dialect.

Check it on the device after flashing:

```
adb shell su -c 'ksu_susfs show version'          # -> v2.1.0, not "unsupport"
adb shell su -c 'ksu_susfs show enabled_features'
```

---

#### Build fixes carried by this script

These are worked around automatically; listed so the behaviour is not surprising.

| Symptom | Cause | Handling |
|---|---|---|
| `fatal: couldn't find remote ref refs/heads/android<N>-<ver>-<patch>` | Google moves retired patch levels to `deprecated/` on `kernel/common`, but the manifest still pins the old name | probes both names, writes `.repo/local_manifests/` override only when needed |
| `Kernel_Suffix` silently ignored | the suffix logic was gated on `6.1`/`6.6` only, and its `stamp.bzl` sed matched a line that does not contain `-maybe-dirty` | applies to every version, matches the `export LOCALVERSION=` assignment directly |
| `undefined symbol: __isoc23_strtoul` linking `resolve_btfids` | host glibc >= 2.38 redirects `strtol*`; `resolve_btfids/Makefile` forwards `EXTRA_CFLAGS` to libbpf but not to libsubcmd, so libsubcmd misses `--sysroot` | passes `HOSTCFLAGS` to the libsubcmd sub-make (not `CFLAGS`, which would drag in `-std=gnu89` and break libsubcmd's `-std=gnu99`) |
| susfs module reports `unsupport`, no rules apply, root/KPM fine | `CONFIG_KSU_SUSFS*` is defined by the SukiSU driver's `kernel/Kconfig`; on a ref without susfs Kconfig drops every one of those lines silently | pins `SukiSU_Src` to the `builtin` branch and hard-fails if the symbols or the built `.config` are missing |
| `implicit declaration of function 'VMA_PAD_START'` | susfs4ksu tracks the newest release of its kernel line, which has Android's `pgsize_migration`; older snapshots do not | rewrites it to `vma->vm_end` only when `include/linux/pgsize_migration.h` is absent |

>[!TIP]
>Building on a host with glibc >= 2.38 (Ubuntu 24.04+) is fine, but older security-patch snapshots
>lag behind susfs4ksu by design. If a new `implicit declaration` shows up, the fix is usually to
>find the pre-existing kernel equivalent of the macro, the same way `VMA_PAD_START` was handled.

---

#### Credits
[AnyKernel3](https://github.com/osm0sis/AnyKernel3) [KernelSU](https://kernelsu.org/) [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) [KernelPatch](https://github.com/bmax121/KernelPatch) [susfs](https://gitlab.com/simonpunk/susfs4ksu)
