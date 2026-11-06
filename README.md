# laptop-keep-awake

让笔记本电脑在**屏幕熄灭 / 合上盖子**之后继续在后台运行，而不是一合盖就睡过去。

适合这些场景：合盖当小型服务器用、跑下载与编译、跑长时间 AI 任务、远程调试，但系统一合盖就断。

一个 PowerShell 脚本 + 一份实测笔记。`-Apply` 改、`-Verify` 查、`-Revert` 还原。

```powershell
# 1. 先看当前状态（不改任何东西，不符合预期时退出码为 1）
powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Verify

# 2. 应用：插电和电池都不睡眠，合盖不动作（自动备份原值）
powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Apply

# 3. 还原
powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Revert
```

> 实测环境：Windows 11 Pro 26200、笔记本、**仅支持现代待机（S0 低电量待机）**、标准用户（非管理员）。

---

## 一、先搞清楚「哪个动作导致睡眠」

合盖后跑不动，通常是下列三条链路之一，**要逐条排除**，只改其中一条往往没效果：

| 链路 | 触发条件 | 对应设置 |
|---|---|---|
| 合盖动作 | 合上显示器 | 「电源按钮和盖子」→ 合上盖子操作 |
| 空闲睡眠超时 | 无键鼠输入一段时间 | 「睡眠」→ 在此时间后睡眠（交流 / 电池分开） |
| 手动 / 厂商层 | 按电源键、厂商管家软件 | 电源按钮操作、厂商工具里的省电策略 |

### 关键认知：熄屏 ≠ 睡眠

这是最常被混淆的一点，两者是**独立**的：

- 「在此时间后关闭显示」= 关背光，**CPU 照常跑**，后台任务不受影响；
- 「在此时间后睡眠」= 进低功耗态，后台任务被挂起。

所以要的是「**显示超时保留（或缩短），睡眠超时设为从不**」，而不是去动显示设置。
本方案保留了显示超时（插电 60 分钟、电池 10 分钟），只关掉睡眠 —— 既省电又不影响运行。

## 二、操作步骤（命令行，可脚本化）

三条设置，`powercfg` 均可用，**标准用户通常就能改当前方案**（不需要管理员）。

### 1. 合上盖子时不睡眠

```powershell
# 0=不采取任何操作  1=睡眠  2=休眠  3=关机
powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
```

### 2. 睡眠超时设为从不

```powershell
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0   # 0 = 从不
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
```

### 3. 让设置生效

```powershell
powercfg /setactive SCHEME_CURRENT
```

> ⚠️ `powercfg /setXvalueindex` **写的是方案存储值**，不执行 `/setactive` 时部分系统未立即应用；
> 同时注意：这些值**只属于当前方案**，切到「节能 / 高性能」不会跟着走。

### 4. 让「合上盖子操作」重新出现在图形界面（可选）

系统默认把这项藏起来（`Attributes=1`），所以 `powercfg /q` 查不到、控制面板里也看不见：

```powershell
powercfg /attributes 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 -ATTRIB_HIDE
```

恢复隐藏用 `+ATTRIB_HIDE`。恢复后可在「控制面板 → 硬件和声音 → 电源选项 → 选择关闭盖子的功能」直接改。

### 一键完成

```powershell
# 折中：插电不睡，电池下仍 15 分钟睡眠（合盖依旧不动作）
powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Apply -BatterySleepMinutes 15
```

备份默认写在脚本同目录的 `keep-awake-backup.json`（已被 `.gitignore` 排除）。请**保留这份备份**，否则只能用下面的手工回滚。

## 三、如何验证真的生效了

不要只看命令退出码 —— `powercfg` 可能返回 0 但被策略覆盖。**读回实际值**：

```powershell
powercfg /a                                                                     # 看睡眠模型
powercfg /getactivescheme                                                       # 确认改的是哪个方案
powercfg /q SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936
```

期望「当前交流电源设置索引 / 当前直流电源设置索引」均为 `0x00000000`。
若该查询**只输出了方案名、没有任何设置项**，说明这项被隐藏，直接读注册表：

```powershell
$k='HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\381b4222-f694-41f0-9685-ff5bb260df2e\4f971e89-eebd-4455-a8de-9e59040e7347\5ca83367-6e45-459f-a27b-476b1d01c936'
Get-ItemProperty $k | Select-Object ACSettingIndex,DCSettingIndex
```

> 路径里的 `381b4222-...` 是**当前方案 GUID**，换方案后要替换。
> 这里读的是**用户方案副本**（`...\Power\User\PowerSchemes\...`），与 `...\Control\Power\PowerSettings\...`
> 下的**默认模板**不是一回事，改模板不影响已有方案。

