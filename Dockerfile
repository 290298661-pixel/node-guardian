# Node Guardian — K8s 节点运维工具箱
# 部署为 DaemonSet，在集群每个节点上运行诊断/安全/备份工具
# 镜像构建: docker build -t ghcr.io/290298661-pixel/node-guardian:latest .

FROM alpine:3.21

LABEL org.opencontainers.image.source="https://github.com/290298661-pixel/node-guardian"
LABEL org.opencontainers.image.description="K8s node ops toolkit — preflight, diagnose, security, backup"

# 安装必要工具
RUN apk add --no-cache bash curl procps util-linux

WORKDIR /opt/node-guardian

# 复制所有脚本和库文件
COPY bin/ ./bin/
COPY lib/ ./lib/
COPY config/ ./config/

# 转换换行符（防止 Windows CRLF 问题）+ 确保可执行
RUN sed -i 's/\r$//' bin/* lib/*.sh && \
    chmod +x bin/* && \
    mkdir -p /var/log/node-guardian && \
    mkdir -p /var/backup/node-guardian

# 将 bin 加入 PATH
ENV PATH="/opt/node-guardian/bin:${PATH}"

ENTRYPOINT ["/bin/bash"]
CMD ["-c", "echo 'Node Guardian ready. Tools: kn-preflight, kn-diagnose, kn-security, kn-backup' && sleep infinity"]
