#!/bin/bash

# Settings

# Kernel Android Release
export Android_Release="13"

# Kernel Version
export Kernel_Version="5.10"

# Kernel Security Patch or lts (latest)
# Recommend same as stock kernel
export Security_Patch="2023-03" #android13-5.10-2023-03 (5.10.157)

export User_Name="jimmy9478"
export User_Email="jimmy@daedalus.cc"
export Working_Dir="$HOME/Projects/PxGKI"

# SukiSU-Ultra driver ref. MUST come from the `builtin` branch: that is the only SukiSU
# branch that still carries kernel-side susfs (the CONFIG_KSU_SUSFS* symbols live in its
# kernel/Kconfig). `main`, `susfs_new` and every v3/v4 tag ship a driver with ZERO susfs
# code, so the CONFIG_KSU_SUSFS* lines appended to gki_defconfig are silently dropped by
# Kconfig and common/fs/susfs.c is never compiled (obj-$(CONFIG_KSU_SUSFS) += susfs.o).
# Root and KPM still work, which is why this looks fine until the susfs module reports
# "unsupport" and none of its rules apply.
#
# Pinned to 6c13a06 (2026-05-30) = the last builtin commit BEFORE b8279c3 "kernel, ksud,
# manager: implement uapi version (#3455)". b8279c3 and adcea94 after it move the
# supercall ABI to a new generation (adds KERNEL_SU_UAPI_VERSION=2, bumps
# KSU_APP_PROFILE_VER 3 -> 4 with a new __u64 flags field) that the v4.1.3 Manager APK
# does not speak -> "Failed to update App Profile". 6c13a06 keeps KSU_APP_PROFILE_VER 3,
# so susfs + KPM + the v4.1.3 manager all agree.
#   - Moving to builtin tip (newer susfs fixes) REQUIRES a post-uapi manager build; the
#     v4.1.3 release is not one, and 4.1.2/4.1.3 ship no APK asset at all.
export SukiSU_Src="6c13a06"
# Ref whose commit count drives KSU_VERSION. Keep it at the tag the manager reports, so
# the banner stays clean: 40000 base + 3611 tag commits - 2815 offset = 40796.
export SukiSU_Ver="v4.1.3"

# susfs4ksu ref, pinned to the same era as SukiSU_Src (SUSFS v2.1.0, 2026-05-30). The
# kernel patch on common/, the driver glue on the builtin branch and the ksu_susfs
# userspace tool inside the module are ONE matched set - do not mix generations.
# Empty = branch tip.
export Susfs_Src="ee023e3"

# KPM (KernelPatch) tool version. Pins patch_linux to a tagged SukiSU_KernelPatch_patch
# release (which carries a matching kpimg) instead of tracking a moving branch tip, so the
# injected KPM runtime is a known-good build. Only used when KERNEL_KPM=y.
export KPM_Patch_Ver="0.13.0"

# Kernel Suffix
# Set (Kernel_Suffix="") meaning delete dirty suffix
# or using custom suffix to replace it
# Recommend same as stock kernel
export Kernel_Suffix="android13-4-00003-g776d0a76f6aa-ab10208116"

# Kernel Build Timestamp
# Recommend same as stock kernel
export Kernel_Time="Thu May 25 12:11:12 UTC 2023"

echo
echo -e "\e[32mKernel information preview\e[0m"
echo Android：$Android_Release
echo Version：$Kernel_Version
echo Security Patch：$Security_Patch
if [[ "$Kernel_Suffix" == "" ]]; then
  echo Delete the dirty suffix
else
  echo Custom suffix：$Kernel_Suffix
fi
echo Build Timestamp：$Kernel_Time
echo

echo -e "\e[33mCheck the settings before starting\e[0m"
echo -e "\e[33mPress Ctrl+C to exit during execution\e[0m"
echo

