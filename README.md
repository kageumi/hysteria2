# Hysteria2 一键安装

在 Linux 服务器上以 root 运行，每次都会从 GitHub 获取最新脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/kageumi/hysteria2/main/install.sh | bash
```

菜单提供 **安装、卸载、查看配置**。安装时可设置端口、密码和 SNI；默认端口为 `443`，密码留空自动生成，默认 SNI 为 `itunes.apple.com`。

安装完成后会显示 v2rayN／v2rayNG、Mihomo 和 sing-box 的节点信息。服务器 IP 变化后，重新运行上面的命令并选择“查看配置”，再更新客户端节点。

请在云平台安全组放行所选 UDP 端口。卸载会删除 `/root/hysteria2/` 中的配置、密码和证书。
