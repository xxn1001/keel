# 运行证据

本目录保存每次验证的运行记录。一个工作项一次运行一份文件，append-only。

## 命名

`<YYYY-MM-DD>-<workitem>.md`，例如：

```text
2026-11-17-w1-storage.md
```

## 规则

- 一份文件不超过 150 行。
- 只保留被结论引用的输出窗口；完整日志放在本地临时目录或 artifact 中，不提交。
- 不放二进制、不放整份 `dmesg` 或 `journalctl`。
- append-only：旧证据错了，写新文件，在文件里写勘误并链接旧文件；不要改旧文件。

## 模板

```text
# <workitem> / <date> / <env>
branch: <branch> @ <sha>
build: <buildroot version, defconfig>
result: PASS | PARTIAL | FAIL

## 做了什么

## 命令

## 证据

## 判定（A-xxx 各自 verified/refuted/untested）

## 与设计不符的地方

## 备注
```
