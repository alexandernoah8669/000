# 个人负债整理

一个基于 SwiftUI 的 iOS 原型应用，用来整理个人月度待还账单、平台负债、现金压力和月度归档。

## 当前功能

- 总览：净现金压力、本月待还、未来 7 天待还、已还/未还金额。
- 账单：内置 Excel 示例数据，支持搜索、状态筛选、新增、编辑和删除。
- 平台：按平台汇总剩余负债、本月应还、下次还款日和自动扣款状态。
- 月度：展示当前月自动汇总与历史月度归档。
- 设置：维护可用现金，恢复 Excel 示例数据。

## 构建验证

当前机器的模拟器列表为空时，可以先用 SDK 做编译验证：

```sh
xcodebuild -project DebtOrganizer.xcodeproj -target DebtOrganizer -configuration Debug -sdk iphonesimulator26.5 SYMROOT=/tmp/DebtOrganizerBuild OBJROOT=/tmp/DebtOrganizerBuild/Intermediates build
```
