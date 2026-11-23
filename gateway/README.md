# 伴伴桌面联网辅助进程

macOS、Windows 的伴伴通过私有标准输入／输出管道启动本目录的辅助进程，不监听 HTTP 端口，不需要部署服务器或配置搜索 Key。运行时由构建脚本随安装包提供，版本与下载摘要固定；Node 许可证随包保留。

```sh
npm test
npm start
```

`npm start` 仅供协议调试；正式 App 自动管理进程。协议版本为 1，每行一条 JSON，使用请求 id 关联 `hello`、`fetch`、`github.import` 和 `cancel`。响应包含 headers、base64 chunk、done 或结构化 error。最多同时处理 4 个请求；关闭父进程管道即取消请求。

客户端只把已登记的真实来源交给读取／下载通道。HTTPS 请求逐跳验证公网 DNS，固定已验证 IP，保持 TLS 主机校验；拒绝本机、私网、凭据 URL 和非 HTTPS。搜索仅使用固定 DuckDuckGo／Bing 来源。系统 DNS 不可用或返回 Fake-IP 时，通过固定且验证 TLS 的 Google HTTPS DNS 查询公网 A 记录；不放行目标私网地址。

GitHub 技能导入复用固定提交 SHA、路径、文件大小和摘要校验。辅助进程不接收聊天 Key、智谱 Key、浏览器 Cookie 或任意文件保存路径。

Brave、Tavily、旧 HTTP 搜索服务和相关环境变量已删除。智谱原有专用流程在 App 内独立保留。验证码、限流、断网或来源结构变化均可能导致免费搜索失败，不提供付费回退。