最后做真实测试：合盖 → 隔几分钟用远程或网络服务确认仍在响应，或让一个后台任务在合盖状态下继续写入。

## 四、边界与坑

| 情况 | 说明与对策 |
|---|---|
| **现代待机（S0）机器** | 只有 S0、没有 S3 / 休眠（`powercfg /a` 会写明）。S0 下即使不进待机后台也会被限流，所以本方案走「**根本不进待机**」，而不是调待机参数。 |
| **想彻底关闭现代待机** | 需要改 `HKLM\SYSTEM\CurrentControlSet\Control\Power` 下的 `PlatformAoAcOverride`（管理员 + 重启），且可能导致厂商驱动异常，**不建议随意做**。 |
| **没有电源方案写入权限** | 企业组策略或厂商锁定时 `powercfg` 返回非 0。脚本会检查退出码并报错，此时需管理员或联系 IT。 |
| **立即被改回去** | 厂商管家（联想 / 戴尔 / 华硕等）、企业电源策略会周期性重置。需在厂商工具里关闭对应策略，而非反复执行脚本。 |
| **电池耗光风险** | 「关键级别电池操作」默认可能是**不采取任何操作**，合盖跑电池会一路到 0% 硬断电。建议加保险：`powercfg /setdcvalueindex SCHEME_CURRENT SUB_BATTERY BATACTIONCRIT 3`（5% 关机）。 |
| **电源键被误触** | 电源键默认可能是「睡眠」，需单独把 `a7066653-8d6c-40a8-910e-a1f54b84c7e5`（「开始」菜单电源按钮）或按钮项改为 0。 |
| **管理员权限的必要性** | 改**当前方案的值**一般不需要；改**默认模板**、改**隐藏属性**、写 HKLM 下 `PowerSettings` 才需要。实测标准用户三项都写成功。 |
| **`powercfg /requests`** | 它需要管理员，只用于排查「谁在阻止睡眠」，不是配置手段。 |

## 五、回滚

```powershell
# 方式一：用备份（推荐）
powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Revert

# 方式二：手工改回（合盖恢复睡眠、电池睡眠恢复 15 分钟）
powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1
powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 900
powercfg /attributes 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 +ATTRIB_HIDE
powercfg /setactive SCHEME_CURRENT
```

## 六、脚本行为说明

| 参数 | 作用 |
|---|---|
| 无参数 / `-Apply` | 备份原值 → 合盖不动作 → 睡眠从不（电池由 `-BatterySleepMinutes` 控制）→ 取消隐藏并应用 |
| `-Apply -BatterySleepMinutes <分钟>` | 同上，但电池供电下按指定分钟睡眠（默认 0 = 从不） |
| `-Verify` | 只读检查，输出当前表格；合盖或插电睡眠不是「不操作 / 从不」时退出码为 1 |
| `-Revert` | 读取备份 JSON 还原，写回的是**当前**方案 |
| `-BackupPath` | 自定义备份路径，默认脚本同目录 `keep-awake-backup.json` |

脚本会打印机箱类型与睡眠模型；机箱类型不像笔记本时会警告「合盖设置可能无效」。

## 七、GUID 速查

| 名称 | GUID |
|---|---|
| 电源按钮和盖子 `SUB_BUTTONS` | `4f971e89-eebd-4455-a8de-9e59040e7347` |
| 合上盖子操作 `LIDACTION` | `5ca83367-6e45-459f-a27b-476b1d01c936` |
| 睡眠 `SUB_SLEEP` | `238c9fa8-0aad-41ed-83f4-97be242c8f20` |
| 在此时间后睡眠 `STANDBYIDLE` | `29f6c1db-86da-48c5-9fdb-f2b67b1f44da` |
| 在此时间后休眠 `HIBERNATEIDLE` | `9d7815a6-7ee4-497e-8888-515a05f02364` |
| 显示 `SUB_VIDEO` | `7516b95f-f776-4464-8c53-06167f40cc99` |
| 在此时间后关闭显示 `VIDEOIDLE` | `3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e` |
| 电池 `SUB_BATTERY` | `e73a048d-bf27-4f12-9731-8b2076e8891f` |
| 关键级别电池操作 `BATACTIONCRIT` | `637ea02f-bbcb-4015-8e2c-a1c7b9c0b546` |
| 平衡 `SCHEME_BALANCED` | `381b4222-f694-41f0-9685-ff5bb260df2e` |

## 许可

MIT，见 [LICENSE](LICENSE)。
