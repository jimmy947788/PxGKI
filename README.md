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

KPM needs **two** steps, and the script does both:

1. `CONFIG_KPM=y` compiled into the kernel
2. `patch_linux` applied to `dist/Image` afterwards (embeds KernelPatch, ~180 KB larger)

Step 2 is offline post-processing on the raw `Image` and is kernel-version agnostic, so it can be
applied to an already-built kernel without recompiling. Verify it landed:

```
strings -n 6 dist/Image | grep -c KernelPatch      # 0 before, >0 after
```

>[!WARNING]
>The bundled `patch_linux` hardcodes the KernelPatch **superkey to `123`** and ignores every
>command-line flag (`-s`, `-p`, `-o`, ...) despite advertising them in its usage text. Setting a
>custom superkey requires upstream KernelPatch `kptools` + `kpimg` instead.

---

#### Build fixes carried by this script

These are worked around automatically; listed so the behaviour is not surprising.

| Symptom | Cause | Handling |
|---|---|---|
| `fatal: couldn't find remote ref refs/heads/android<N>-<ver>-<patch>` | Google moves retired patch levels to `deprecated/` on `kernel/common`, but the manifest still pins the old name | probes both names, writes `.repo/local_manifests/` override only when needed |
| `Kernel_Suffix` silently ignored | the suffix logic was gated on `6.1`/`6.6` only, and its `stamp.bzl` sed matched a line that does not contain `-maybe-dirty` | applies to every version, matches the `export LOCALVERSION=` assignment directly |
| `undefined symbol: __isoc23_strtoul` linking `resolve_btfids` | host glibc >= 2.38 redirects `strtol*`; `resolve_btfids/Makefile` forwards `EXTRA_CFLAGS` to libbpf but not to libsubcmd, so libsubcmd misses `--sysroot` | passes `HOSTCFLAGS` to the libsubcmd sub-make (not `CFLAGS`, which would drag in `-std=gnu89` and break libsubcmd's `-std=gnu99`) |
| `implicit declaration of function 'VMA_PAD_START'` | susfs4ksu tracks the newest release of its kernel line, which has Android's `pgsize_migration`; older snapshots do not | rewrites it to `vma->vm_end` only when `include/linux/pgsize_migration.h` is absent |

>[!TIP]
>Building on a host with glibc >= 2.38 (Ubuntu 24.04+) is fine, but older security-patch snapshots
>lag behind susfs4ksu by design. If a new `implicit declaration` shows up, the fix is usually to
>find the pre-existing kernel equivalent of the macro, the same way `VMA_PAD_START` was handled.

---

#### Credits
[AnyKernel3](https://github.com/osm0sis/AnyKernel3) [KernelSU](https://kernelsu.org/) [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) [KernelPatch](https://github.com/bmax121/KernelPatch) [susfs](https://gitlab.com/simonpunk/susfs4ksu)