# Non-interactive when KERNEL_KPM is preset or stdin is not a terminal, so the script can be
# driven from CI or a one-liner:  KERNEL_KPM=y SKIP_APT=1 ./Buildkernel.sh
if [ -t 0 ] && [ -z "$KERNEL_KPM" ]; then
  read -n 1 -s -p "Press any key to continue"
  echo
fi

# Select KPM feature
while [[ "$KERNEL_KPM" != "y" && "$KERNEL_KPM" != "n" ]]; do
  if [ ! -t 0 ]; then
    echo -e "\e[31m[Error]\e[0m Set KERNEL_KPM=y or KERNEL_KPM=n when running non-interactively"
    exit 1
  fi
  read -p "KPM Feature (y=Enable, n=Disable): " KERNEL_KPM
  [[ "$KERNEL_KPM" == "y" || "$KERNEL_KPM" == "n" ]] || echo -e "\e[31m[Error]\e[33m Please select：y or n\e[0m"
done
export KERNEL_KPM

# Install tools (APT is used by default). Skipped when everything is already present,
# so a re-run does not wait on apt or ask for a sudo password.
if [ -n "$SKIP_APT" ] || command -v curl git python3 zip >/dev/null 2>&1; then
  echo -e "\e[32mTools already present, skipping apt\e[0m"
else
  echo -e "\e[32mInstall tools\e[0m"
  sudo apt update
  sudo apt upgrade -y
  sudo apt-get install -y curl git python3 zip
fi

# Set up repo
if command -v repo >/dev/null 2>&1; then
  echo -e "\e[32mrepo already installed, skipping\e[0m"
else
  echo -e "\e[32mSet up repo\e[0m"
  curl https://storage.googleapis.com/git-repo-downloads/repo > $Working_Dir/repo
  chmod a+x $Working_Dir/repo
  sudo mv $Working_Dir/repo /usr/local/bin/repo
fi

# Sync GKI Source Code
echo -e "\e[32mSync GKI source code\e[0m"
mkdir -p $Working_Dir/Buildkernel
cd $Working_Dir/Buildkernel
git config --global user.email "$User_Email"
git config --global user.name "$User_Name"

# Reset a previous run back to pristine so this script is safe to re-run.
# The patch/defconfig steps below all assume an untouched tree: susfs would be applied
# on top of itself and the defconfig appends would pile up duplicates otherwise.
if [ -d common/.git ]; then
  echo -e "\e[33m[Reset]\e[0m" Restoring common/ and build/kernel/ to pristine
  git -C common reset --hard >/dev/null 2>&1
  git -C common clean -fd >/dev/null 2>&1
  git -C build/kernel checkout -- . >/dev/null 2>&1
  rm -rf KernelSU
fi

echo "Branch: common-android$Android_Release-$Kernel_Version-$Security_Patch"
repo init -u https://android.googlesource.com/kernel/manifest -b common-android$Android_Release-$Kernel_Version-$Security_Patch --depth=1

# Fix deprecated kernel/common branch
# Older security patch levels get renamed on kernel/common (android13-5.10-2023-09
# -> deprecated/android13-5.10-2023-09) while the manifest still pins the old name,
# which makes "repo sync" fail with "cannot find remote ref". Override it locally.
Kernel_Branch="android$Android_Release-$Kernel_Version-$Security_Patch"
Kernel_Common_Url="https://android.googlesource.com/kernel/common"
if ! git ls-remote --exit-code --heads "$Kernel_Common_Url" "refs/heads/$Kernel_Branch" >/dev/null 2>&1; then
  if git ls-remote --exit-code --heads "$Kernel_Common_Url" "refs/heads/deprecated/$Kernel_Branch" >/dev/null 2>&1; then
    echo -e "\e[33m[Fix]\e[0m kernel/common $Kernel_Branch moved to deprecated/, overriding manifest"
    mkdir -p .repo/local_manifests
    cat > .repo/local_manifests/fix_common_deprecated.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="kernel/common" />
  <project path="common" name="kernel/common"
           revision="deprecated/$Kernel_Branch"
           upstream="deprecated/$Kernel_Branch"
           dest-branch="deprecated/$Kernel_Branch">
    <linkfile src="." dest=".source_date_epoch_dir" />
  </project>
