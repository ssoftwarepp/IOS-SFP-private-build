# 手机端脚本设置页

每个 `.bdl` 脚本包可选地放置 `index.html` 与 `settings.js`。存在 `index.html` 时，手机端的脚本列表、悬浮面板、快捷指令或 TCP 任务 19 开始运行前会先显示该设置页；取消则不运行。没有 `index.html` 的包维持原来的直接运行方式。悬浮面板的脚本行有独立设置图标，App 脚本列表的更多菜单有“脚本设置”按钮；这两个入口仅保存设置，不启动脚本。

推荐包结构（完整例子见 `layout/usr/share/zxtouch/examples/Settings Form.bdl/`）：

```text
My Script.bdl/
  info.plist
  main.py
  index.html
  settings.js
  settings.json  # 第一次保存后自动生成
```

`index.html` 通过 `<script src="settings.js"></script>` 引入脚本。`settings.js` 必须定义 `window.iosSfpSettingsSubmit()`；用户点手机导航栏“保存”或“保存并运行”时该函数收集字段，将一个 JSON 对象发送给原生页面，并返回 `true`；字段校验失败返回 `false`，页面可自行提示。

```javascript
window.iosSfpSettingsSubmit = function () {
    window.webkit.messageHandlers.iosSfpSettings.postMessage({
        action: 'save',
        data: { account: document.getElementById('account').value }
    });
    return true;
};

window.addEventListener('ios-sfp-settings', function (event) {
    document.getElementById('account').value = event.detail.account || '';
});
```

原生端收到 `save` 后把 `data` 原子写入该包的 `settings.json`，然后关闭设置页；只有成功写入且本次为“保存并运行”，才启动入口脚本。页面加载后会收到 `ios-sfp-settings` 事件，其 `detail` 是上次保存的 JSON 对象（首次为空对象）。

Python 在设备本地读取同包 JSON：

```python
import json
from pathlib import Path

bundle = Path(__file__).resolve().parent
settings = json.loads((bundle / 'settings.json').read_text(encoding='utf-8'))
account = settings.get('account', '')
```

原生设置页在 SpringBoard 进程中承载，不依赖浏览器调试控制台。任务 19 对含设置页的脚本返回的是“设置页已请求显示”，而不是“用户已保存/脚本已完成”。任务 36 (`36<脚本包绝对路径>\r\n`) 只打开设置页，成功立即返回 `0\r\n`；实际填写与保存随后进行。
