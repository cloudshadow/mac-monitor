# 可扩展的多语言文件设计

**Updated**: 2026-10-01
**Status**: 设计约定；以下资源、脚本和生成文件为计划路径，尚未实现。
**关联需求**: US6 / FR-016 / SC-009。

## 1. 文件结构与唯一翻译来源

使用 UTF-8 标准 JSON，每种语言一个目录，按功能拆分文件。翻译者无需修改 React/Swift 业务代码；新增语言通过构建时扫描目录自动注册。首版提供 `en`、`zh-Hans`、`zh-Hant`，目录命名使用规范的 BCP 47 语言标签。

```text
locales/
  README.md                 # 翻译贡献指南、占位符与复数规则
  schema/                   # 元信息、消息结构校验规范
  en/                       # 英语为键及消息参数的基准
    locale.json             # 语言名称、匹配别名、方向、发布状态
    common.json
    auth.json
    dashboard.json
    apps.json
    history.json
    settings.json
    pairing.json
    errors.json
    native.json             # 原生引导、控制端文案
  zh-Hans/                  # 与 en 相同的文件组织
  zh-Hant/
scripts/i18n/
  generate.mjs              # 扫描目录，生成注册表、TS 键类型、原生资源
  validate.mjs              # 构建前及 CI 校验
web/src/i18n/
  index.ts                  # 选择语言、加载字典、格式化、回退
  generated/                # 生成注册表及键类型，不手工维护
Sources/MonitorControl/Resources/
  Localizable.xcstrings     # 从 native.json 生成，不手工翻译
```

`locales/` 是唯一需要维护的翻译源。原生资源由同一生成流程输出：普通消息转为原生字符串，命名参数映射为带类型的位置参数，复数对象转为原生复数变体；生成过程保持参数顺序映射稳定，并校验转义。原生调用使用生成的键/参数包装，避免手工维护两份翻译或位置参数次序。生成失败应阻止构建。

## 2. 语言元信息和消息示例

`locales/zh-Hans/locale.json`：

```json
{
  "tag": "zh-Hans",
  "nativeName": "简体中文",
  "englishName": "Simplified Chinese",
  "direction": "ltr",
  "aliases": ["zh-CN", "zh-SG"],
  "status": "published"
}
```

`status` 只允许 `draft` / `published`。正式构建仅打包 published 语言并显示在选择器中；开发预览可启用 draft。`tag` 必须与目录相同，别名不得冲突。翻译目录不能提供任意加载路径或脚本。注册表由构建器生成固定加载映射。

`locales/en/auth.json`：

```json
{
  "login.title": "Sign in",
  "login.username": "Username",
  "login.password": "Password",
  "login.submit": "Sign in",
  "login.retryAfter": "Try again in {seconds} seconds"
}
```

`locales/zh-Hans/auth.json`：

```json
{
  "login.title": "登录",
  "login.username": "用户名",
  "login.password": "密码",
  "login.submit": "登录",
  "login.retryAfter": "请在 {seconds} 秒后重试"
}
```

组件使用稳定标识，例如 `t('auth:login.title')` 和 `t('auth:login.retryAfter', { seconds: formatNumber(30) })`。文件名为命名空间，文件内使用扁平键；不用中文或英文句子作为键。基于英语资源生成 TypeScript 键和参数类型，尽早发现拼写和缺参问题。

规则：

- 普通消息为字符串，插值仅支持命名参数 `{name}`；需要显示字面花括号时使用 `{{` / `}}`，生成器与格式化器统一解析。参数作为文本渲染，语言文件不包含可执行代码、HTML 或 React 组件。
- 类型契约固定：普通插值参数全部为string，生成TS的string参数和Swift的String参数，原生位置格式统一`%@`；不根据seconds/name等名称猜类型。复数对象argument指定的唯一计数参数为number（Swift Int32），其他插值仍为string；生成器为该计数生成整数复数占位，运行时拒绝越界/小数/NaN。各复数分支须有与英语一致的参数集合。
- 单位、时间和数值由显示层通过 Intl 格式化；保留原始数据、应用名称及传感器标识。业务代码不拼接句子片段，使用带参数的完整消息。
- 计数消息采用显式复数对象，例如英语 `{"type":"plural","argument":"count","forms":{"one":"{count} device","other":"{count} devices"}}`；中文可仅有 `other`。Web 使用 Intl.PluralRules 的 cardinal 类别选择，原生生成对应变体。复数选择参数（示例为`count`）必须为0～2,147,483,647的整数，不解析任意 ICU 表达式。
- 所有复数消息必须有 `other`；published 语言必须覆盖其 cardinal 类别。不同语言的类别允许不同，变量集合及消息类型必须与英语基准兼容。原生目标不能表示的结构须构建失败，不能悄悄丢弃。
- 翻译说明和语境写入 `locales/README.md` 的键说明表，避免向 JSON 添加非标准注释。

