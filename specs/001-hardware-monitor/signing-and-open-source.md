# 开源与 macOS 签名分发

设计更新：2026-10-01。仅设计发布流程，未购买会员、签名、上传公证或发布仓库。

## 费用和分发选择

| 方式 | Apple费用 | 适合人群 |
| --- | --- | --- |
| 公开源码、本机编译与开发签名 | 无需付费会员 | 开发者与愿意自行构建的用户 |
| 预编译ad-hoc包 + 开源一行安装器 | 无需付费会员 | 首版首选；可能需要针对该应用的首次批准 |
| Developer ID签名 + Apple公证 + DMG下载 | Apple Developer Program通常99美元/会员年，按地区币种结算 | 后续可选发行渠道 |

Developer ID和macOS公证包含在付费计划内，不按每个免费开源应用单独购买证书套餐。官方费用减免面向符合条件的非营利法人、教育机构和政府实体；个人/独资/单人企业不因项目开源自动减免。用户下载使用开源软件不需要购买开发者会员。[会员比较](https://developer.apple.com/support/compare-memberships/)、[减免资格](https://developer.apple.com/help/account/membership/fee-waivers)。

不开通会员也能开发和公开源码；ad-hoc本地签名没有Developer ID的发行者信任，也不等于公证。未经公证的构建可能遇到Gatekeeper拦截或额外手动批准，首版将批准步骤纳入安装引导与实测，不承诺所有机器零提示。不提供关闭系统安全机制作为常规安装步骤。

## 首版免费发行流程

构建arm64应用及内嵌组件 → ad-hoc签名与验证 → 归档包及SHA-256清单 → 公开固定版本安装器 → 干净Mac安装/升级测试 → 发布源码tag和对应产物。默认系统目录与LaunchDaemon，安装/维护需本机管理员授权，不要求Xcode/Node/Homebrew；管理员权限与Apple付费会员无关；可选独立维护者发布签名与Apple代码发行信任不同。详见 [free-command-install.md](free-command-install.md)。

## 后续可选Developer ID与公证流程

1. 维护者加入Apple Developer Program，在Xcode/开发者后台取得**Developer ID Application**证书。DMG内的.app使用此身份；只有选择PKG安装器时才额外涉及Developer ID Installer。
2. 以Release构建arm64应用，先签内嵌Agent、库、框架和updater等可执行组件，再签最外层.app；启用Hardened Runtime与安全时间戳，保留必要且最少的entitlement。
3. 构建并签署DMG，使用Xcode发行流程或`xcrun notarytool submit … --wait`提交Apple公证；检查结果和日志。公证是自动安全检查，不是Mac App Store上架审核。
4. 对正式发行物附加票据（`xcrun stapler staple …`）并验证，按Apple嵌套包装流程保证从DMG复制出的.app也能离线验证。用`codesign --verify --strict`、`stapler validate`和Gatekeeper评估检查发行物，不能仅以命令退出成功替代干净Mac的首次下载启动测试。
5. 发布源码tag、对应DMG、SHA-256、更新说明及第三方声明；自动更新另使用Sparkle签名和HTTPS发布appcast。

签名私钥、Apple API私钥、应用专用密码和公证凭据只放维护者Keychain/受控CI secrets。公开CI可跑构建测试；只有受保护的正式发布流程可访问发行凭据，来自fork的PR不能执行带秘密的任意脚本。现阶段无需向用户索取证书或密钥。

[Developer ID](https://developer.apple.com/developer-id/)、[Apple公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Sparkle](https://sparkle-project.org/documentation/)。

## 源码与许可证

建议首次发行采用MIT：适合希望别人易于使用、修改、再分发及商业使用的项目，要求保留许可和版权声明。若希望衍生软件也必须开放源码，应另比较相应copyleft许可证；当前仅记录MIT建议，不代替用户最终选择，也不在没有版权主体信息时生成正式LICENSE。[MIT原文](https://opensource.org/license/mit)。

源码仓库计划包含Swift服务、React/TypeScript/Vite前端、嵌入式SQLite接入、构建/打包脚本、测试与设计文档、依赖锁文件及THIRD_PARTY_NOTICES。贡献者无需付费会员即可构建开发版；付费签名仅属于可选渠道。初期可通过GitHub Releases分发归档包与安装器，不必上架Mac App Store。

参考其他监测项目时区分“研究接口”和“复制代码”：复用前检查其许可证和归属声明，不能假定本项目选择MIT就能把所有外部代码改成MIT。源码公开和依赖可复现是目标；签名时间戳等会使发行物字节不同，不承诺不同构建机器生成完全相同的已签名DMG。

## 两种证书不要混淆

Developer ID签名/公证解决Mac应用发行信任；局域网网页HTTPS证书解决浏览器连接信任。购买99美元会员不会让手机自动信任Mac的本地HTTPS证书，既有手机配对引导仍需独立验证。

## 免费命令安装首选（2026-10-01）

无需购买会员也能提供预编译包和开源安装脚本，用一条命令完成下载/校验/安装；ad-hoc签名不等于Developer ID或公证，首次运行可能仍需系统确认。流程与已同步的验收条款见 [free-command-install.md](free-command-install.md)。用户已确定为首选，主规格和任务已同步；尚无可用公开安装命令。
