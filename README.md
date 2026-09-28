# Hysteria2 一键安装

使用 sing-box 在 Linux 服务器上安装 Hysteria2，开机自动启动。需要 root 权限和 systemd。

## 安装

```bash
curl -fL https://raw.githubusercontent.com/kageumi/hysteria2/main/install.sh -o install.sh
bash install.sh
```

按提示设置端口、密码和 SNI：端口默认 `443`，密码留空会自动生成，SNI 默认 `itunes.apple.com`。安装完成后，终端会显示适用于 v2rayN／v2rayNG、Mihomo 和 sing-box 1.13+ 的节点信息。

请在云平台安全组放行所选的 UDP 端口。

## 查看节点

```bash
bash /root/hysteria2/install.sh show
```

脚本会获取当前公网 IP。若获取失败，可手动指定：

```bash
bash /root/hysteria2/install.sh show 203.0.113.7
```

服务器 IP 变化后，重新运行 `show`，并更新客户端中的节点。再次运行安装脚本会保留现有密码和证书。

## 查看服务状态

```bash
systemctl status hysteria2-singbox.service
```

安装文件保存在 `/root/hysteria2/`。
