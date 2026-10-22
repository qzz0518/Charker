# Third-Party Notices

本项目自身以 [MIT](LICENSE) 发布。

Charker 的 Swift 代码为独立编写。以下仓库作为**协议规格与测试向量来源**被引用。

## flip-dots/SolixBLE — MIT

固定提交 `bb2d39822458108f2f98232195b83c489d4531b5`。

`Tests/A2687ProtocolTests/Fixtures.swift` 中的协商报文取自该仓库 `tests/const.py` 的
`NEGOTIATION_RESPONSES_PRIME`（作者用自己的 Anker Prime 160W 录制），仅作为测试向量使用。

```
MIT License

Copyright (c) 2025 Harvey Lelliott

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Hyper-Beast/Anker_Prime_160W_WebBLE — 无显式许可证

固定提交 `ad4355d8ea7630070059637f84c4ad245ac601b0`。

**只引用协议事实**（GATT UUID、opcode 语义、TLV 类型前缀、线材/充电协议编码表、
端口结构布局）。未复制其 JavaScript、HTML、图片或任何 UI 资产。

## atc1441/Anker_Prime_BLE_hacking — 无显式许可证

固定提交 `7d0d5a0cb2ae37f66d0be2f4af4ff53dd405e962`。

目标设备是 A1340 移动电源，协议与 A2687 无关。仅作为「Anker Prime 家族存在多代加密行为」
的背景，未使用其任何内容。

## 商标

Anker、Anker Prime 为 Anker Innovations 的商标。本项目与其无关联、未获其背书。

- `Resources/Brand/Anker.svg` 是 Anker 字标，用于标识应用所连接设备的制造商。
  素材取自用户指定的 [Seeklogo 页面](https://seeklogo.com/vector-logo/359771/anker)，
  商标及图形权利归 Anker Innovations 所有。
- `Resources/Brand/GitHub.svg` 与 `Resources/Brand/X.svg` 只用作“查看源码”和
  “关注作者”链接的识别图标。GitHub、X 及其图形标识归各自权利人所有；使用这些图标
  不表示 GitHub 或 X 对本项目提供背书。

## 产品图像与 3D 资源（Resources/Model3D/）

- `A2687.webp`、`A2687.glb`、`A2687.hdr`（应用内产品识别与三维展示）
  来自 Anker 官方商品页（anker.com/products/a2687）。版权归 Anker Innovations 所有，
  在本非官方伴侣应用中仅用于标识和展示其对应的实体产品。本项目与 Anker 无关联、未获其背书。
- `A2345.glb`（应用内产品识别与三维展示）来自 Anker 官方 A2345 商品页：
  <https://www.anker.com/products/a2345-anker-prime-charger-250w-6-ports-ganprime>。
  版权归 Anker Innovations 所有，仅用于标识和展示其对应的实体产品。

## 时钟主题预览（Resources/ClockThemes/）

- `style1.png`、`style2.png`、`style3.png`（A2345 三种内置时钟样式的预览）和
  `clock.png`（叠在图片主题上的时间示意）取自 Anker 官方「安克充电」App 3.24.0 的内置资源。
  版权归 Anker Innovations 所有，仅用于预览充电器屏幕上对应的时钟样式。

## GLTFKit2 0.5.15 — MIT

Copyright (c) 2021 Warren Moore

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

`Sources/CharkerDraco/CharkerDraco.mm` 的解码适配器基于 GLTFKit2 仓库中的
MIT-licensed `SampleDracoPlugin.mm`，并缩减为产品模型使用的三角网格路径。

## DracoSwift 1.5.7 / Google Draco — Apache License 2.0

DracoSwift 采用与 Google Draco 相同的 Apache License 2.0。本应用使用其原生
XCFramework 解码 `KHR_draco_mesh_compression`，不再分发网页端 Draco 解码器。
完整 Apache License 2.0 文本位于
`Resources/Licenses/Draco-Apache-2.0.txt`，并随 App 一同分发。

Copyright 2016 The Draco Authors

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at:

https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

## thomluther/anker-solix-api — MIT

固定提交 `daa6e3a4f1c7c3234c9ebabd7ab5c9312cd48009`。

仅引用账号区域、HTTP 接口与 MQTT 凭据结构等协议事实；未复制其 Python 实现。

```
MIT License

Copyright (c) 2024 thomluther

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Sparkle 2.10.0 — MIT

Charker 使用原版 Sparkle framework 提供签名更新检查与安装。Sparkle 的 MIT 许可、
版权声明及其所含外部组件声明完整保存在
`Resources/Licenses/Sparkle-LICENSE.txt`，并随 App 一同分发。

项目主页：<https://github.com/sparkle-project/Sparkle>

## rs-matter — Apache License 2.0

Apple「家庭」桥接助手 `charker-matter`（源码在 `Matter/`）用 rs-matter 实现 Matter 协议，
以 Git 依赖固定在 fork <https://github.com/qzz0518/rs-matter> 的提交 `9c24d772755bf1c8a7981dbea8adca577eb2be9a`：
在上游提交 `834a754698509602c015ea7979e476d7a050ba17` 之上只改了一处，订阅的 MaxInterval 最多 60 秒（`rs-matter/src/im.rs`）。
mDNS 注册所用的 astro-dnssd 0.3.6 以源码副本放在 `Matter/vendor/astro-dnssd`，只改了一处：迟到的注册回调不再触发 panic。

项目主页：<https://github.com/project-chip/rs-matter>

Copyright (c) 2022-2026 Project CHIP Authors

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at:

https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

## charker-matter 的其余 Rust 依赖

助手链接的全部 crate 的版本、许可证和所选许可，以及 Apache License 2.0 全文、
各 MIT / BSD-3-Clause crate 自带的许可与版权声明，保存在
`Resources/Licenses/charker-matter-LICENSES.txt`，并随 App 一同分发。该文件由
`mise run matter-licenses` 从 `Matter/Cargo.lock` 生成。
