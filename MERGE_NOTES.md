# MERGE_NOTES.md - 4.14-stable 合并操作手册

> 本文档记录在 `4.14.206-dev` 分支上合并 android-4.14-stable 时的所有经验教训、决策依据和操作规范。每次合并新版本前请先回顾。

---

## 0. 速查表

| 任务 | 命令 / 文件 |
|------|------------|
| 找上游 tag | `git log --all --oneline --grep "Linux 4.14.2XX"` |
| 找 merge commit | `git log --all --oneline --grep "Merge 4.14.2XX"` |
| 查看某版本的真实 diff | `git show <upstream-tag>^..<upstream-tag> -- <file>` |
| 合并 | `git merge --no-commit --no-ff <upstream-tag>` |
| 冲突标记检查 | `grep -c "<<<<<<<" $(git diff --name-only --diff-filter=U)` |
| 强制 ours | `merge=ours` 在 `.git/info/attributes` |
| 修复历史 | `git commit --fixup=<hash>` + `git rebase -i --autosquash` |
| 恢复错误 rebase | `git reflog` → `git reset --hard <good-hash>` |

---

## 1. 已配置 `merge=ours` 的文件（自动锁定）

完整列表见 [`.git/info/attributes`](file:///home/rpd4tonzy/.git/info/attributes)。下表为关键文件速查：

| 文件 | 锁定原因 | 错误发生版本 |
|------|---------|-----------|
| `fs/incfs/*` + `include/uapi/linux/incrementalfs.h` | opho 私有设计 vs upstream 重构 | 4.14.210-218 |
| `drivers/dma-buf/dma-buf.c` | opho 私有 helper 函数（partial/get_flags）| 4.14.222 |
| `drivers/usb/dwc3/gadget.{c,h}` + `dwc3-msm.c` | opho extern 函数 vs upstream static | 4.14.233 |
| `drivers/usb/dwc3/core.c` | opho 旧清理函数 vs upstream 新 API | 4.14.238 |
| `drivers/gpu/drm/msm/msm_drv.{c,h}` | opho vblank_work/kthread 设计 | 4.14.228 |
| `net/qrtr/qrtr.c` | opho v1/v2 vs upstream phdr | 4.14.227 |
| `kernel/sched/fair.c` | opho `cpu_isolated()` 检查 | 4.14.236 |
| `kernel/cgroup/cgroup.c` | opho `OPT_FEATURE_COUNT` 机制 | 4.14.237 |
| `fs/crypto/fname.c` | opho `fscrypt_nokey_name` vs upstream `digest_encode` | 4.14.240 |
| `fs/fs-writeback.c` | opho `block_dump___mark_inode_dirty` debug | 4.14.240 |
| `drivers/usb/gadget/function/f_uac*` | opho 私有声明 | 4.14.215, 4.14.233 |
| `drivers/soc/oplus/**`, `techpack/**` | opho 厂商代码 | （持续）|

> ⚠️ **绝对不要**对以上文件使用 `git checkout --theirs`（除 `drivers/usb/core/hub.c` 之外，它在 Tier 2b 中明确取 theirs）。

> ⚠️ **drivers/usb/core/hub.c 标记为 `merge=theirs`** — 特殊例外。当 upstream
> 包含 race condition 修复时（如 4.14.233 的 `d34cab87d2fb`），必须取 theirs。
> 默认应该是 ours，但 hub.c 的 opho 10ms 延迟被 upstream 明确标记为 bug。

---

## 2. 决策树：合并单个冲突文件

```
冲突文件
  │
  ├── 上下游均无 opho 专用 API（仅命名 / 重构）
  │   └─→ `git checkout --theirs` 是安全的
  │
  ├── 上游引入新 API/函数（local 无，upstream 新增）
  │   └─→ `git checkout --theirs` ✅
  │   例：4.14.221 的 dma_buf_release()，4.14.225 的 fibocom quirk
  │
  ├── local 已有 opho 私有实现，upstream 想替换
  │   ├─ upstream 是新设计（删除旧函数）→ 永远 `merge=ours`
  │   ├─ upstream 是兼容性增强（添加 NULL check）→ 手商，保留双侧
  │   ├─ upstream 是 race condition 修复 → `merge=theirs` ⚠️
  │   └─ upstream 是 whitespace 调整 → 任何选择都行
  │   例：4.14.228 的 msm_pdev_shutdown（ours 更安全）
  │   例：4.14.226 的 mmc part_time + cmdq（手商）
  │   例：4.14.233 的 hub.c TRSMRCY（theirs - 关键！）
  │   例：4.14.240 的 sm_make_chunk.c / avc.c（whitespace）
  │
  └── local 与 upstream 都在同一位置有不同实现
      ├─ 同方向（都加了某函数）→ 手商
      └─ 互斥（local 加 A，upstream 删 A 换 B）→ 评估语义
         - 如 A 是 opho 依赖 → 永远 `merge=ours`
         - 如 B 是 upstream 修复 → 手商
         例：4.14.221 的 `was_locked` vs `do_unlock_page`（取 theirs）
         例：4.14.233 的 dwc3 static（取 ours 修复）
```

---

## 3. 错误案例库（每次合并前重读一遍）

### 案例 1：4.14.222 `dma-buf.c`（**严重**）
- **错误**：用 `git checkout --theirs` 整体替换了 oppo 私有 `dma-buf.c`
- **后果**：删除了 `dma_buf_begin_cpu_access_partial` / `dma_buf_get_flags`，导致链接失败
- **影响范围**：11+ 个 oppo 调用方（msm_gem, kgsl, qseecom, vidc, cam_mem_mgr, audio, fastrpc, adsprpc 等）
- **修复**：commit `5afa9240b052`（fixup!）从 oppo branch 恢复整个文件
- **教训**：`git checkout --theirs` = 整个文件替换，不只替换冲突区

### 案例 2：4.14.233 `dwc3/gadget.c`（**严重**）
- **错误**：用 `git checkout --theirs`，把 oppo 的 extern 函数改成了 static
- **后果**：`dwc3-msm.c` 报 redefinition 错误
- **影响范围**：6 个函数，1 个重复定义
- **修复**：commit `3b0386064f02`（fixup!）恢复 4.14.232 状态
- **教训**：对 oppo 设计的 struct/函数，可见性（static vs extern）是契约

### 案例 3：4.14.228 `msm_drv.c`（**中等**）
- **错误**：用 `git checkout --theirs`，引入了 `msm_vblank_ctrl`（未在 msm_drv.h 定义）
- **后果**：编译错误
- **修复**：commit `1ebeb7aab181` 取 ours
- **教训**：取 theirs 时要验证整个文件的依赖关系

### 案例 4：4.14.227 `qrtr.c`（**中等**）
- **错误**：合并时加了 upstream 的 `phdr` 验证逻辑
- **后果**：11 个 undeclared 错误（`ver`, `size`, `type`, `dst`, `psize` 等）
- **修复**：删除 upstream 验证，保留 oppo `alloc_skb_with_frags`
- **教训**：手商时检查上下文中 local 的变量名

### 案例 5：4.14.233 `hub.c` 10ms TRSMRCY（**严重 - 运行时崩溃**）
- **错误**：4.14.233 合并时取 ours，保留了 opho 的 10ms `usleep_range()`
- **后果**：USB 设备连接时内核崩溃重启（4.14.235 上发生）
- **根因**：upstream commit `d34cab87d2fb` 明确说明这是 **race condition**，
  10ms 等待是 unneeded。upstream 把它移到 SuspendCleared 段
- **修复**：commit `e5012688c1af` 删除错误位置的 10ms 延迟
- **教训**：
  - **opho 私有 ≠ 正确**：vendor 可能有"workaround"代码但实际上是 bug
  - 合并前要看 upstream commit message（`git log --grep "race" 4.14-stable`）
  - 4.14.233 包含多个 USB 关键 fix（dwc3、xhci、hub），不能盲目保留
- **.git/info/attributes 修正**：把 `drivers/usb/core/hub.c` 改为 `merge=theirs`
  （罕见但需要 - 当 upstream 是 race condition 修复时）

---

## 4. 操作流程

### 4.1 合并前

```bash
# 1. 找到上游 tag 和 merge commit
git log --all --oneline --grep "Linux 4.14.2XX"   # 上游 tag
git log --all --oneline --grep "Merge 4.14.2XX"   # merge commit
```

### 4.2 合并中

```bash
# 1. 合并（先看冲突数）
git merge --no-commit --no-ff <upstream-tag>

# 2. 如果有冲突：
#    a. 列出冲突文件
git diff --name-only --diff-filter=U

#    b. 对每个冲突文件，应用"决策树"（第 2 节）
#    c. 对每个文件，验证冲突标记归零
for f in $(git diff --name-only --diff-filter=U); do
  grep -c "<<<<<<<" $f  # 必须为 0
done

# 3. 提交
git commit --no-verify -m "Merge 4.14.2XX into android-4.14-stable

Resolved conflicts:
- <file>: <ours/theirs/hand-merge>. <reason>
- <file>: ...
"
```

### 4.3 合并后

```bash
# 1. 验证 build
bash build.sh  # 必须 BUILD SUCCESS

# 2. 检查冲突标记残留
grep -rn "<<<<<<< " --include="*.c" --include="*.h" . | grep -v "^\./out/"

# 3. 检查 Makefile 版本号
head -7 Makefile  # SUBLEVEL = 2XX
```

---

## 5. 修复历史的标准模式

**推荐：使用 `fixup!` 提交 + `--autosquash` 之外的简单做法**

```bash
# 1. 在工作树中修复
git add <fixed-files>

# 2. 创建 fixup 提交
git commit --fixup=<target-commit-hash>
# → commit message 变成 "fixup! <original subject>"

# 3. 不做 rebase！直接保留 fixup 作为独立 commit
# 理由：交互式 rebase 风险大（前几次已证实会破坏历史）

# 4. 在 commit message 中详细说明：
#    - 哪个 merge 错了
#    - 为什么错（--theirs 删除 opho 函数）
#    - 修复了什么
#    - 影响范围（哪些 caller）
```

### 现有 fixup 提交

| 提交 | 目标 | 错误原因 |
|------|------|---------|
| `5afa9240b052` | 4.14.222 | `--theirs` 删了 dma-buf 私有函数 |
| `3b0386064f02` | 4.14.233 | `--theirs` 把 extern 改 static |

> **4.14.336 之前**：择机做一次完整 rebase 清理，squash 这些 fixup 到原 commit。需要 force push，单独操作。

---

## 6. 节奏与验证策略

| 任务量 | 频率 | 验证 |
|--------|------|------|
| 合并 1-5 个版本 | 单次会话 | 完整 `bash build.sh` |
| 合并 6-10 个版本 | 单次会话 | 必须 build 验证（推荐 5 个一批）|
| 合并 10+ 个版本 | 拆分多次 | 每 5 个 build 一次 |
| fixup 历史清理 | 每月 | 独立 PR / force push |

### 当前已合并的版本（截至 4.14.235）

```
$ git log --oneline 4.14.210..HEAD
4.14.235 ← 4.14.234 ← 4.14.233 ← 4.14.232 ← 4.14.231 ← 4.14.230
← 4.14.229 ← 4.14.228 ← 4.14.227 ← 4.14.226 ← 4.14.225 ...
```

---

## 7. 自动化检查（建议加入 build.sh）

```bash
# 1. 冲突标记检查（编译前必须为 0）
pre_build_check() {
  local conflicts=$(grep -rn "<<<<<<< " --include="*.c" --include="*.h" . 2>/dev/null | grep -v "^\./out/" | wc -l)
  if [ $conflicts -gt 0 ]; then
    echo "ERROR: $conflicts conflict markers remain in source"
    return 1
  fi
}

# 2. oppo 关键文件存在性
check_oppo_files() {
  for f in drivers/dma-buf/dma-buf.c drivers/usb/dwc3/gadget.c \
           drivers/gpu/drm/msm/msm_drv.c net/qrtr/qrtr.c; do
    [ -f "$f" ] || { echo "MISSING: $f"; return 1; }
  done
}
```

---

## 8. 长期演进路径

| 阶段 | 内核版本 | 主要挑战 |
|------|---------|---------|
| 当前 | 4.14.210-235 | incfs + dwc3 + dma-buf 锁 ours |
| 中期 | 4.14.236-280 | 可能更多 audio/camera vendor 代码 |
| 后期 | 4.14.281-336 | 准备 EOL，密集合并 |
| 升级 | 5.4+ | 全面重写 vendor 适配层 |

---

**最后更新**：2026-08-02（4.14.235 合并完成，build 验证通过）
**维护者**：Tonzy (bsKSU)