## 3. 语言选择与缺失回退

选择顺序：已保存且仍受支持的用户选择 → 浏览器语言列表中首个可匹配项 → `en`。对浏览器列表逐项尝试规范标签、元信息别名、显式脚本和已发布基础语言；中文有脚本时优先脚本，`zh-CN/SG` 映射简体，`zh-TW/HK/MO` 映射繁体，仅 `zh` 默认简体。未知标签不得用于拼接文件路径。

按键回退：当前语言消息缺失 → 英语同键 → `common` 中内置的通用错误文本。开发模式报告缺失键及文件位置；正式界面不直接显示原始键。published 语言的缺失翻译由构建校验提前阻止；运行时回退处理资源损坏或请求失败，不替代完整翻译。

加载失败优先保留当前可用语言并显示可重试提示，首次加载失败使用随入口打包的英语最小提示。快速连续切换时仅最后一次选择可以提交，防止较慢请求覆盖最新语言。完整加载当前页面所需资源后原子切换，保留表单、图表范围、账户会话及 SSE 连接。同步设置页面 `lang` / `dir`；布局使用逻辑方向属性，为未来 RTL 语言预留并在发布前验证。

浏览器只在 localStorage 存语言标签；不写账号数据库，不同步到其他设备，不保存 token。原生控制端使用独立本地语言偏好和同一发布语言列表，按系统语言匹配并回退英语。

## 4. 低占用与离线

- 构建时生成资源、注册表和类型；用户机器不运行 Node、翻译脚本、目录扫描或文件监听器。
- Web 按语言与功能模块懒加载；初始只加载当前页面所需的当前语言及英语回退字典，历史、设置等随页面加载。生产资源全部随应用提供，不请求翻译 CDN。
- 应用层字典缓存仅保留当前语言和英语；切换完成后释放旧语言字典。采用静态 JSON 资源请求及生成的 URL 映射，避免将所有语言作为动态 import 模块永久保留。浏览器资源缓存另计实测内存。
- 翻译工作不进入原生采样循环。标签仅在挂载/切换语言时重算；Intl 格式化器按当前语言和有限格式选项复用，数值仍随数据更新。
- 首屏体积预算包含必需的英语回退及当前语言资源；新增语言只增加安装包资源，不要求首屏加载全部语言。原有 CPU/内存预算不放宽，实际开销仍需验收。

## 5. 新增语言的贡献流程

1. 复制 `locales/en/` 为新目录，如 `locales/ja/`。
2. 修改 `locale.json`：标签、原语言名称、方向、别名，先设 `draft`。
3. 翻译各 JSON 的值，保留键和参数名；调整复数分支，原生提示在 `native.json` 中翻译。
4. 运行计划提供的 `npm --prefix web run i18n:check` 与 `npm --prefix web run i18n:generate`（从项目根执行，脚本定义在web/package.json；生成器按自身文件位置定位locales而非依赖工作目录，尚未实现）；预览未登录、监测、历史、配对、设置与原生引导。
5. 翻译完整并通过布局审查后改为 `published`，重新构建。菜单、Web 资源及原生资源自动更新，无需修改业务代码中的语言枚举或选择器列表。

新增语言随新版本发布；首版不提供安装后编辑应用包或运行时下载第三方语言包的功能。

## 6. 校验和验收

构建前及 CI 校验：UTF-8 / JSON 语法、重复 JSON 属性、元信息 schema、标签/别名唯一、必需命名空间、未知/缺失键、空值、消息结构、参数集合、上述固定类型及复数类别。未知键和不兼容参数为错误；draft 缺失键可警告，published 缺失键必须失败。英语基准中的未知调用键通过生成类型和检查发现。

端到端验证：三种首版语言覆盖全部页面与原生引导；缺失/加载失败回退；切换竞态；表单保留；SSE 连接数不增加；刷新保留偏好；长文本和 RTL 测试夹具；原生参数/复数语义与 Web 一致，覆盖普通参数误传数字、计数越界/小数、位置顺序、百分号及花括号转义。新增第四种测试语言时仅添加资源目录，验证自动出现在构建注册表和选择器中，且未切换前无该语言字典请求。测试语言不进入正式发布列表。

这些是待实现的验收要求，不表示当前已通过运行测试。