</manifest>
EOF
  else
    echo -e "\e[31m[Error]\e[0m kernel/common has no branch $Kernel_Branch nor deprecated/$Kernel_Branch"
    exit 1
  fi
else
  rm -f .repo/local_manifests/fix_common_deprecated.xml
fi

repo sync -c -j4 --fail-fast

# Fix 6.6 build
if [[ "$Kernel_Version" == "6.6" ]]; then
cd $Working_Dir/Buildkernel/common
fake_patched=0
  if ! grep -qxF $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' ./fs/proc/task_mmu.c; then
    echo "Can't find nr_subpages, try to repair"
    sed -i -e '/int ret = 0, copied = 0;/a \\tunsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;' -e '/int ret = 0, copied = 0;/a \\tpagemap_entry_t \*res = NULL;' ./fs/proc/task_mmu.c
    fake_patched=1
  fi
fi

if [ "$fake_patched" = 1 ]; then
  if [ "$Kernel_Version" = "6.6" ]; then
    if grep -qxF $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' ./fs/proc/task_mmu.c; then
      sed -i -e '/unsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;/d' -e '/pagemap_entry_t \*res = NULL;/d' ./fs/proc/task_mmu.c
    fi
  fi
fi

# Set up SukiSU-Ultra
echo -e "\e[32mSet up SukiSU-Ultra\e[0m"
cd $Working_Dir/Buildkernel
# setup.sh treats its argument as a git ref (tag/branch/commit) to check out, NOT an
# install "mode". It clones the whole repo, so a commit that only lives on the `builtin`
# branch is reachable even though the clone lands on main first.
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s "$SukiSU_Src"
if [ ! -d KernelSU/.git ]; then
  echo -e "\e[31m[Error]\e[0m" "setup.sh did not clone the SukiSU driver"
  exit 1
fi
# Guarantee the version-count ref is resolvable locally (tag + full history) so the
# rev-list fallback can tally it even if the GitHub-API path is rate-limited.
git -C KernelSU fetch -q --tags --unshallow origin 2>/dev/null \
  || git -C KernelSU fetch -q --tags origin 2>/dev/null || true

# setup.sh runs `git checkout "$1" && echo ... || echo ...`, so a ref it cannot resolve
# only prints a message and leaves HEAD on main - which has no susfs at all. Verify.
Ksu_Head=$(git -C KernelSU rev-parse HEAD)
Ksu_Want=$(git -C KernelSU rev-parse "$SukiSU_Src^{commit}" 2>/dev/null || echo "")
if [ -z "$Ksu_Want" ] || [ "$Ksu_Head" != "$Ksu_Want" ]; then
  echo -e "\e[31m[Error]\e[0m" "SukiSU ref '$SukiSU_Src' not checked out (HEAD=${Ksu_Head:0:7}) - setup.sh fell through to main"
  exit 1
fi
echo -e "\e[33m[Done]\e[0m" "SukiSU driver at $SukiSU_Src ($(git -C KernelSU log -1 --format='%ad %s' --date=short | cut -c1-70))"

# The whole point of the pinned ref: this driver must define the susfs symbols, otherwise
# every CONFIG_KSU_SUSFS* line below is silently dropped by Kconfig and susfs.c never
# compiles. Fail loudly here instead of shipping a susfs-less kernel that looks fine.
if ! grep -qE '^config[[:space:]]+KSU_SUSFS[[:space:]]*$' KernelSU/kernel/Kconfig; then
  echo -e "\e[31m[Error]\e[0m" "KernelSU/kernel/Kconfig has no 'config KSU_SUSFS' - this SukiSU ref carries no susfs"
  echo -e "\e[31m[Error]\e[0m" "Use a commit from the 'builtin' branch (see SukiSU_Src at the top of this script)"
  exit 1
fi

