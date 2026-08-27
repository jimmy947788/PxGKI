# PxGKI 分析筆記

## 1. 配合最新 SukiSU Manager 的修改

目前官方最新正式 Manager 為 **v4.1.3**。

### 問題
- `b8279c3`（「implement uapi version」）之後：
  - 新增 `KERNEL_SU_UAPI_VERSION = 2`
  - `KSU_APP_PROFILE_VER` 從 3 升到 4（多了 `__u64 flags`）
- v4.1.3 Manager 只支援 App Profile v3 → 會出現 **「Failed to update App Profile」**（root 仍可用）

### 目前專案設定（相容 v4.1.3）
```bash
export SukiSU_Src="6c13a06"   # builtin 分支，UAPI v1 / App Profile v3 的最後一個 commit
export SukiSU_Ver="v4.1.3"
export Susfs_Src="ee023e3"    # 同時代 susfs（SUSFS v2.1.0）
```

### 若要使用更新的 Manager（main / CI 建置）
1. 把 `SukiSU_Src` 改成 `builtin` 分支更新的 commit（`b8279c3` 之後）
2. 同步更新 `Susfs_Src` 到對應世代
3. 必須使用支援 UAPI v2 / App Profile v4 的 Manager APK（官方 4.1.3 沒有釋出此版本的 APK）

---

## 2. 讓 susfs 模組真正生效

### 核心限制
- **只有 `builtin` 分支** 的 SukiSU 才有 kernel-side susfs（`CONFIG_KSU_SUSFS` 定義在其 `kernel/Kconfig`）
- `main`、`susfs_new`、所有正式 `v3.x` / `v4.x` tag **都沒有** susfs 程式碼
- 若用錯 ref，`CONFIG_KSU_SUSFS*` 會被 Kconfig 靜默丟棄，模組會回報 `unsupport`

### 必須保持的兩個 pin（已寫在 `Buildkernel.sh` 頂部）
| 設定 | 值 | 說明 |
|------|-----|------|
| `SukiSU_Src` | `6c13a06` | builtin，2026-05-30，UAPI 變更前最後 commit |
| `Susfs_Src` | `ee023e3` | susfs4ksu gki-android13-5.10，SUSFS **v2.1.0** |

### 腳本已自動做的檢查
- 確認 HEAD 真的是指定的 `SukiSU_Src`（setup.sh 失敗時會 silent 落在 main）
- 確認 `KernelSU/kernel/Kconfig` 存在 `config KSU_SUSFS`
- 只啟用此 driver 實際定義的 10 個選項
- 建完後驗證 `.config` 有 `CONFIG_KSU_SUSFS=y` 且 `Image` 含 susfs 字串

### 刷入後驗證指令
```bash
adb shell su -c 'ksu_susfs show version'          # 應顯示 v2.1.0，不是 unsupport
adb shell su -c 'ksu_susfs show enabled_features'
```

### 常見失敗原因
- `SukiSU_Src` 不在 `builtin` → susfs 完全沒編譯進去
- `Susfs_Src` 與 SukiSU 世代不匹配 → 通訊失敗
- 混用正式 tag / main 的 SukiSU + 舊 susfs

---

## 總結建議
- **要穩定用官方 v4.1.3 Manager + susfs**：維持現有 pin（`6c13a06` + `ee023e3`）即可
- **要追最新 Manager**：需同時更新 SukiSU/Susfs 並自己建對應的 Manager APK
```
