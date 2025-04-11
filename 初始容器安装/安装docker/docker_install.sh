#!/bin/bash

# 更新包索引
sudo apt-get update

# 安装必要的依赖
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# 添加 Docker 官方 GPG 密钥
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# 设置稳定版仓库
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 再次更新包索引
sudo apt-get update

# 安装 Docker Engine
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# 启动 Docker 服务
sudo systemctl start docker

# 设置 Docker 开机自启
sudo systemctl enable docker

# 验证 Docker 是否安装成功
docker --version

# 将当前用户添加到 docker 组（可选，避免每次使用都需要 sudo）
sudo usermod -aG docker $USER

echo "Docker 安装完成！"
echo "建议注销并重新登录以应用用户组更改，或者运行 'newgrp docker'"