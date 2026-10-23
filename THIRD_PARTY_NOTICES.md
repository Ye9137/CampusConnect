# 第三方依赖说明

CampusConnect 新版自有内容采用根目录的[非商业使用许可证](LICENSE)：禁止商用，商业使用须事先获得作者书面授权。历史 MIT 权利不受影响，原 MIT 声明保留在许可证附录中。以下依赖与系统组件由各自权利人提供，项目许可证不替代其条款。

| 依赖 / 工具 | 用途 | 官方来源与条款 |
| --- | --- | --- |
| .NET / Windows Forms | Windows 应用及随安装包分发的运行时 | https://github.com/dotnet/runtime/blob/main/LICENSE.TXT · https://github.com/dotnet/runtime/blob/main/THIRD-PARTY-NOTICES.TXT · https://github.com/dotnet/winforms/blob/main/LICENSE.TXT |
| Microsoft WebView2 SDK / Runtime | Windows 内嵌浏览器；Runtime 由 Microsoft 安装程序提供 | https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4258.31 （License Info） |
| Microsoft.Windows.SDK.NET.Ref / WinRT.Runtime | Windows 系统 OCR 的 .NET 投影与互操作支持 | https://www.nuget.org/packages/Microsoft.Windows.SDK.NET.Ref/10.0.19041.57 · https://aka.ms/WinSDKLicenseURL |
| ddddocr 1.5.6 | 随 Windows 分发的离线验证码模型 `common_old.onnx` 与数字索引；C# 预处理/解码适配 | https://github.com/sml2h3/ddddocr · https://pypi.org/project/ddddocr/1.5.6/ · MIT；原文见 `licenses/ddddocr-LICENSE.txt` |
| Microsoft.ML.OnnxRuntime 1.23.2 | CPU 本地推理；C# 绑定和 Windows 原生库 | https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime/1.23.2 · MIT 及附带第三方声明，见 `licenses/ONNX-Runtime-*` |
| Microsoft Visual C++ Redistributable | ONNX Runtime 所需系统运行库；缺少时从微软下载，校验 Microsoft Authenticode 签名后调用官方安装器 | https://aka.ms/vs/17/release/vc_redist.x64.exe · https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist；适用 Microsoft 对应条款，不作为本项目代码分发 |
| NSIS | Windows 安装器构建 | https://nsis.sourceforge.io/License |
| Playwright | 开发及浏览器测试，不随应用分发 | https://github.com/microsoft/playwright/blob/main/LICENSE |
| Apple 系统框架 | macOS 原生界面、网络和浏览器组件 | 由 macOS 提供，适用 Apple 对应 SDK / 系统条款 |

Windows 安装包的 `licenses/` 目录保留项目许可证及 .NET 10.0.12、WebView2 1.0.4258.31、NSIS 3.13 的相关声明，原文见仓库 [licenses](licenses/) 目录。Windows 模型来源、版本、SHA-256 与预处理/解码说明见 `Windows/source/models/SOURCE.json`；模型未经训练或修改权重，仅提取数字索引并增加本机适配。升级依赖时应同步更新对应声明。macOS 应用资源目录包含项目许可证。图标为本项目已有资源；仓库不包含学校认证网站的完整页面或资源包。
