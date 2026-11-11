#!/usr/bin/env python3
"""构建前磁盘余量闸门：磁盘快满时**提前**失败，别让构建在半路崩掉。

为什么要有这道闸：
Xcode 构建依赖 SQLite 构建数据库（`Build/Intermediates.noindex/XCBuildData/build.db`）
和索引存储（`Index.noindex/DataStore/v5/records/`）。磁盘写满时，它们的失败方式
极具误导性——表现为**随机分布**的编译错误：

    error: accessing build database ".../build.db": disk I/O error
    Writing index record file: failed to create directory ".../records/UZ": No such file or directory
    error closing ".../VisionModelCard.o" for output: ... No such file or directory

这些报错挂在**互不相干**的源文件上（Expense*、Food*、PromptBlock…），
看起来像代码编译失败，实际是磁盘 I/O 崩溃后的级联。
更糟的是 `build.db` 可能根本建不出来，排查成本极高。

判定：
- 统计**数据卷**（`/System/Volumes/Data`，即用户数据实际所在卷）的可用空间。
- 低于 `MIN_FREE_GIB` 直接非零退出，并打印占用最大的可清理目录，
  避免下一个人继续在错误的方向上排查代码。

用法：
    python3 scripts/check_disk_space.py             # 校验，失败非零退出
    python3 scripts/check_disk_space.py --audit     # 只打印现状，恒零退出
"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 构建一次的余量需求：DerivedData + 编译中间产物，实测约 6~8 GiB
# （关闭索引存储后不再有 Index.noindex 的上千个分片目录）。
# 阈值 12 GiB：既够一次全量构建，又留出系统与临时文件的安全垫。
# 定得太高（比如 20 GiB）会把构建直接挡死，反而让这道闸门变成负担。
MIN_FREE_GIB = 12.0

# 空闲空间不足时提示的可清理候选（仅提示，不代用户删除）。
CLEANABLE_HINTS = [
    (ROOT / "DerivedData", "项目内 Xcode 构建产物"),
    (ROOT / "build", "项目内构建产物"),
    (ROOT / ".build", "项目内 SwiftPM 构建缓存"),
    (Path.home() / "Library/Developer/Xcode/DerivedData", "全局 Xcode 缓存"),
    (Path.home() / "Library/Developer/CoreSimulator/Devices", "模拟器设备数据（xcrun simctl delete <udid>）"),
]


def data_volume_free_bytes() -> int:
    """取数据卷可用空间。

    macOS 上 `/` 是只读系统卷，用户数据在 `/System/Volumes/Data`，
    直接 `shutil.disk_usage("/")` 拿到的是系统卷的余量，会严重高估可用空间。
    """
    for path in ("/System/Volumes/Data", "/"):
        try:
            usage = shutil.disk_usage(path)
        except OSError:
            continue
        if path == "/System/Volumes/Data":
            return usage.free
    return shutil.disk_usage("/").free


def human(num_bytes: float) -> str:
    return f"{num_bytes / (1024 ** 3):.1f} GiB"


def dir_size_bytes(path: Path) -> int:
    """统计目录实际占用。

    注意：不能用 `shutil.disk_usage(path)` —— 它返回的是**所在卷**的总用量，
    对每个子目录都会重复报成整个卷的大小。
    """
    try:
        result = subprocess.run(
            ["du", "-sk", str(path)],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout:
            return int(result.stdout.split()[0]) * 1024
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return 0


def audit() -> int:
    free = data_volume_free_bytes()
    print(f"数据卷可用空间: {human(free)}（阈值 {MIN_FREE_GIB:.0f} GiB）")
    print()
    print("可清理的构建产物候选（仅提示，未删除任何内容）：")
    any_found = False
    for path, desc in CLEANABLE_HINTS:
        if not path.exists():
            continue
        size = dir_size_bytes(path)
        if size <= 0:
            continue
        any_found = True
        print(f"  {human(size):>10}  {path}  — {desc}")
    if not any_found:
        print("  （没有发现显著的构建产物缓存）")
    print()
    print("提示：项目内产物可用 ./scripts/clean.sh --yes 清理（白名单 + 路径逃逸校验）")
    return 0


def check() -> int:
    free = data_volume_free_bytes()
    free_gib = free / (1024 ** 3)
    if free_gib >= MIN_FREE_GIB:
        print(f"✅ 磁盘余量充足：{human(free)} ≥ {MIN_FREE_GIB:.0f} GiB")
        return 0

    print(f"❌ 磁盘余量不足：仅剩 {human(free)}，低于 {MIN_FREE_GIB:.0f} GiB 阈值", file=sys.stderr)
    print("", file=sys.stderr)
    print("   在磁盘写满的情况下，Xcode 构建会以**误导性的方式**失败：", file=sys.stderr)
    print("     · error: accessing build database \".../build.db\": disk I/O error", file=sys.stderr)
    print("     · Writing index record file: failed to create directory \".../records/XX\"", file=sys.stderr)
    print("     · error closing \".../SomeFile.o\" for output: ... No such file or directory", file=sys.stderr)
    print("", file=sys.stderr)
    print("   这些报错随机挂在互不相干的源文件上，**不是代码错误**，别往编译问题上排查。", file=sys.stderr)
    print("", file=sys.stderr)
    print("   请先释放空间：", file=sys.stderr)
    print("     ./scripts/clean.sh --yes      # 清理项目内构建产物", file=sys.stderr)
    print("", file=sys.stderr)
    audit()
    return 1


def main() -> int:
    if "--audit" in sys.argv:
        return audit()
    return check()


if __name__ == "__main__":
    sys.exit(main())
