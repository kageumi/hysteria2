# sing-box Hysteria2 一键安装脚本

一个 Bash 脚本，在使用 systemd 的 Linux 服务器上安装 sing-box Hysteria2 服务端。程序、配置、证书、私钥和脚本统一保存在 `/root/hysteria2/`；服务由 systemd 管理并随系统启动。

## 安装

以 root 身份在服务器上运行：

```bash
curl -fL https://raw.githubusercontent.com/kageumi/hysteria2/main/install.sh -o install.sh
bash install.sh
```

首次安装时输入 UDP 端口，直接回车使用 `443`。脚本会自动生成密码和自签证书，下载并校验 sing-box 官方最新稳定版，检查配置，然后启动服务。安装完成后，终端会显示以下三种**单节点**信息：

- v2rayN／v2rayNG：`hysteria2://` 分享链接
- Mihomo：`proxies` YAML 片段
- sing-box：单个 Hysteria2 出站 JSON，要求客户端版本 **1.13.0 或更新**

Mihomo 和 sing-box 的输出需要放入各自客户端的完整配置中。节点信息只打印在终端，不会另存客户端配置文件。

## 公网 IP 变化后

服务端监听所有可用地址，配置和证书不绑定公网 IP。IP 变化后，在服务器上重新运行：

```bash
bash /root/hysteria2/install.sh show
```

脚本会通过 ip.sb 获取当前公网 IP，并重新打印三种节点信息。若获取失败，会提示手动输入；也可以直接指定当前 IPv4 或 IPv6 地址：

```bash
bash /root/hysteria2/install.sh show 203.0.113.7
bash /root/hysteria2/install.sh show 2001:db8::7
```

随后更新客户端中已导入的节点地址。重新运行安装命令会保留原有密码、证书和 sing-box 程序，并显示现有节点，不会重新安装或升级。

## 环境与依赖

- 使用 systemd 的 Linux，需以 root 运行；支持的 CPU 架构以 sing-box 当前官方发布包为准。
- 需要访问 GitHub 发布资源；自动获取 IP 时需要访问 `https://api.ip.sb/ip`。
- 使用 Bash、curl、OpenSSL、tar 和 `sha256sum`，不需要 Python。缺少工具时，脚本尝试通过 apt、dnf、yum 或 pacman 安装。
- 若 UFW 或 firewalld 正在运行，脚本会尝试放行所选 UDP 端口。云平台安全组仍需允许该端口的 UDP 入站流量。

证书使用固定名称 `hy2.invalid`，客户端节点包含证书指纹或公钥 SHA-256 钉扎值。请妥善保管终端输出的节点信息，其中包含连接密码。

## 服务管理

```bash
systemctl status hysteria2-singbox.service
journalctl -u hysteria2-singbox.service -e
systemctl restart hysteria2-singbox.service
```

服务端数据位于 `/root/hysteria2/`，systemd 的启用链接和系统日志由操作系统管理。