# SukiSU derives KSU_VERSION from the commit count of REPO_BRANCH, which is hardcoded to
# "main" - so even a checked-out tag/commit still gets numbered off main's tip (-> 40879).
# Repoint REPO_BRANCH at the pinned version ref so both the GitHub-API and the local
# rev-list count paths tally the tag's 3611 commits -> 40000+3611-2815 = 40796.
# The file differs per branch: main/tags carry kernel/Kbuild, `builtin` only kernel/Makefile.
Ksu_Mk=""
for f in KernelSU/kernel/Kbuild KernelSU/kernel/Makefile; do
  if [ -f "$f" ] && grep -q '^REPO_BRANCH[[:space:]]*:=' "$f"; then Ksu_Mk="$f"; break; fi
done
if [ -n "$Ksu_Mk" ]; then
  sed -i "s|^REPO_BRANCH[[:space:]]*:=.*|REPO_BRANCH := $SukiSU_Ver|" "$Ksu_Mk"
  echo -e "\e[33m[Done]\e[0m" "Pinned SukiSU REPO_BRANCH -> $SukiSU_Ver in ${Ksu_Mk#KernelSU/} (KSU_VERSION will match the manager)"
else
  echo -e "\e[31m[Error]\e[0m" "No REPO_BRANCH found in KernelSU/kernel/{Kbuild,Makefile} - cannot pin KSU_VERSION"
  exit 1
fi

# Set up susfs
echo -e "\e[32mSet up susfs\e[0m"
cd $Working_Dir/Buildkernel
Susfs_Branch="gki-android$Android_Release-$Kernel_Version"
if [ -d susfs4ksu/.git ]; then
  git -C susfs4ksu fetch -q origin
else
  git clone -q https://gitlab.com/simonpunk/susfs4ksu.git -b "$Susfs_Branch"
fi
# Pin to the commit that matches SukiSU_Src. The branch tip tracks the newest SUSFS
# generation and its driver-side glue lives in kernel_patches/KernelSU/, which targets
# upstream KernelSU, not SukiSU - mixing them yields a kernel the module cannot talk to.
git -C susfs4ksu reset -q --hard "origin/$Susfs_Branch"
git -C susfs4ksu clean -qfd
if [ -n "$Susfs_Src" ]; then
  git -C susfs4ksu checkout -q --detach "$Susfs_Src" || {
    echo -e "\e[31m[Error]\e[0m" "susfs4ksu ref '$Susfs_Src' not found on $Susfs_Branch"
    exit 1
  }
