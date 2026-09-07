#!/usr/bin/env python3
"""把 ra6 广播的 RA 生存期改长，让 Android 15+ 肯收。

Android 15 起把 net.ipv6.conf.*.accept_ra_min_lft 设为 180 秒，生存期低于该值的
RA 会被整条丢弃。ra6 出厂写死 router lifetime 45s / valid 120s / preferred 45s，
全部低于门槛，于是新手机拿不到 IPv6，而 macOS/Windows（无此过滤）一切正常。

ra6 没有源码，也没有生存期参数，但这三个值是三条相邻指令里的立即数，可以精确定位：

    movk w10, #0x2d00, lsl #16    ; RA 头 [0xaa..0xad] = 40 18 00 2d
                                  ;   hop=64, flags=0x18(pref low), router lifetime=45
    movk x9,  #0x7800, lsl #48    ; 前缀选项 [0xb6..0xbd] = 03 04 40 c0 00 00 00 78
                                  ;   type=3 len=4 plen=64 flags=onlink|auto, valid=120
    mov  w8,  #0x2d000000         ; [0xbe..0xc1] = 00 00 00 2d, preferred=45

按 12 字节整体签名匹配，且要求全文件唯一；对不上就原样不动并退出 1，
所以换了别的 ra6 构建只会「不生效」，不会改坏。

编码上限：valid/preferred 所在的 bits47:32 恒为 0（没有指令写它），所以这两个值
最大 65535 秒。router lifetime 本身就是 16 位字段。

用法：
    ./patch-ra6.py 输入 [输出]        # 省略输出则原地改
    ./patch-ra6.py --check 输入       # 只报告当前状态，不写入
"""
import struct
import sys

# 都要远高于 180；preferred < valid。
ROUTER_LIFETIME = 1800   # 30 分钟，与 RouterOS /ipv6 nd 的默认值一致
VALID_LIFETIME = 7200    # 2 小时
PREF_LIFETIME = 3600     # 1 小时

OLD = (0x72A5A00A, 0xF2EF0009, 0x52A5A008)   # 45 / 120 / 45


def movk32(imm16, rd):    # movk wN, #imm16, lsl #16
    return 0x72A00000 | (imm16 << 5) | rd


def movk64_48(imm16, rd):  # movk xN, #imm16, lsl #48
    return 0xF2E00000 | (imm16 << 5) | rd


def movz32(imm16, rd):    # mov  wN, #imm16<<16
    return 0x52A00000 | (imm16 << 5) | rd


def swap16(v):
    """字段在包里是大端，写进寄存器的立即数正是它的字节交换。"""
    return ((v & 0xFF) << 8) | (v >> 8)


def encode(router, valid, pref):
    for name, v in (("router", router), ("valid", valid), ("preferred", pref)):
        if not 0 < v <= 0xFFFF:
            raise SystemExit(f"{name} lifetime 必须在 1..65535 之间：{v}")
    if pref > valid:
        raise SystemExit(f"preferred({pref}) 不能大于 valid({valid})")
    return (movk32(swap16(router), 10),
            movk64_48(swap16(valid), 9),
            movz32(swap16(pref), 8))


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check_only = "--check" in sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    src = args[0]
    dst = args[1] if len(args) > 1 else src

    data = bytearray(open(src, "rb").read())
    old_sig = b"".join(struct.pack("<I", i) for i in OLD)
    new = encode(ROUTER_LIFETIME, VALID_LIFETIME, PREF_LIFETIME)
    new_sig = b"".join(struct.pack("<I", i) for i in new)

    if data.count(new_sig) == 1:
        print(f"ra6 已是补丁版（router={ROUTER_LIFETIME}s valid={VALID_LIFETIME}s "
              f"preferred={PREF_LIFETIME}s）")
        return 0
    hits = data.count(old_sig)
    if hits != 1:
        print(f"ra6 里找不到唯一的生存期指令序列（匹配 {hits} 处），未改动。"
              f"可能是别的构建版本。", file=sys.stderr)
        return 1
    off = data.find(old_sig)
    if check_only:
        print(f"ra6 是原版（router=45s valid=120s preferred=45s），"
              f"低于 Android 的 180s 门槛；可补丁，偏移 {off:#x}")
        return 0
    data[off:off + 12] = new_sig
    open(dst, "wb").write(bytes(data))
    print(f"已补丁 {src} -> {dst}（偏移 {off:#x}）: "
          f"router 45->{ROUTER_LIFETIME}s, valid 120->{VALID_LIFETIME}s, "
          f"preferred 45->{PREF_LIFETIME}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
