# 06: 安装固定版本的 Vantage，并按顺序查找二进制

**What to build:** 新用户运行 `mdv install-vantage`，就会把 Vantage v0.7.1 装到 `~/.local/bin/`：自动选择 amd64 或 arm64 的发布包，校验内置的 sha256，校验失败就中止，不留下任何文件。如果 `~/.local/bin` 不在 PATH 里，给出提示。

`mdv` 找 Vantage 的顺序是：`MDV_VANTAGE` → PATH → `~/.local/bin` → 探测脚本的下载目录；都找不到时，提示用户运行 `mdv install-vantage`。版本号和校验和集中定义在一处。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 在隔离的 `HOME` 下运行 `mdv install-vantage`，之后 `~/.local/bin/vantage --version` 输出 0.7.1，退出码为 0；重复安装同样成功
- [ ] 用 PATH 里的假 `curl` 返回被篡改的内容：输出校验失败信息，退出码为 1，`~/.local/bin/vantage` 没有被创建或覆盖，临时目录被清理
- [ ] 不支持的架构（用假 `uname` 模拟）给出明确报错
- [ ] 查找顺序可以验证：四个位置分别只放一个二进制时都能被找到，同时存在时 `MDV_VANTAGE` 优先
- [ ] 四个位置都没有时，运行 `mdv`：stderr 提示运行 `mdv install-vantage`，退出码为 1
- [ ] 需要联网的用例可以单独跳过（例如通过一个环境变量），离线时其余用例照常运行