fi
echo -e "\e[33m[Done]\e[0m" "susfs4ksu at $(git -C susfs4ksu rev-parse --short HEAD) ($(grep -m1 SUSFS_VERSION susfs4ksu/kernel_patches/include/linux/susfs.h | cut -d'"' -f2))"
cp susfs4ksu/kernel_patches/50_add_susfs_in_gki-android$Android_Release-$Kernel_Version.patch ./common/
cp susfs4ksu/kernel_patches/fs/* ./common/fs/
cp susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
cd $Working_Dir/Buildkernel/common
patch -p1 -F 3 < 50_add_susfs_in_gki-android$Android_Release-$Kernel_Version.patch

# Fix susfs / kernel snapshot skew: VMA_PAD_START
# susfs4ksu's gki branch tracks the newest release of its kernel line, which carries
# Android's pgsize_migration (16KB page padding). Older security-patch snapshots have no
# pgsize_migration.h, so VMA_PAD_START() is undefined there. With no padding it is
# exactly vma->vm_end, which is what the surrounding kernel code itself uses.
if [ ! -f ./include/linux/pgsize_migration.h ] && grep -q 'VMA_PAD_START' ./fs/proc/task_mmu.c; then
  sed -i 's|VMA_PAD_START(vma)|vma->vm_end|g' ./fs/proc/task_mmu.c
  echo -e "\e[33m[Done]\e[0m" Fix VMA_PAD_START for kernels without pgsize_migration
fi

echo -e "\e[32mKernel configuration\e[0m"

# Add configuration to kernel
cd $Working_Dir/Buildkernel
# susfs
# Only symbols that the pinned SukiSU driver actually defines. Kconfig drops anything it
# does not know WITHOUT a warning, so an unknown name here is a silent no-op - which is
# exactly how this kernel shipped with zero susfs for several builds. The list is checked
# against KernelSU/kernel/Kconfig before it is written.
#
# The AUTO_ADD_* / TRY_UMOUNT options from older susfs generations are deliberately gone:
# they do not exist on this driver (SukiSU does its own umount handling), so keeping them
# would just be four more silently-dropped lines.
Gki_Defconfig="./common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU=y" >> "$Gki_Defconfig"
for Susfs_Cfg in \
  CONFIG_KSU_SUSFS \
  CONFIG_KSU_SUSFS_SUS_PATH \
  CONFIG_KSU_SUSFS_SUS_MOUNT \
  CONFIG_KSU_SUSFS_SUS_KSTAT \
  CONFIG_KSU_SUSFS_SUS_MAP \
  CONFIG_KSU_SUSFS_SPOOF_UNAME \
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
  CONFIG_KSU_SUSFS_OPEN_REDIRECT \
  CONFIG_KSU_SUSFS_ENABLE_LOG \
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
; do
  if ! grep -qE "^config[[:space:]]+${Susfs_Cfg#CONFIG_}[[:space:]]*$" ./KernelSU/kernel/Kconfig; then
    echo -e "\e[31m[Error]\e[0m" "$Susfs_Cfg is not defined by this SukiSU driver - it would be dropped silently"
    exit 1
  fi
  echo "$Susfs_Cfg=y" >> "$Gki_Defconfig"
done
echo -e "\e[33m[Done]\e[0m" "Enabled 10 susfs options (all verified against the driver Kconfig)"
# tmpfs
echo "CONFIG_TMPFS_XATTR=y" >> ./common/arch/arm64/configs/gki_defconfig
echo "CONFIG_TMPFS_POSIX_ACL=y" >> ./common/arch/arm64/configs/gki_defconfig
sed -i 's/check_defconfig//' ./common/build.config.gki
echo -e "\e[33m[Done]\e[0m" Add configuration to kernel

# Add KPM configuration to kernel
if [ "$KERNEL_KPM" = "y" ]; then
  cd $Working_Dir/Buildkernel
  echo "CONFIG_KPM=y" >> common/arch/arm64/configs/gki_defconfig
  # patch_linux prints "[?] can't find arm64 relocation table" on kernels built with
  # CONFIG_RELR=y (the lld default): the relocations live in the compressed .relr.dyn
  # section, so .rela.dyn is left nearly empty. It is a warning, not a failure - kpimg
  # still takes over at runtime and loads .kpm modules (verified on 5.10.157 / raven).
  # Do not "fix" it by turning RELR off.
  echo -e "\e[33m[Done]\e[0m" Add KPM configuration to kernel
  echo -e "\e[33m[Done]\e[0m" Enable KPM feature
else
  echo -e "\e[33m[Done]\e[0m" Disable KPM feature
fi

# Set up kernel suffix
cd $Working_Dir/Buildkernel
# Strip the "-maybe-dirty" marker. Match on the assignment itself: on some trees
# (e.g. 5.10) LOCALVERSION lives in _set_localversion_cmd, several lines away from
# stable_scmversion_cmd, so a line-scoped sed on that symbol silently does nothing.
sed -i 's|export LOCALVERSION="-maybe-dirty"|export LOCALVERSION=""|' ./build/kernel/kleaf/impl/stamp.bzl
if [[ "$Kernel_Suffix" == "" ]]; then
  if [[ "$Kernel_Version" == "6.6" ]]; then
    sed -i '/^CONFIG_LOCALVERSION=/ s/="\([^"]*\)"/=""/' ./common/arch/arm64/configs/gki_defconfig
  fi
  echo -e "\e[33m[Done]\e[0m" Delete the dirty suffix
else
  if [[ "$Kernel_Version" == "6.6" ]]; then
    sed -i "\$s|echo \"\\$res\"|echo \"-$Kernel_Suffix\"|" ./common/scripts/setlocalversion
    sed -i "s/-4k/-$Kernel_Suffix/g" ./common/arch/arm64/configs/gki_defconfig
  else
    sed -i '$s|^echo "\$res"$|echo "$res-'"$Kernel_Suffix"'"|' ./common/scripts/setlocalversion
  fi
  echo -e "\e[33m[Done]\e[0m" Set up custom suffix: $Kernel_Suffix
fi

# Set up kernel build timestamp
cd $Working_Dir/Buildkernel
perl -pi -e "s{UTS_VERSION=\"\\\$\(echo \\\$UTS_VERSION \\\$CONFIG_FLAGS \\\$TIMESTAMP \\| cut -b -\\\$UTS_LEN\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $Kernel_Time\"}" ./common/scripts/mkcompile_h
sed -i -e "s|\$(preempt-flag-y) \"\$(build-timestamp)\"|\$(preempt-flag-y) \"$Kernel_Time\"|" ./common/init/Makefile
echo -e "\e[33m[Done]\e[0m" Set up kernel build timestamp

# Fix resolve_btfids link failure on glibc >= 2.38 hosts
# resolve_btfids/Makefile passes EXTRA_CFLAGS to the libbpf sub-make but not to
# libsubcmd, so libsubcmd misses the --sysroot from HOSTCFLAGS and compiles against
# the host /usr/include. Since glibc 2.38 that redirects strtol/strtoul/strtoull to
# __isoc23_*, which the older prebuilt sysroot libc does not export -> undefined
# symbols at link time. Harmless to apply on older hosts.
Btfids_Mk="$Working_Dir/Buildkernel/common/tools/bpf/resolve_btfids/Makefile"
if [ -f "$Btfids_Mk" ] && ! grep -q 'SUBCMD_SRC).*EXTRA_CFLAGS' "$Btfids_Mk"; then
  sed -i 's|\(\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))/\) \(\$(abspath \$@)\)|\1 EXTRA_CFLAGS="$(HOSTCFLAGS)" \2|' "$Btfids_Mk"
  echo -e "\e[33m[Done]\e[0m" Fix resolve_btfids host build flags
fi

# Build kernel
cd $Working_Dir/Buildkernel
echo -e "\e[32mBuilding kernel\e[0m"
sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' ./common/BUILD.bazel
rm -rf ./common/android/abi_gki_protected_exports_*
sed -i 's/BUILD_SYSTEM_DLKM=1/BUILD_SYSTEM_DLKM=0/' common/build.config.gki.aarch64
sed -i '/MODULES_ORDER=android\/gki_aarch64_modules/d' common/build.config.gki.aarch64
sed -i '/KMI_SYMBOL_LIST_STRICT_MODE/d' common/build.config.gki.aarch64
# kleaf renamed the dist flag between branches: newer trees take --destdir, older ones
# (e.g. android13-5.10-2023-03) only accept --dist_dir. Try both before giving up.
if ! tools/bazel run --config=fast --lto=thin //common:kernel_aarch64_dist -- --destdir=dist; then
  echo -e "\e[33m[Fix]\e[0m" Retrying dist step with --dist_dir for older kleaf
  tools/bazel run --config=fast --lto=thin //common:kernel_aarch64_dist -- --dist_dir=dist
fi
if [ ! -f dist/Image ]; then
  echo -e "\e[31m[Error]\e[0m" "dist/Image was not produced - kernel dist step failed"
  exit 1
fi

# Verify susfs actually made it into the build, not just into gki_defconfig. Kconfig
# drops unknown symbols without a warning and the build still succeeds, so the only
# honest proof is the generated .config plus real susfs code in the Image.
Built_Cfg=$(find out -name .config -path '*kernel_aarch64*' 2>/dev/null | head -1)
if [ -n "$Built_Cfg" ]; then
  if grep -q '^CONFIG_KSU_SUSFS=y$' "$Built_Cfg"; then
    echo -e "\e[33m[Done]\e[0m" "susfs verified in generated .config ($(grep -c '^CONFIG_KSU_SUSFS' "$Built_Cfg") options)"
  else
    echo -e "\e[31m[Error]\e[0m" "CONFIG_KSU_SUSFS is absent from $Built_Cfg - susfs was NOT compiled in"
    exit 1
  fi
else
  echo -e "\e[33m[Warn]\e[0m" "could not locate the generated .config to verify susfs"
fi
if [ "$(strings -n 5 dist/Image | grep -c -i susfs)" -eq 0 ]; then
  echo -e "\e[31m[Error]\e[0m" "dist/Image contains no susfs strings - susfs was NOT linked in"
  exit 1
fi

# KPM patch
if [ "$KERNEL_KPM" = "y" ]; then
  echo -e "\e[32mKPM patch\e[0m"
  cd dist
  # Pin patch_linux to the tagged KernelPatch release. Cache it per-version so a re-run
  # cannot silently reuse a different build's patch_linux (the old unversioned
  # ../patch_linux cache did exactly that -> mismatched kpimg).
  Patch_Cache="$Working_Dir/Buildkernel/patch_linux-$KPM_Patch_Ver"
  if [ ! -f "$Patch_Cache" ]; then
    echo -e "\e[32mDownloading patch_linux $KPM_Patch_Ver\e[0m"
    curl -LSs -o "$Patch_Cache" \
      "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/$KPM_Patch_Ver/patch_linux" \
      || { echo -e "\e[31m[Error]\e[0m failed to download patch_linux $KPM_Patch_Ver"; rm -f "$Patch_Cache"; exit 1; }
  fi
  cp "$Patch_Cache" ./patch_linux
  chmod 755 patch_linux
  ./patch_linux
  mv Image Image.orig
  mv oImage Image
  cp Image kernel
  echo -e "\e[33m[Done]\e[0m" KPM feature is enabled
else
  cd dist
  cp Image kernel
fi

# Set up AnyKernel3
echo -e "\e[32mSet up AnyKernel3\e[0m"
cd $Working_Dir/Buildkernel
if [ -d SukiSU_patch/.git ]; then
  git -C SukiSU_patch fetch -q origin && git -C SukiSU_patch reset -q --hard origin/HEAD
else
  git clone https://github.com/SukiSU-Ultra/SukiSU_patch.git
fi
# a previous run leaves its zip inside AnyKernel3/, which would get packed into the new one
rm -f SukiSU_patch/AnyKernel3/*.zip SukiSU_patch/AnyKernel3/Image

# Create AnyKernel3
echo -e "\e[32mCreate AnyKernel3\e[0m"
cd $Working_Dir/Buildkernel/SukiSU_patch/AnyKernel3
cp $Working_Dir/Buildkernel/dist/Image $Working_Dir/Buildkernel/SukiSU_patch/AnyKernel3
rm -f "android$Android_Release-$Kernel_Version-AnyKernel3.zip"
zip -r "android$Android_Release-$Kernel_Version-AnyKernel3.zip" ./* -x '*.zip' 

# Output Kernel and AnyKernel3
cd $Working_Dir/Buildkernel/
mkdir -p patched
cd patched
cp $Working_Dir/Buildkernel/dist/kernel $Working_Dir/Buildkernel/patched/
cp $Working_Dir/Buildkernel/SukiSU_patch/AnyKernel3/android$Android_Release-$Kernel_Version-AnyKernel3.zip $Working_Dir/Buildkernel/patched/
echo -e "\e[33m[Done]\e[0m" Complete
echo -e "\e[32mINFO:\e[0m" Output to $Working_Dir/Buildkernel/patched
