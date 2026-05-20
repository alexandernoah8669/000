# 个人负债整理

一个基于 SwiftUI 的 iOS 原型应用，用来整理个人月度待还账单、平台负债、现金压力和月度归档。

## 当前功能

- 总览：净现金压力、本月待还、未来 7 天待还、已还/未还金额。
- 账单：内置 Excel 示例数据，支持搜索、状态筛选、新增、编辑和删除。
- 导入：在账单页可下载 Excel 导入模板，填写后从 Excel `.xlsx`、CSV 或 TSV 回导账单。
- 平台：按平台汇总剩余负债、本月应还、下次还款日和自动扣款状态。
- 月度：展示当前月自动汇总与历史月度归档。
- 设置：维护可用现金，恢复 Excel 示例数据。

## Excel 导入格式

导入入口在「账单」页顶部。可先下载「账单导入模板」填写，回导时会读取第一张工作表。表格需要包含这些必要表头：

- 平台
- 应还金额
- 最晚还款日

可选表头包括：账单类型、消费/借款日期、本金、利息/手续费、状态、自动扣款、备注。状态支持“未还”“已还”“逾期”“部分还款”；日期支持 `2026-05-20`、`2026/5/20`、`2026年5月20日` 等格式。

## 构建验证

当前机器的模拟器列表为空时，可以先用 SDK 做编译验证：

```sh
xcodebuild -project DebtOrganizer.xcodeproj -target DebtOrganizer -configuration Debug -sdk iphonesimulator26.5 SYMROOT=/tmp/DebtOrganizerBuild OBJROOT=/tmp/DebtOrganizerBuild/Intermediates build
```
