# 同步上游 FlClash

本项目的 `origin/main` 已包含 FlClash ISP 改动。日常同步从本项目的 `main` 建临时分支，把上游 `main` 合进来，验收后再通过 PR 合回本项目。保留合并提交，Git 下次同步时会从新的共同祖先计算差异。

| 远端 | 用途 |
| --- | --- |
| `origin` | [milesradford99/FlClash](https://github.com/milesradford99/FlClash)，本项目 |
| `upstream` | [chen08209/FlClash](https://github.com/chen08209/FlClash)，原版 FlClash |

## 1. 取回两个远端的 main

在本项目的工作副本中执行。先用 `git status --short` 检查工作区，把正在进行的修改留在原分支或提交后再切换。

```bash
git remote -v
git remote add upstream https://github.com/chen08209/FlClash.git  # 仅首次配置
git fetch --no-recurse-submodules origin main
git fetch --no-recurse-submodules upstream main
git rev-list --left-right --count origin/main...upstream/main
git log --oneline origin/main..upstream/main
```

计数左边是本项目独有的提交数，右边是上游待合入的提交数。右边为 0 时已经同步。仓库有两个子模块，先只取主仓库提交，合并后再按最终提交指针初始化。

## 2. 在同步分支合并

```bash
sync_branch="sync/upstream-main-$(date +%Y%m%d)"
git switch --no-track -c "$sync_branch" origin/main
git merge --no-ff --no-commit upstream/main
git status --short
git diff --name-only --diff-filter=U
```

有冲突时同时看两侧的变化。这里的 ours 是本项目，theirs 是上游。在未提交的合并中，`git merge --abort` 可回到合并前。

- `README*` 和 macOS 文档保留本项目的构建、下载和验收入口，吸收仍适用的上游说明。
- `arb/*.arb` 保留双方有效的文案键，先处理改名、重复键和占位符。配置页与 provider 保留上游的新行为，同时接回固定 ISP 的添加、诊断和切换入口。
- `core/Clash.Meta` 和 `plugins/prism_ui` 是锁定到特定提交的子模块。遇到指针冲突时，用 `git ls-files -u -- core/Clash.Meta plugins/prism_ui` 看双方 SHA，在对应子模块核对并切换到经验证的 SHA，再 `git add` 该子模块路径。检查 Core 出站和 IPC、TUN 授权及 UI API 是否兼容新版本。
- `lib/l10n/` 和 `lib/providers/generated/` 中的冲突从已经合并的源文件重新生成。先以一侧生成文件作为临时输入，再运行下面的生成命令并审查输出，最后把重新生成的文件标为已解决。

依赖和 Dart 源文件冲突解决后，准备最终版本的子模块并按需重新生成：

```bash
git submodule sync --recursive
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
flutter pub get
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
```

`.gitmodules` 的地址使用 SSH。上面的单次 HTTPS 映射适用于没有配置 GitHub SSH 的机器。日常同步按主仓库最终记录的提交初始化子模块，避免使用会把子模块推进到分支尖端的 `submodule update --remote`。

## 3. 验证再提交

```bash
git status --short
git diff --check
flutter analyze --no-fatal-infos
flutter test test/features/managed_isp test/providers/setup_action_test.dart \
  test/providers/action_test.dart test/core/protocol_contract_test.dart
(cd core && go test . ./cmd/core)
```

在 macOS 按[本机签名与打包](macos/NetworkProtection/README.md#本机签名与打包)构建单 App，再用[单 App 验收表](macos/NetworkProtection/README.md#单-app-验收)检查 TUN、普通订阅分流、指定应用、Chrome 空间、共享切换和 ISP 故障。若同步改动涉及全机过滤器或其签名，也按[全机网络保护](macos/NetworkProtection/README.md#全机网络保护)验收相应构建。

用 `git add <已解决的文件>` 逐项标记冲突解决结果。确认暂存区同时包含上游变更和本项目保留的功能，且没有未解决的冲突，再提交：

```bash
git status --short
git diff --cached --check
git diff --cached --stat
git commit -m 'chore(sync): merge upstream FlClash main'
git merge-base --is-ancestor upstream/main HEAD
```

## 4. 推送同步分支并创建 PR

```bash
git push -u origin "$sync_branch"
gh pr create --repo milesradford99/FlClash \
  --base main --head "$sync_branch" \
  --title 'chore(sync): merge upstream FlClash main' \
  --body '同步上游 main。请核对冲突处理、子模块指针与 macOS 固定 ISP 验收记录。'
```

在 PR 补上本次同步的上游 SHA、冲突处理、子模块变更和实际测试结果。验收后在 GitHub 选择 **Create a merge commit**。保留上游提交作为本项目 `main` 的祖先，下一次同步就从上次合入的位置继续。如果合入后发现回归，通过新的回滚 PR 保留历史，并记录回滚范围。整次合并被撤回后，后续同步会继续沿用已有的上游祖先；恢复被撤回的内容需要重新引入对应改动。

GitHub 的基础操作见[同步 fork](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/syncing-a-fork)。
