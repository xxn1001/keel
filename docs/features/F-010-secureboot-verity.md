---
id: F-010
title: Secure Boot and dm-verity
status: deferred
target: future
owner: TBD
updated: 2026-11-10
depends: [F-002, F-005]
---

# F-010 Secure Boot + dm-verity（future）

## 1. Why

v1 明确不做签名/verity：自己编译、马上安装、无对手。
但如果机器离开物理控制，或者要做“可证明未被篡改”，需要 Secure Boot + dm-verity。
本文只记录未来路径，不进 v1；实现前必须写新 ADR 推翻 [ADR-0007](../decisions/ADR-0007-no-signature.md)。

## 2. Scope

包含（未来）：

- 自签/企业密钥签 systemd-boot + UKI。
- 固件登记证书（或 shim）。
- root erofs + dm-verity，roothash 在 UKI/cmdline。
- 可选 TPM PCR 封印。

不包含（v1）：

- 任何签名/verity 代码。
- 密钥管理自动化。

## 3. User-visible behavior（未来）

- `bootctl status` 显示 Secure Boot enabled。
- `systemd-veritysetup` 校验 root。
- 篡改 root 后启动失败。

## 4. Interfaces（未来）

| 接口 | 说明 |
|---|---|
| `mkosi`/`ukify` 签名 | 不进 v1；用 Buildroot 后处理 |
| `sbverify`/`sbsign` | 验证/签名 |
| `veritysetup` | root hash |
| `systemd-veritysetup` | 启动时校验 |

## 5. Design notes

- UKI 已经打包 kernel/initrd/cmdline，适合签名。
- root 是两个 LVM LV（`system/root_a|b`）：每个槽一份 roothash；cmdline 里带 `roothash=`。
- Secure Boot 开启后，未签名 UKI 不执行；密钥轮换要设计。
- dm-verity 要求 root 逐字节可校验；`/etc` 不在 root 里（独立 LV），不冲突。
- TPM pcrlock 依赖固件 event log；不是所有机器都有。

## 6. Failure modes / recovery（未来）

| 失败 | 处理 |
|---|---|
| 密钥丢失 | 无法更新/启动；离线备份 |
| 固件不信任证书 | 登记证书或关 SB |
| verity 不匹配 | 启动失败；回旧槽 |
| 更新破坏 roothash | 拒绝更新 |

## 7. Acceptance criteria（未来）

- [ ] `bootctl status` = Secure Boot enabled。
- [ ] `sbverify` 通过。
- [ ] 篡改 root 后启动失败。
- [ ] 回滚到旧槽仍能启动。

## 8. Open questions / ADR links

- 当前决策：[ADR-0007](../decisions/ADR-0007-no-signature.md)（v1 不做）。
- 未来实现前必须写新 ADR。
- 密钥管理/TPM 策略：未定。

## 9. Test plan

E3：真机 + 固件密钥库；E2 只能验证签名/启动链，不能验证真实固件信任。

## 10. Changelog

| 日期 | 变更 |
|---|---|
| 2026-11-10 | 初稿；标 deferred |
